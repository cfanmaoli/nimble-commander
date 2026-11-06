//! The Rust core of Nimble Commander.
//!
//! Everything here is reached through a narrow C ABI (see `rust/include/nc_core.h`): the caller
//! owns the strings, the callbacks and the buffers, the Rust side owns nothing but its own state,
//! and every entry point is wrapped in `catch_unwind` so that a panic can never cross into the
//! C++ side (where it would be an immediate abort).
//!
//! The first module is a parallel native-filesystem search. The C++ `SearchForFiles` walks the
//! tree on a single serial queue through the VFS abstraction - right for archives and network
//! hosts, but it leaves most of the machine idle on a local disk.

#![deny(unsafe_op_in_unsafe_fn)]

use std::ffi::{c_char, c_int, c_void, CStr};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::Mutex;

pub const NC_OK: i32 = 0;
pub const NC_ERR_INVALID_ARG: i32 = -7;
pub const NC_ERR_PANIC: i32 = -5;
pub const NC_ERR_UTF8: i32 = -2;
pub const NC_ABI_VERSION: u32 = 1;

/// Bits of `NcSearchParams::options`.
pub const NC_SEARCH_FILES: u32 = 1 << 0;
pub const NC_SEARCH_DIRS: u32 = 1 << 1;
pub const NC_SEARCH_CASE_INSENSITIVE: u32 = 1 << 2;

/// Called for every match. `rel_path` is the path relative to the search root (UTF-8, NUL
/// terminated) and is only valid for the duration of the call.
pub type NcFoundCallback =
    extern "C" fn(ctx: *mut c_void, rel_path: *const c_char, is_dir: bool, size: u64, mtime: i64);

#[repr(C)]
pub struct NcSearchParams {
    /// Absolute UTF-8 path.
    pub root: *const c_char,
    /// UTF-8 glob mask (`*`, `?`). NULL or empty matches everything.
    pub mask: *const c_char,
    /// NC_SEARCH_* bits.
    pub options: u32,
    /// 0 = pick a sensible number for the machine.
    pub threads: u32,
    pub on_found: Option<NcFoundCallback>,
    pub ctx: *mut c_void,
    /// Optional pointer to an int32 flag that the caller may set to non-zero to stop the search.
    pub cancel_flag: *const c_int,
}

#[repr(C)]
#[derive(Default, Clone, Copy)]
pub struct NcSearchStats {
    pub files_seen: u64,
    pub dirs_seen: u64,
    pub matches: u64,
}

/// A tiny glob matcher: `*` matches any run of characters, `?` exactly one, everything else is
/// literal. The whole name has to match, like the file masks in the app.
pub fn glob_match(pattern: &str, text: &str, case_insensitive: bool) -> bool {
    let pb: Vec<char> = pattern.chars().collect();
    let tb: Vec<char> = text.chars().collect();
    let fold = |c: char| {
        if case_insensitive {
            c.to_lowercase().next().unwrap_or(c)
        }
        else {
            c
        }
    };
    let (mut pi, mut ti) = (0usize, 0usize);
    // the position to resume from when the last star has to swallow one more character
    let mut star: Option<(usize, usize)> = None;
    while ti < tb.len() {
        if pi < pb.len() && (pb[pi] == '?' || (pb[pi] != '*' && fold(pb[pi]) == fold(tb[ti]))) {
            pi += 1;
            ti += 1;
        }
        else if pi < pb.len() && pb[pi] == '*' {
            star = Some((pi, ti));
            pi += 1;
        }
        else if let Some((spi, sti)) = star {
            pi = spi + 1;
            ti = sti + 1;
            star = Some((spi, sti + 1));
        }
        else {
            return false;
        }
    }
    while pi < pb.len() && pb[pi] == '*' {
        pi += 1;
    }
    pi == pb.len()
}

fn parse_cstr<'a>(ptr: *const c_char) -> Result<Option<&'a str>, i32> {
    if ptr.is_null() {
        return Ok(None);
    }
    // SAFETY: the caller guarantees a NUL-terminated string that outlives the call.
    let s = unsafe { CStr::from_ptr(ptr) };
    s.to_str().map(Some).map_err(|_| NC_ERR_UTF8)
}

fn is_cancelled(flag: *const c_int) -> bool {
    if flag.is_null() {
        return false;
    }
    // SAFETY: the caller guarantees that the flag stays valid for the whole search.
    unsafe { flag.read_volatile() != 0 }
}

struct Shared {
    matches: AtomicU64,
    files_seen: AtomicU64,
    dirs_seen: AtomicU64,
    files_scanned: AtomicU64,
    files_skipped: AtomicU64,
    working: AtomicUsize,
    stop: AtomicBool,
}

/// The parts of `NcSearchParams` that the workers need, unpacked and declared thread-safe.
///
/// Safety: the C caller keeps the root/mask strings, the callback, its context and the cancel
/// flag alive and valid for the whole duration of `nc_core_search_native`, and the callback is
/// documented to be callable from any thread.
struct JobParams<'a> {
    on_found: Option<NcFoundCallback>,
    ctx: *mut c_void,
    cancel_flag: *const c_int,
    options: u32,
    mask: Option<&'a str>,
    case_insensitive: bool,
}

unsafe impl Send for JobParams<'_> {}
unsafe impl Sync for JobParams<'_> {}

struct Job<'a> {
    queue: Mutex<Vec<PathBuf>>,
    shared: Shared,
    params: JobParams<'a>,
    root: &'a Path,
}

impl Job<'_> {
    fn worker(&self) {
        loop {
            if self.shared.stop.load(Ordering::Relaxed) || is_cancelled(self.params.cancel_flag) {
                return;
            }
            let next = {
                let mut q = self.queue.lock().unwrap();
                q.pop()
            };
            let Some(dir) = next else {
                // nothing queued: if nobody is working either, the tree has been walked through
                if self.shared.working.load(Ordering::SeqCst) == 0 {
                    return;
                }
                std::thread::yield_now();
                continue;
            };
            self.shared.working.fetch_add(1, Ordering::SeqCst);
            self.process_directory(&dir);
            self.shared.working.fetch_sub(1, Ordering::SeqCst);
        }
    }

    fn process_directory(&self, dir: &Path) {
        let Ok(entries) = std::fs::read_dir(dir) else {
            return;
        };
        let mut subdirs: Vec<PathBuf> = Vec::new();
        for entry in entries.flatten() {
            if self.shared.stop.load(Ordering::Relaxed) || is_cancelled(self.params.cancel_flag) {
                return;
            }
            let name = entry.file_name();
            let name = name.to_string_lossy();
            let Ok(file_type) = entry.file_type() else {
                continue;
            };
            let is_dir = file_type.is_dir();
            let full = dir.join(&name.to_string());
            if is_dir {
                self.shared.dirs_seen.fetch_add(1, Ordering::Relaxed);
                subdirs.push(full.clone());
            }
            else {
                self.shared.files_seen.fetch_add(1, Ordering::Relaxed);
            }

            let wanted = if is_dir {
                self.params.options & NC_SEARCH_DIRS != 0
            }
            else {
                self.params.options & NC_SEARCH_FILES != 0
            };
            if !wanted {
                continue;
            }
            let matched = self
                .params
                .mask
                .map(|m| glob_match(m, &name, self.params.case_insensitive))
                .unwrap_or(true);
            if !matched {
                continue;
            }
            let Some(callback) = self.params.on_found else {
                continue;
            };
            let relative = full.strip_prefix(self.root).unwrap_or(&full);
            let Ok(relative_c) = std::ffi::CString::new(relative.to_string_lossy().as_bytes().to_vec()) else {
                continue;
            };
            let (size, mtime) = entry
                .metadata()
                .map(|m| {
                    let mtime = m
                        .modified()
                        .ok()
                        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                        .map(|d| d.as_secs() as i64)
                        .unwrap_or(0);
                    (m.len(), mtime)
                })
                .unwrap_or((0, 0));
            self.shared.matches.fetch_add(1, Ordering::Relaxed);
            callback(self.params.ctx, relative_c.as_ptr(), is_dir, size, mtime);
        }

        if !subdirs.is_empty() {
            let mut q = self.queue.lock().unwrap();
            q.append(&mut subdirs);
        }
    }
}

/// Runs a parallel filename search over the local filesystem. Fills `_stats` when non-NULL.
#[no_mangle]
pub extern "C" fn nc_core_search_native(params: *const NcSearchParams, stats: *mut NcSearchStats) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if params.is_null() {
            return NC_ERR_INVALID_ARG;
        }
        // SAFETY: null-checked above; the struct is only read.
        let params = unsafe { &*params };
        let root_str = match parse_cstr(params.root) {
            Ok(Some(s)) => s,
            Ok(None) => return NC_ERR_INVALID_ARG,
            Err(e) => return e,
        };
        if root_str.is_empty() {
            return NC_ERR_INVALID_ARG;
        }
        let mask = match parse_cstr(params.mask) {
            Ok(m) => m.filter(|m| !m.is_empty()),
            Err(e) => return e,
        };
        let root = PathBuf::from(root_str);
        if !root.is_absolute() {
            return NC_ERR_INVALID_ARG;
        }
        let case_insensitive = params.options & NC_SEARCH_CASE_INSENSITIVE != 0;
        let threads = if params.threads == 0 {
            std::thread::available_parallelism()
                .map(|n| n.get())
                .unwrap_or(4)
                .min(16)
        }
        else {
            (params.threads as usize).clamp(1, 64)
        };

        let job = Job {
            queue: Mutex::new(vec![root.clone()]),
            shared: Shared {
                matches: AtomicU64::new(0),
                files_seen: AtomicU64::new(0),
                dirs_seen: AtomicU64::new(0),
                files_scanned: AtomicU64::new(0),
                files_skipped: AtomicU64::new(0),
                working: AtomicUsize::new(0),
                stop: AtomicBool::new(false),
            },
            params: JobParams {
                on_found: params.on_found,
                ctx: params.ctx,
                cancel_flag: params.cancel_flag,
                options: params.options,
                mask,
                case_insensitive,
            },
            root: root.as_path(),
        };

        std::thread::scope(|scope| {
            for _ in 0..threads {
                scope.spawn(|| job.worker());
            }
        });

        if !stats.is_null() {
            // SAFETY: non-null and owned by the caller.
            unsafe {
                *stats = NcSearchStats {
                    files_seen: job.shared.files_seen.load(Ordering::Relaxed),
                    dirs_seen: job.shared.dirs_seen.load(Ordering::Relaxed),
                    matches: job.shared.matches.load(Ordering::Relaxed),
                };
            }
        }
        NC_OK
    }));
    match result {
        Ok(rc) => rc,
        Err(_) => NC_ERR_PANIC,
    }
}

#[no_mangle]
pub extern "C" fn nc_core_abi_version() -> u32 {
    NC_ABI_VERSION
}

/// Smoke test: returns `_x + 1`.
#[no_mangle]
pub extern "C" fn nc_core_ping(x: i32) -> i32 {
    match catch_unwind(AssertUnwindSafe(|| x.wrapping_add(1))) {
        Ok(v) => v,
        Err(_) => -1,
    }
}

/// Glob matching, exposed so that the C++ side can be differential-tested against it.
#[no_mangle]
pub extern "C" fn nc_core_glob_match(
    pattern: *const c_char,
    text: *const c_char,
    case_insensitive: bool,
) -> bool {
    let matched = catch_unwind(AssertUnwindSafe(|| {
        let Ok(Some(pattern)) = parse_cstr(pattern) else {
            return None;
        };
        let Ok(Some(text)) = parse_cstr(text) else {
            return None;
        };
        Some(glob_match(pattern, text, case_insensitive))
    }));
    match matched {
        Ok(Some(v)) => v,
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn glob_literal() {
        assert!(glob_match("abc", "abc", false));
        assert!(!glob_match("abc", "abd", false));
        assert!(!glob_match("abc", "abcd", false));
    }

    #[test]
    fn glob_star() {
        assert!(glob_match("*.txt", "notes.txt", false));
        assert!(!glob_match("*.txt", "notes.md", false));
        assert!(glob_match("a*c", "abc", false));
        assert!(glob_match("a*c", "ac", false));
        assert!(glob_match("*", "", false));
        assert!(glob_match("a*b*c", "aXbYc", false));
        assert!(glob_match("a*b*c", "aXbYcZ", false) == false);
    }

    #[test]
    fn glob_question() {
        assert!(glob_match("a?c", "abc", false));
        assert!(!glob_match("a?c", "ac", false));
    }

    #[test]
    fn glob_case_insensitive() {
        assert!(glob_match("*.TXT", "notes.txt", true));
        assert!(!glob_match("*.TXT", "notes.txt", false));
    }

    #[test]
    fn search_finds_files() {
        let root = std::env::temp_dir().join(format!("nc_core_test_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("sub")).unwrap();
        std::fs::write(root.join("a.txt"), b"12345").unwrap();
        std::fs::write(root.join("b.md"), b"x").unwrap();
        std::fs::write(root.join("sub/c.txt"), b"xy").unwrap();

        static SEEN: Mutex<Vec<String>> = Mutex::new(Vec::new());
        extern "C" fn on_found(_ctx: *mut c_void, rel: *const c_char, _is_dir: bool, _size: u64, _mtime: i64) {
            let s = unsafe { CStr::from_ptr(rel) }.to_string_lossy().into_owned();
            SEEN.lock().unwrap().push(s);
        }

        let mut stats = NcSearchStats::default();
        let root_c = std::ffi::CString::new(root.to_str().unwrap()).unwrap();
        let mask_c = std::ffi::CString::new("*.txt").unwrap();
        let params = NcSearchParams {
            root: root_c.as_ptr(),
            mask: mask_c.as_ptr(),
            options: NC_SEARCH_FILES,
            threads: 2,
            on_found: Some(on_found),
            ctx: std::ptr::null_mut(),
            cancel_flag: std::ptr::null(),
        };
        assert_eq!(nc_core_search_native(&params, &mut stats), NC_OK);
        let mut seen = SEEN.lock().unwrap().clone();
        seen.sort();
        assert_eq!(seen, vec!["a.txt".to_string(), "sub/c.txt".to_string()]);
        assert_eq!(stats.matches, 2);
        assert_eq!(stats.files_seen, 3);
        assert_eq!(stats.dirs_seen, 1);

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn search_rejects_bad_arguments() {
        let relative = std::ffi::CString::new("relative/path").unwrap();
        let params = NcSearchParams {
            root: relative.as_ptr(),
            mask: std::ptr::null(),
            options: NC_SEARCH_FILES,
            threads: 1,
            on_found: None,
            ctx: std::ptr::null_mut(),
            cancel_flag: std::ptr::null(),
        };
        let mut stats = NcSearchStats::default();
        assert_eq!(nc_core_search_native(&params, &mut stats), NC_ERR_INVALID_ARG);
        assert_eq!(nc_core_search_native(std::ptr::null(), &mut stats), NC_ERR_INVALID_ARG);
    }

    #[test]
    fn search_cancellation() {
        let root = std::env::temp_dir().join(format!("nc_core_cancel_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        for i in 0..200 {
            std::fs::write(root.join(format!("f{i}.txt")), b"x").unwrap();
        }
        let cancel: std::ffi::c_int = 1;
        let root_c = std::ffi::CString::new(root.to_str().unwrap()).unwrap();
        let params = NcSearchParams {
            root: root_c.as_ptr(),
            mask: std::ptr::null(),
            options: NC_SEARCH_FILES,
            threads: 2,
            on_found: None,
            ctx: std::ptr::null_mut(),
            cancel_flag: &cancel,
        };
        let mut stats = NcSearchStats::default();
        assert_eq!(nc_core_search_native(&params, &mut stats), NC_OK);
        assert_eq!(stats.files_seen, 0);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn ping_works() {
        assert_eq!(nc_core_ping(41), 42);
        assert_eq!(nc_core_abi_version(), NC_ABI_VERSION);
    }
}

// ---------------------------------------------------------------------------------------------
// Column-oriented flat enumeration
//
// The flat view needs the attributes of every entry of a whole subtree, and building one
// VFSListing per directory for that was the bottleneck (Docs/VFS-Peel-Evaluation.md, 6.). This
// walks the tree with getattrlistbulk() and hands the entries over in column form, so that the
// C++ side can fill a single ListingInput without any intermediate listings.
// ---------------------------------------------------------------------------------------------

#[repr(C)]
struct AttrList {
    bitmapcount: u16,
    reserved: u16,
    commonattr: u32,
    volattr: u32,
    dirattr: u32,
    fileattr: u32,
    forkattr: u32,
}

extern "C" {
    fn getattrlistbulk(
        dirfd: i32,
        al: *mut AttrList,
        buffer: *mut core::ffi::c_void,
        buffer_size: usize,
        options: u64,
    ) -> i32;
}

const ATTR_BIT_MAP_COUNT: u16 = 5;
const ATTR_CMN_RETURNED_ATTRS: u32 = 0x8000_0000;
const ATTR_CMN_NAME: u32 = 0x0000_0001;
const ATTR_CMN_OBJTYPE: u32 = 0x0000_0008;
const ATTR_CMN_CRTIME: u32 = 0x0000_0200;
const ATTR_CMN_MODTIME: u32 = 0x0000_0400;
const ATTR_CMN_CHGTIME: u32 = 0x0000_0800;
const ATTR_CMN_ACCTIME: u32 = 0x0000_1000;
const ATTR_CMN_OWNERID: u32 = 0x0000_8000;
const ATTR_CMN_GRPID: u32 = 0x0001_0000;
const ATTR_CMN_ACCESSMASK: u32 = 0x0002_0000;
const ATTR_CMN_FLAGS: u32 = 0x0004_0000;
const ATTR_CMN_FILEID: u32 = 0x0200_0000;
const ATTR_CMN_ADDEDTIME: u32 = 0x1000_0000;
const ATTR_FILE_DATALENGTH: u32 = 0x0000_0200;
const FSOPT_ATTR_CMN_EXTENDED: u64 = 0x0000_0020;

pub const NC_DT_UNKNOWN: u8 = 0;
pub const NC_DT_FIFO: u8 = 1;
pub const NC_DT_CHR: u8 = 2;
pub const NC_DT_DIR: u8 = 4;
pub const NC_DT_BLK: u8 = 6;
pub const NC_DT_REG: u8 = 8;
pub const NC_DT_LNK: u8 = 10;
pub const NC_DT_SOCK: u8 = 12;
pub const NC_DT_WHT: u8 = 14;

/// One batch of entries of a single directory, handed to the C++ side as columns.
#[repr(C)]
pub struct NcFlatBatch {
    /// Absolute directory path, UTF-8, NUL-terminated, with a trailing slash.
    pub dir_path: *const c_char,
    pub dir_path_len: u32,
    pub count: u32,
    /// NUL-terminated entry names plus their lengths (without the NUL).
    pub names: *const *const c_char,
    pub name_lengths: *const u32,
    /// DT_* values.
    pub types: *const u8,
    /// Full st_mode: file type bits + permission bits.
    pub modes: *const u32,
    /// u64::MAX when the entry has no data length (directories).
    pub sizes: *const u64,
    pub mtimes: *const i64,
    pub btimes: *const i64,
    pub ctimes: *const i64,
    pub atimes: *const i64,
    /// -1 when the volume doesn't report it.
    pub add_times: *const i64,
    pub inodes: *const u64,
    pub uids: *const u32,
    pub gids: *const u32,
    pub flags: *const u32,
}

#[repr(C)]
#[derive(Default, Clone, Copy)]
pub struct NcFlatStats {
    pub files: u64,
    pub dirs: u64,
    pub entries: u64,
    pub directories_scanned: u64,
}

pub type NcFlatBatchCallback = extern "C" fn(ctx: *mut c_void, batch: *const NcFlatBatch);

fn ne_u32(buf: &[u8], off: usize) -> u32 {
    u32::from_ne_bytes(buf[off..off + 4].try_into().unwrap())
}

fn ne_u64(buf: &[u8], off: usize) -> u64 {
    u64::from_ne_bytes(buf[off..off + 8].try_into().unwrap())
}

fn ne_i64(buf: &[u8], off: usize) -> i64 {
    i64::from_ne_bytes(buf[off..off + 8].try_into().unwrap())
}

struct Entry {
    name_off: usize, // offset into the parse buffer
    name_len: u32,
    dtype: u8,
    mode: u32,
    size: u64,
    mtime: i64,
    btime: i64,
    ctime: i64,
    atime: i64,
    addtime: i64,
    inode: u64,
    uid: u32,
    gid: u32,
    flags: u32,
    is_dir: bool,
}

/// Parses one batch of getattrlistbulk output into entry records.
fn parse_entries(buf: &[u8], count: i32, out: &mut Vec<Entry>) {
    let mut entry_off = 0usize;
    for _ in 0..count {
        if entry_off + 4 > buf.len() {
            return;
        }
        let entry_len = ne_u32(buf, entry_off) as usize;
        if entry_len < 4 || entry_off + entry_len > buf.len() {
            return;
        }
        let entry_start = entry_off + 4;
        let mut off = entry_start;
        if off + 20 > buf.len() {
            return;
        }
        let returned_common = ne_u32(buf, off);
        let returned_file = ne_u32(buf, off + 12);
        off += 20;

        if returned_common & ATTR_CMN_NAME == 0 {
            entry_off = entry_start + entry_len - 4;
            continue;
        }
        let aref_off = off;
        let aref_offset = i32::from_ne_bytes(buf[off..off + 4].try_into().unwrap());
        let aref_length = ne_u32(buf, off + 4);
        off += 8;
        let name_addr = aref_off as isize + aref_offset as isize;
        if name_addr < 0 || aref_length == 0 || name_addr as usize + aref_length as usize > buf.len() {
            entry_off = entry_start + entry_len - 4;
            continue;
        }

        let mut entry = Entry {
            name_off: name_addr as usize,
            name_len: aref_length - 1, // drop the trailing NUL
            dtype: NC_DT_UNKNOWN,
            mode: 0,
            size: u64::MAX,
            mtime: 0,
            btime: 0,
            ctime: 0,
            atime: 0,
            addtime: -1,
            inode: 0,
            uid: 0,
            gid: 0,
            flags: 0,
            is_dir: false,
        };

        if returned_common & ATTR_CMN_OBJTYPE != 0 {
            match ne_u32(buf, off) {
                1 => {
                    entry.dtype = NC_DT_REG;
                    entry.mode = 0o100000;
                }
                2 => {
                    entry.dtype = NC_DT_DIR;
                    entry.mode = 0o040000;
                    entry.is_dir = true;
                }
                3 => {
                    entry.dtype = NC_DT_BLK;
                    entry.mode = 0o060000;
                }
                4 => {
                    entry.dtype = NC_DT_CHR;
                    entry.mode = 0o020000;
                }
                5 => {
                    entry.dtype = NC_DT_LNK;
                    entry.mode = 0o120000;
                }
                6 => {
                    entry.dtype = NC_DT_SOCK;
                    entry.mode = 0o140000;
                }
                7 => {
                    entry.dtype = NC_DT_FIFO;
                    entry.mode = 0o010000;
                }
                8 => {
                    entry.dtype = NC_DT_WHT;
                    entry.mode = 0o160000;
                }
                _ => {}
            }
            off += 4;
        }
        if returned_common & ATTR_CMN_CRTIME != 0 {
            entry.btime = ne_i64(buf, off);
            off += 16;
        }
        if returned_common & ATTR_CMN_MODTIME != 0 {
            entry.mtime = ne_i64(buf, off);
            off += 16;
        }
        if returned_common & ATTR_CMN_CHGTIME != 0 {
            entry.ctime = ne_i64(buf, off);
            off += 16;
        }
        if returned_common & ATTR_CMN_ACCTIME != 0 {
            entry.atime = ne_i64(buf, off);
            off += 16;
        }
        if returned_common & ATTR_CMN_OWNERID != 0 {
            entry.uid = ne_u32(buf, off);
            off += 4;
        }
        if returned_common & ATTR_CMN_GRPID != 0 {
            entry.gid = ne_u32(buf, off);
            off += 4;
        }
        if returned_common & ATTR_CMN_ACCESSMASK != 0 {
            entry.mode |= ne_u32(buf, off) & 0o7777;
            off += 4;
        }
        if returned_common & ATTR_CMN_FLAGS != 0 {
            entry.flags = ne_u32(buf, off);
            off += 4;
        }
        if returned_common & ATTR_CMN_FILEID != 0 {
            entry.inode = ne_u64(buf, off);
            off += 8;
        }
        if returned_common & ATTR_CMN_ADDEDTIME != 0 {
            entry.addtime = ne_i64(buf, off);
            off += 16;
        }
        if returned_file & ATTR_FILE_DATALENGTH != 0 {
            entry.size = ne_u64(buf, off);
        }

        out.push(entry);
        entry_off = entry_start + entry_len - 4;
    }
}

thread_local! {
    static FLAT_BUF: std::cell::UnsafeCell<Vec<u8>> =
        std::cell::UnsafeCell::new(vec![0u8; 256 * 1024]);
}

/// Enumerates one directory and hands its entries over in one batch.
/// Returns the subdirectories found there.
fn enumerate_directory_flat(
    dir: &Path,
    cb: NcFlatBatchCallback,
    ctx: *mut c_void,
    stats: &mut NcFlatStats,
) -> Vec<PathBuf> {
    use std::os::unix::io::AsRawFd;
    let mut subdirs: Vec<PathBuf> = Vec::new();
    let Ok(file) = std::fs::File::open(dir) else {
        return subdirs;
    };
    let fd = file.as_raw_fd();

    let mut al = AttrList {
        bitmapcount: ATTR_BIT_MAP_COUNT,
        reserved: 0,
        commonattr: ATTR_CMN_RETURNED_ATTRS
            | ATTR_CMN_NAME
            | ATTR_CMN_OBJTYPE
            | ATTR_CMN_CRTIME
            | ATTR_CMN_MODTIME
            | ATTR_CMN_CHGTIME
            | ATTR_CMN_ACCTIME
            | ATTR_CMN_OWNERID
            | ATTR_CMN_GRPID
            | ATTR_CMN_ACCESSMASK
            | ATTR_CMN_FLAGS
            | ATTR_CMN_FILEID
            | ATTR_CMN_ADDEDTIME,
        volattr: 0,
        dirattr: 0,
        fileattr: ATTR_FILE_DATALENGTH,
        forkattr: 0,
    };

    let mut dir_path = dir.to_string_lossy().into_owned();
    if !dir_path.ends_with('/') {
        dir_path.push('/');
    }
    let Ok(dir_path_c) = std::ffi::CString::new(dir_path.as_str()) else {
        return subdirs;
    };

    FLAT_BUF.with(|cell| {
        // SAFETY: the buffer stays borrowed for the duration of this closure and is not
        // re-entered (the closure runs to completion before the slot is used again).
        let buf = unsafe { &mut *cell.get() };
        let mut entries: Vec<Entry> = Vec::new();
        loop {
            // SAFETY: fd belongs to \`file\`, al is initialised and the buffer is 256 KiB.
            let retcount = unsafe {
                getattrlistbulk(
                    fd,
                    &mut al,
                    buf.as_mut_ptr() as *mut core::ffi::c_void,
                    buf.len(),
                    FSOPT_ATTR_CMN_EXTENDED,
                )
            };
            if retcount <= 0 {
                break;
            }
            entries.clear();
            parse_entries(buf, retcount, &mut entries);
            if entries.is_empty() {
                continue;
            }

            let names: Vec<*const c_char> = entries
                .iter()
                .map(|e| buf.as_ptr().wrapping_add(e.name_off) as *const c_char)
                .collect();
            let name_lengths: Vec<u32> = entries.iter().map(|e| e.name_len).collect();
            let types: Vec<u8> = entries.iter().map(|e| e.dtype).collect();
            let modes: Vec<u32> = entries.iter().map(|e| e.mode).collect();
            let sizes: Vec<u64> = entries.iter().map(|e| e.size).collect();
            let mtimes: Vec<i64> = entries.iter().map(|e| e.mtime).collect();
            let btimes: Vec<i64> = entries.iter().map(|e| e.btime).collect();
            let ctimes: Vec<i64> = entries.iter().map(|e| e.ctime).collect();
            let atimes: Vec<i64> = entries.iter().map(|e| e.atime).collect();
            let add_times: Vec<i64> = entries.iter().map(|e| e.addtime).collect();
            let inodes: Vec<u64> = entries.iter().map(|e| e.inode).collect();
            let uids: Vec<u32> = entries.iter().map(|e| e.uid).collect();
            let gids: Vec<u32> = entries.iter().map(|e| e.gid).collect();
            let flags: Vec<u32> = entries.iter().map(|e| e.flags).collect();

            let batch = NcFlatBatch {
                dir_path: dir_path_c.as_ptr(),
                dir_path_len: dir_path.len() as u32,
                count: entries.len() as u32,
                names: names.as_ptr(),
                name_lengths: name_lengths.as_ptr(),
                types: types.as_ptr(),
                modes: modes.as_ptr(),
                sizes: sizes.as_ptr(),
                mtimes: mtimes.as_ptr(),
                btimes: btimes.as_ptr(),
                ctimes: ctimes.as_ptr(),
                atimes: atimes.as_ptr(),
                add_times: add_times.as_ptr(),
                inodes: inodes.as_ptr(),
                uids: uids.as_ptr(),
                gids: gids.as_ptr(),
                flags: flags.as_ptr(),
            };
            cb(ctx, &batch);

            for (i, e) in entries.iter().enumerate() {
                let name = String::from_utf8_lossy(&buf[e.name_off..(e.name_off + e.name_len as usize)]);
                if name == "." || name == ".." {
                    continue;
                }
                if e.is_dir {
                    stats.dirs += 1;
                    subdirs.push(dir.join(name.as_ref()));
                } else {
                    stats.files += 1;
                }
                let _ = i;
            }
            stats.entries += entries.len() as u64;
        }
    });
    stats.directories_scanned += 1;
    subdirs
}

/// Walks the tree under \`root\` in parallel and reports the entries of every directory as a batch.
#[no_mangle]
pub extern "C" fn nc_core_scan_flat(
    root: *const c_char,
    threads: u32,
    on_batch: Option<NcFlatBatchCallback>,
    ctx: *mut c_void,
    cancel_flag: *const c_int,
    stats: *mut NcFlatStats,
) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        let Ok(Some(root_str)) = parse_cstr(root) else {
            return NC_ERR_INVALID_ARG;
        };
        let Some(callback) = on_batch else {
            return NC_ERR_INVALID_ARG;
        };
        let root_path = PathBuf::from(root_str);
        if !root_path.is_absolute() {
            return NC_ERR_INVALID_ARG;
        }
        let workers = if threads == 0 {
            std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4).min(16)
        } else {
            (threads as usize).clamp(1, 64)
        };

        // The C caller's context and cancel flag travel into the workers; the caller guarantees
        // they stay valid until this function returns.
        struct SharedCtx(*mut c_void, *const c_int);
        unsafe impl Send for SharedCtx {}
        unsafe impl Sync for SharedCtx {}
        let shared_ctx = SharedCtx(ctx, cancel_flag);

        let mut totals = NcFlatStats::default();
        let mut level: Vec<PathBuf> = vec![root_path];
        while !level.is_empty() {
            if is_cancelled(cancel_flag) {
                break;
            }
            let next_level: Mutex<Vec<PathBuf>> = Mutex::new(Vec::new());
            let level_stats: Mutex<NcFlatStats> = Mutex::new(NcFlatStats::default());
            let next_index = AtomicUsize::new(0);
            let thread_count = workers.min(level.len().max(1));
            let shared = &shared_ctx;
            std::thread::scope(|scope| {
                for _ in 0..thread_count {
                    scope.spawn(|| loop {
                        if is_cancelled(shared.1) {
                            return;
                        }
                        let i = next_index.fetch_add(1, Ordering::Relaxed);
                        if i >= level.len() {
                            return;
                        }
                        let mut local = NcFlatStats::default();
                        let subdirs = enumerate_directory_flat(&level[i], callback, shared.0, &mut local);
                        if !subdirs.is_empty() {
                            next_level.lock().unwrap().extend(subdirs);
                        }
                        let mut ls = level_stats.lock().unwrap();
                        ls.files += local.files;
                        ls.dirs += local.dirs;
                        ls.entries += local.entries;
                        ls.directories_scanned += local.directories_scanned;
                    });
                }
            });
            let ls = *level_stats.lock().unwrap();
            totals.files += ls.files;
            totals.dirs += ls.dirs;
            totals.entries += ls.entries;
            totals.directories_scanned += ls.directories_scanned;
            level = next_level.into_inner().unwrap();
        }

        if !stats.is_null() {
            // SAFETY: non-null and owned by the caller.
            unsafe {
                *stats = totals;
            }
        }
        NC_OK
    }));
    match result {
        Ok(rc) => rc,
        Err(_) => NC_ERR_PANIC,
    }
}

#[cfg(test)]
mod flat_tests {
    use super::*;

    extern "C" fn count_batch(ctx: *mut c_void, batch: *const NcFlatBatch) {
        let counter = unsafe { &mut *(ctx as *mut (u64, u64, u64)) };
        let b = unsafe { &*batch };
        let dir = unsafe { std::slice::from_raw_parts(b.dir_path as *const u8, b.dir_path_len as usize) };
        let dir = std::str::from_utf8(dir).unwrap_or("<bad>");
        counter.0 += b.count as u64;
        for i in 0..b.count as usize {
            let name_ptr = unsafe { *b.names.add(i) };
            let name = unsafe { std::ffi::CStr::from_ptr(name_ptr) }.to_string_lossy();
            eprintln!("batch dir={dir} name={name}");
            if name.ends_with(".txt") {
                counter.1 += 1;
            }
            let size = unsafe { *b.sizes.add(i) };
            if size != u64::MAX && !name.is_empty() {
                counter.2 += 1;
            }
        }
    }

    #[test]
    fn flat_scan_reports_entries() {
        let root = std::env::temp_dir().join(format!("nc_flat_test_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("sub")).unwrap();
        std::fs::write(root.join("a.txt"), b"12345").unwrap();
        std::fs::write(root.join("b.md"), b"x").unwrap();
        std::fs::write(root.join("sub/c.txt"), b"xy").unwrap();

        let mut counter: (u64, u64, u64) = (0, 0, 0);
        let mut stats = NcFlatStats::default();
        let root_c = std::ffi::CString::new(root.to_str().unwrap()).unwrap();
        let rc = nc_core_scan_flat(
            root_c.as_ptr(),
            3,
            Some(count_batch),
            &mut counter as *mut _ as *mut c_void,
            std::ptr::null(),
            &mut stats,
        );
        assert_eq!(rc, NC_OK);
        assert_eq!(counter.0, 4); // two files in the root, one in sub, plus the "sub" directory
        assert_eq!(counter.1, 2); // a.txt, sub/c.txt
        assert_eq!(stats.files, 3);
        assert_eq!(stats.dirs, 1);
        assert_eq!(stats.directories_scanned, 2);

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn flat_scan_rejects_bad_arguments() {
        let mut stats = NcFlatStats::default();
        assert_eq!(
            nc_core_scan_flat(
                std::ptr::null(),
                1,
                Some(count_batch),
                std::ptr::null_mut(),
                std::ptr::null(),
                &mut stats
            ),
            NC_ERR_INVALID_ARG
        );
        let rel = std::ffi::CString::new("relative").unwrap();
        assert_eq!(
            nc_core_scan_flat(
                rel.as_ptr(),
                1,
                Some(count_batch),
                std::ptr::null_mut(),
                std::ptr::null(),
                &mut stats
            ),
            NC_ERR_INVALID_ARG
        );
    }
}


// ---------------------------------------------------------------------------------------------
// Content search
//
// The find-files dialog can search for text inside files; the C++ implementation opens every file
// through the VFS and matches with SearchInFile (CFString based, one encoding at a time). This is
// the same job done natively, in parallel, straight on the bytes - the common case is UTF-8/ASCII
// and does not need the encoding machinery.
// ---------------------------------------------------------------------------------------------

pub const NC_CONTENT_CASE_INSENSITIVE: u32 = 1 << 0;
pub const NC_CONTENT_WHOLE_PHRASE: u32 = 1 << 1;

#[repr(C)]
pub struct NcContentParams {
    /// Absolute UTF-8 path of the tree to search.
    pub root: *const c_char,
    /// The needle, as raw bytes (UTF-8 for text).
    pub needle: *const c_char,
    pub needle_len: u32,
    /// NC_CONTENT_* bits.
    pub options: u32,
    /// 0 = automatic.
    pub threads: u32,
    /// Files larger than this are skipped; 0 means "no limit".
    pub max_file_size: u64,
}

#[repr(C)]
#[derive(Default, Clone, Copy)]
pub struct NcContentStats {
    pub files_scanned: u64,
    pub files_skipped: u64,
    pub matches: u64,
}

/// Called for every file that contains the needle. \`rel_path\` is relative to the search root.
pub type NcContentCallback =
    extern "C" fn(ctx: *mut c_void, rel_path: *const c_char, offset: u64, bytes_len: u64);

fn ascii_fold(b: u8) -> u8 {
    if b.is_ascii_uppercase() {
        b + 32
    } else {
        b
    }
}

fn is_word_byte(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b == b'_'
}

/// Finds the first occurrence of \`needle\` in \`hay\`. Returns its byte offset.
pub fn find_bytes(hay: &[u8], needle: &[u8], case_insensitive: bool, whole_phrase: bool) -> Option<usize> {
    if needle.is_empty() || hay.len() < needle.len() {
        return None;
    }
    let first = if case_insensitive { ascii_fold(needle[0]) } else { needle[0] };
    let last_start = hay.len() - needle.len();
    let mut i = 0usize;
    while i <= last_start {
        // find a candidate first byte; the standard library's position() is vectorised for u8
        let Some(rel) = hay[i..=last_start]
            .iter()
            .position(|&b| if case_insensitive { ascii_fold(b) == first } else { b == first })
        else {
            return None;
        };
        i += rel;
        let matched = if case_insensitive {
            hay[i..i + needle.len()]
                .iter()
                .zip(needle.iter())
                .all(|(a, b)| ascii_fold(*a) == ascii_fold(*b))
        } else {
            &hay[i..i + needle.len()] == needle
        };
        if matched {
            if !whole_phrase {
                return Some(i);
            }
            let before_ok = i == 0 || !is_word_byte(hay[i - 1]);
            let after = i + needle.len();
            let after_ok = after == hay.len() || !is_word_byte(hay[after]);
            if before_ok && after_ok {
                return Some(i);
            }
        }
        i += 1;
    }
    None
}

/// The parts of NcContentParams the workers need, unpacked and declared thread-safe.
///
/// Safety: the C caller keeps the root, the needle, the callback, its context and the cancel flag
/// alive for the whole call, and the callback is documented to be callable from any thread.
struct ContentParams<'a> {
    on_found: Option<NcContentCallback>,
    ctx: *mut c_void,
    cancel_flag: *const c_int,
    max_file_size: u64,
    needle: &'a [u8],
}

unsafe impl Send for ContentParams<'_> {}
unsafe impl Sync for ContentParams<'_> {}

struct ContentJob<'a> {
    queue: Mutex<Vec<PathBuf>>,
    shared: Shared,
    params: ContentParams<'a>,
    root: &'a Path,
    case_insensitive: bool,
    whole_phrase: bool,
}

impl ContentJob<'_> {
    fn worker(&self) {
        let mut files_scanned = 0u64;
        let mut files_skipped = 0u64;
        let mut matches = 0u64;
        loop {
            if self.shared.stop.load(Ordering::Relaxed)
                || is_cancelled(self.params.cancel_flag)
            {
                break;
            }
            let next = {
                let mut q = self.queue.lock().unwrap();
                q.pop()
            };
            let Some(dir) = next else {
                if self.shared.working.load(Ordering::SeqCst) == 0 {
                    break;
                }
                std::thread::yield_now();
                continue;
            };
            self.shared.working.fetch_add(1, Ordering::SeqCst);
            let Ok(entries) = std::fs::read_dir(&dir) else {
                self.shared.working.fetch_sub(1, Ordering::SeqCst);
                continue;
            };
            let mut subdirs: Vec<PathBuf> = Vec::new();
            for entry in entries.flatten() {
                if self.shared.stop.load(Ordering::Relaxed) || is_cancelled(self.params.cancel_flag) {
                    break;
                }
                let Ok(file_type) = entry.file_type() else {
                    continue;
                };
                let path = entry.path();
                if file_type.is_dir() {
                    subdirs.push(path);
                    continue;
                }
                if !file_type.is_file() {
                    continue; // symlinks, devices, sockets
                }
                let Ok(metadata) = entry.metadata() else {
                    continue;
                };
                if self.params.max_file_size != 0 && metadata.len() > self.params.max_file_size {
                    files_skipped += 1;
                    continue;
                }
                let Ok(content) = std::fs::read(&path) else {
                    continue;
                };
                files_scanned += 1;
                if let Some(offset) =
                    find_bytes(&content, self.params.needle, self.case_insensitive, self.whole_phrase)
                {
                    matches += 1;
                    if let Some(cb) = self.params.on_found {
                        let relative = path.strip_prefix(self.root).unwrap_or(&path);
                        if let Ok(relative_c) =
                            std::ffi::CString::new(relative.to_string_lossy().as_bytes().to_vec())
                        {
                            cb(
                                self.params.ctx,
                                relative_c.as_ptr(),
                                offset as u64,
                                self.params.needle.len() as u64,
                            );
                        }
                    }
                }
            }
            if !subdirs.is_empty() {
                let mut q = self.queue.lock().unwrap();
                q.append(&mut subdirs);
            }
            self.shared.working.fetch_sub(1, Ordering::SeqCst);
        }
        self.shared.files_scanned.fetch_add(files_scanned, Ordering::Relaxed);
        self.shared.files_skipped.fetch_add(files_skipped, Ordering::Relaxed);
        self.shared.matches.fetch_add(matches, Ordering::Relaxed);
    }
}

/// Searches the contents of the files under \`params->root\` for \`params->needle\`.
#[no_mangle]
pub extern "C" fn nc_core_search_content(
    params: *const NcContentParams,
    on_found: Option<NcContentCallback>,
    ctx: *mut c_void,
    cancel_flag: *const c_int,
    stats: *mut NcContentStats,
) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if params.is_null() {
            return NC_ERR_INVALID_ARG;
        }
        let params = unsafe { &*params };
        let Ok(Some(root_str)) = parse_cstr(params.root) else {
            return NC_ERR_INVALID_ARG;
        };
        if root_str.is_empty() || params.needle.is_null() || params.needle_len == 0 {
            return NC_ERR_INVALID_ARG;
        }
        let root = PathBuf::from(root_str);
        if !root.is_absolute() {
            return NC_ERR_INVALID_ARG;
        }
        // SAFETY: the caller keeps the needle alive for the duration of the call.
        let needle = unsafe { std::slice::from_raw_parts(params.needle as *const u8, params.needle_len as usize) };
        let threads = if params.threads == 0 {
            std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4).min(16)
        } else {
            (params.threads as usize).clamp(1, 64)
        };

        let job = ContentJob {
            queue: Mutex::new(vec![root.clone()]),
            shared: Shared {
                matches: AtomicU64::new(0),
                files_seen: AtomicU64::new(0),
                dirs_seen: AtomicU64::new(0),
                files_scanned: AtomicU64::new(0),
                files_skipped: AtomicU64::new(0),
                working: AtomicUsize::new(0),
                stop: AtomicBool::new(false),
            },
            params: ContentParams {
                on_found,
                ctx,
                cancel_flag,
                max_file_size: params.max_file_size,
                needle,
            },
            root: root.as_path(),
            case_insensitive: params.options & NC_CONTENT_CASE_INSENSITIVE != 0,
            whole_phrase: params.options & NC_CONTENT_WHOLE_PHRASE != 0,
        };

        std::thread::scope(|scope| {
            for _ in 0..threads {
                scope.spawn(|| job.worker());
            }
        });

        if !stats.is_null() {
            // SAFETY: non-null and owned by the caller.
            unsafe {
                *stats = NcContentStats {
                    files_scanned: job.shared.files_scanned.load(Ordering::Relaxed),
                    files_skipped: job.shared.files_skipped.load(Ordering::Relaxed),
                    matches: job.shared.matches.load(Ordering::Relaxed),
                };
            }
        }
        NC_OK
    }));
    match result {
        Ok(rc) => rc,
        Err(_) => NC_ERR_PANIC,
    }
}

#[cfg(test)]
mod content_tests {
    use super::*;

    #[test]
    fn finds_literal_bytes() {
        assert_eq!(find_bytes(b"hello world", b"world", false, false), Some(6));
        assert_eq!(find_bytes(b"hello world", b"World", false, false), None);
        assert_eq!(find_bytes(b"hello world", b"World", true, false), Some(6));
        assert_eq!(find_bytes(b"abc", b"abcd", false, false), None);
        assert_eq!(find_bytes(b"", b"a", false, false), None);
        assert_eq!(find_bytes(b"aaab", b"aab", false, false), Some(1));
    }

    #[test]
    fn whole_phrase_respects_word_boundaries() {
        assert_eq!(find_bytes(b"a cat sat", b"cat", false, true), Some(2));
        assert_eq!(find_bytes(b"concatenate", b"cat", false, true), None);
        assert_eq!(find_bytes(b"cat9", b"cat", false, true), None);
        assert_eq!(find_bytes(b"(cat)", b"cat", false, true), Some(1));
    }

    #[test]
    fn searches_files_in_a_tree() {
        let root = std::env::temp_dir().join(format!("nc_content_test_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("sub")).unwrap();
        std::fs::write(root.join("a.txt"), b"the needle is here").unwrap();
        std::fs::write(root.join("b.txt"), b"nothing to see").unwrap();
        std::fs::write(root.join("sub/c.txt"), b"another NEEDLE").unwrap();

        static SEEN: Mutex<Vec<(String, u64)>> = Mutex::new(Vec::new());
        extern "C" fn on_found(_ctx: *mut c_void, rel: *const c_char, offset: u64, _len: u64) {
            let s = unsafe { CStr::from_ptr(rel) }.to_string_lossy().into_owned();
            SEEN.lock().unwrap().push((s, offset));
        }

        let root_c = std::ffi::CString::new(root.to_str().unwrap()).unwrap();
        let needle = b"needle";
        let params = NcContentParams {
            root: root_c.as_ptr(),
            needle: needle.as_ptr() as *const c_char,
            needle_len: needle.len() as u32,
            options: NC_CONTENT_CASE_INSENSITIVE,
            threads: 2,
            max_file_size: 0,
        };
        let mut stats = NcContentStats::default();
        assert_eq!(
            nc_core_search_content(
                &params,
                Some(on_found),
                std::ptr::null_mut(),
                std::ptr::null(),
                &mut stats
            ),
            NC_OK
        );
        let mut seen = SEEN.lock().unwrap().clone();
        seen.sort();
        assert_eq!(
            seen,
            vec![("a.txt".to_string(), 4), ("sub/c.txt".to_string(), 8)]
        );
        assert_eq!(stats.matches, 2);
        assert_eq!(stats.files_scanned, 3);

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn respects_the_size_limit() {
        let root = std::env::temp_dir().join(format!("nc_content_size_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join("small.txt"), b"needle").unwrap();
        std::fs::write(root.join("big.txt"), vec![b'x'; 64]).unwrap();

        let root_c = std::ffi::CString::new(root.to_str().unwrap()).unwrap();
        let needle = b"needle";
        let params = NcContentParams {
            root: root_c.as_ptr(),
            needle: needle.as_ptr() as *const c_char,
            needle_len: needle.len() as u32,
            options: 0,
            threads: 1,
            max_file_size: 32,
        };
        let mut stats = NcContentStats::default();
        assert_eq!(
            nc_core_search_content(&params, None, std::ptr::null_mut(), std::ptr::null(), &mut stats),
            NC_OK
        );
        assert_eq!(stats.files_skipped, 1);
        let _ = std::fs::remove_dir_all(&root);
    }
}

