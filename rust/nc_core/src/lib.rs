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
