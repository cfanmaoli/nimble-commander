// Copyright (C) 2021-2026 Michael Kazakov. Subject to GNU General Public License version 3.
#include "Trash.h"
#include <RoutedIO/Trash.h>
#include <Foundation/Foundation.h>
#include <CoreFoundation/CoreFoundation.h>
#include <Base/CFPtr.h>
#include <cerrno>
#include <copyfile.h>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dirent.h>
#include <fcntl.h>
#include <filesystem>
#include <string_view>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <unistd.h>
#include <unordered_map>

namespace nc::routedio {

namespace {
// Closes a descriptor on scope exit. The errno of a failed operation is kept intact: close()
// itself may fail and overwrite it, and the callers report the original error.
class ScopedFd
{
public:
    explicit ScopedFd(const int _fd) noexcept : m_Fd(_fd) {}
    ScopedFd(const ScopedFd &) = delete;
    ScopedFd &operator=(const ScopedFd &) = delete;
    ~ScopedFd() noexcept { Reset(); }

    void Reset() noexcept
    {
        if( m_Fd < 0 )
            return;
        const int error = errno;
        ::close(m_Fd);
        errno = error;
        m_Fd = -1;
    }

private:
    int m_Fd;
};

constexpr const char *g_OriginalPathAttr = "info.filesmanager.trash.originalPath";

std::string Utf16BeToUtf8(const uint8_t *_data, size_t _chars)
{
    if( _chars == 0 )
        return {};
    nc::base::CFPtr<CFStringRef> str = nc::base::CFPtr<CFStringRef>::adopt(
        CFStringCreateWithBytes(nullptr, _data, static_cast<CFIndex>(_chars) * 2, kCFStringEncodingUTF16BE, false));
    if( !str )
        return {};
    const CFIndex len = CFStringGetLength(str.get());
    const CFIndex max_size = CFStringGetMaximumSizeForEncoding(len, kCFStringEncodingUTF8) + 1;
    std::string result(static_cast<size_t>(max_size), '\0');
    if( !CFStringGetCString(str.get(), result.data(), max_size, kCFStringEncodingUTF8) )
        return {};
    result.resize(std::char_traits<char>::length(result.data()));
    return result;
}

struct PutBackLocation {
    std::string parent;
    std::string name;
};

// A minimal reader for the .DS_Store files that the Finder keeps in folders. Only the put-back
// locations are of interest: they are stored as 'ptbL' (the original parent folder) and 'ptbN'
// (the original file name) string records.
class DsStoreParser
{
public:
    DsStoreParser(const std::string &_path) { Load(_path); }

    [[nodiscard]] std::unordered_map<std::string, PutBackLocation> PutBackLocations() const;

private:
    bool Load(const std::string &_path);
    bool ParseBlock(uint32_t _block);
    bool ReadRecord(size_t &_pos, std::string &_name, std::string &_code, std::string &_ustr) const;

    [[nodiscard]] bool Bounds(size_t _pos, size_t _len) const
    {
        return _pos <= m_Data.size() && _len <= m_Data.size() - _pos;
    }
    [[nodiscard]] uint32_t U32(size_t _pos) const;

    std::vector<uint8_t> m_Data;
    std::vector<uint32_t> m_BlockAddresses;
    std::unordered_map<std::string, PutBackLocation> m_Locations;
};

constexpr uint32_t Align256(uint32_t _value)
{
    return (_value + 255) & ~255u;
}

uint32_t DsStoreParser::U32(size_t _pos) const
{
    if( !Bounds(_pos, 4) )
        return 0;
    return (static_cast<uint32_t>(m_Data[_pos]) << 24) | (static_cast<uint32_t>(m_Data[_pos + 1]) << 16) |
           (static_cast<uint32_t>(m_Data[_pos + 2]) << 8) | static_cast<uint32_t>(m_Data[_pos + 3]);
}

bool DsStoreParser::Load(const std::string &_path)
{
    FILE *const file = std::fopen(_path.c_str(), "rb");
    if( file == nullptr )
        return false;
    std::fseek(file, 0, SEEK_END);
    const long size = std::ftell(file);
    std::fseek(file, 0, SEEK_SET);
    if( size <= 0 || size > 64L * 1024 * 1024 ) {
        std::fclose(file);
        return false;
    }
    m_Data.resize(static_cast<size_t>(size));
    const size_t read = std::fread(m_Data.data(), 1, m_Data.size(), file);
    std::fclose(file);
    if( read != m_Data.size() )
        return false;

    // Header: magic, 'Bud1', root block offset, root block size, mirrored offset.
    if( m_Data.size() < 32 || U32(0) != 1 )
        return false;
    if( std::memcmp(m_Data.data() + 4, "Bud1", 4) != 0 )
        return false;
    const uint32_t root_offset = U32(8);
    const uint32_t root_size = U32(12);
    if( U32(16) != root_offset || !Bounds(root_offset, root_size) )
        return false;

    // The payload of a buddy block starts four bytes past its address, which is why the root
    // block's fields are read with a '+4' - and the offsets array starts at '+12'.
    const uint32_t block_count = U32(root_offset + 4);
    if( block_count == 0 || block_count > 1'000'000 )
        return false;
    const uint32_t padded_count = Align256(block_count);
    const size_t addresses_pos = static_cast<size_t>(root_offset) + 12;
    if( !Bounds(addresses_pos, static_cast<size_t>(padded_count) * 4) )
        return false;
    m_BlockAddresses.resize(block_count);
    for( uint32_t i = 0; i < block_count; ++i )
        m_BlockAddresses[i] = U32(addresses_pos + (static_cast<size_t>(i) * 4));

    // Every block is inspected on its own: leaf blocks parse as a plain list of records, while
    // internal ones simply fail to parse and get skipped. This keeps the code independent of
    // the B-tree metadata, which is not always consistent between writers.
    for( uint32_t i = 0; i < block_count; ++i )
        ParseBlock(i);
    return true;
}

bool DsStoreParser::ParseBlock(uint32_t _block)
{
    if( _block >= m_BlockAddresses.size() )
        return false;
    const uint32_t address = m_BlockAddresses[_block];
    const uint32_t offset = (address & ~0x1Fu) + 4;
    if( !Bounds(offset, 8) )
        return false;
    const uint32_t count = U32(offset + 4);
    if( count == 0 || count > 1'000'000 )
        return false;
    size_t pos = static_cast<size_t>(offset) + 8;

    struct Record {
        std::string name;
        std::string code;
        std::string value;
    };
    std::vector<Record> records;
    records.reserve(count);
    for( uint32_t i = 0; i < count; ++i ) {
        Record record;
        if( !ReadRecord(pos, record.name, record.code, record.value) )
            return false;
        records.push_back(std::move(record));
    }

    for( const Record &record : records ) {
        if( (record.code == "ptbL" || record.code == "ptbN") && !record.value.empty() ) {
            PutBackLocation &location = m_Locations[record.name];
            if( record.code == "ptbL" )
                location.parent = record.value;
            else
                location.name = record.value;
        }
    }
    return true;
}

bool DsStoreParser::ReadRecord(size_t &_pos, std::string &_name, std::string &_code, std::string &_ustr) const
{
    if( !Bounds(_pos, 4) )
        return false;
    const uint32_t name_len = U32(_pos);
    _pos += 4;
    if( name_len > 1'000'000 || !Bounds(_pos, (static_cast<size_t>(name_len) * 2) + 8) )
        return false;
    _name = Utf16BeToUtf8(m_Data.data() + _pos, name_len);
    _pos += static_cast<size_t>(name_len) * 2;
    _code.assign(reinterpret_cast<const char *>(m_Data.data() + _pos), 4);
    _pos += 4;
    const std::string type(reinterpret_cast<const char *>(m_Data.data() + _pos), 4);
    _pos += 4;
    _ustr.clear();

    if( type == "ustr" ) {
        if( !Bounds(_pos, 4) )
            return false;
        const uint32_t len = U32(_pos);
        _pos += 4;
        if( !Bounds(_pos, static_cast<size_t>(len) * 2) )
            return false;
        _ustr = Utf16BeToUtf8(m_Data.data() + _pos, len);
        _pos += static_cast<size_t>(len) * 2;
    }
    else if( type == "blob" ) {
        if( !Bounds(_pos, 4) )
            return false;
        const uint32_t len = U32(_pos);
        _pos += 4;
        if( !Bounds(_pos, len) )
            return false;
        _pos += len;
    }
    else if( type == "bool" ) {
        if( !Bounds(_pos, 1) )
            return false;
        _pos += 1;
    }
    else if( type == "long" || type == "shor" || type == "type" ) {
        if( !Bounds(_pos, 4) )
            return false;
        _pos += 4;
    }
    else if( type == "comp" || type == "dutc" ) {
        if( !Bounds(_pos, 8) )
            return false;
        _pos += 8;
    }
    else {
        return false;
    }
    return true;
}

std::unordered_map<std::string, PutBackLocation> DsStoreParser::PutBackLocations() const
{
    return m_Locations;
}

std::string JoinPath(const std::string &_parent, const std::string &_name)
{
    if( _parent.empty() )
        return _name;
    if( _parent.back() == '/' )
        return _parent + _name;
    return _parent + "/" + _name;
}

// Checks that the path can be trusted as a trash folder. Trash folders come from mountable media,
// so a symlink or a mount point there must never be followed: emptying such a "trash" would delete
// through to an arbitrary directory.
bool IsValidTrashDirectory(const std::string &_path)
{
    const int fd = detail::OpenTrashDirectory(_path, false);
    if( fd < 0 )
        return false;
    ::close(fd);
    return true;
}

// Reads an extended attribute of the entry itself - a symlink is not followed.
bool ReadAttribute(const std::string &_path, const char *_name, std::string &_value)
{
    const ssize_t size = getxattr(_path.c_str(), _name, nullptr, 0, 0, XATTR_NOFOLLOW);
    if( size <= 0 || size > 1024L * 1024 )
        return false;
    _value.assign(static_cast<size_t>(size), '\0');
    const ssize_t result = getxattr(_path.c_str(), _name, _value.data(), _value.size(), 0, XATTR_NOFOLLOW);
    if( result != size ) {
        _value.clear();
        return false;
    }
    return true;
}

// How many numbered names a put-back is willing to try before it reports a failure.
constexpr int kMaxTargetCandidates = 10'000;

// The name to use when the original one is taken: 'report.pdf' -> 'report 2.pdf'.
std::string NumberedTarget(const std::string &_target, const int _index)
{
    const std::filesystem::path path(_target);
    std::string filename = path.stem().string();
    filename += ' ';
    filename += std::to_string(_index);
    filename += path.extension().string();
    return (path.parent_path() / filename).string();
}

// Renames without ever replacing an existing entry. RENAME_EXCL makes the check and the move a
// single atomic operation, so another process can't slip an entry in between them. A filesystem
// that can't provide that guarantee makes the restore fail instead - silently replacing an entry
// with a plain rename() is not an acceptable fallback for user data.
int RenameExclusive(const std::string &_from, const std::string &_to)
{
    if( renamex_np(_from.c_str(), _to.c_str(), RENAME_EXCL) == 0 )
        return 0;
    return errno;
}

// Copies the extended attributes of the entry itself, without following a symlink.
int CopyAttributes(const std::string &_from, const std::string &_to)
{
    const ssize_t list_size = listxattr(_from.c_str(), nullptr, 0, XATTR_NOFOLLOW);
    if( list_size < 0 )
        return errno;
    if( list_size == 0 )
        return 0;

    std::vector<char> names(static_cast<size_t>(list_size));
    const ssize_t names_size = listxattr(_from.c_str(), names.data(), names.size(), XATTR_NOFOLLOW);
    if( names_size < 0 )
        return errno;
    for( size_t pos = 0; pos < static_cast<size_t>(names_size); ) {
        const std::string name{names.data() + pos};
        pos += name.size() + 1;
        if( name.empty() )
            continue;
        const ssize_t value_size = getxattr(_from.c_str(), name.c_str(), nullptr, 0, 0, XATTR_NOFOLLOW);
        if( value_size < 0 )
            return errno;
        if( value_size > 64L * 1024 * 1024 )
            return EFBIG;
        std::vector<char> value(static_cast<size_t>(value_size));
        if( getxattr(_from.c_str(), name.c_str(), value.data(), value.size(), 0, XATTR_NOFOLLOW) != value_size )
            return errno;
        if( setxattr(_to.c_str(), name.c_str(), value.data(), value.size(), 0, XATTR_NOFOLLOW) != 0 )
            return errno;
    }
    return 0;
}

int CopyEntry(const std::string &_from,
              const std::string &_to,
              bool &_created,
              const std::function<bool()> &_cancel_checker);

int CopyDirectory(const std::string &_from,
                  const std::string &_to,
                  bool &_created,
                  const std::function<bool()> &_cancel_checker)
{
    if( _cancel_checker && _cancel_checker() )
        return ECANCELED;

    // Owner access first: the source mode can be read-only (0500), while the children still have
    // to be written. The final mode, ACL and times are applied below, once the tree is complete.
    if( mkdir(_to.c_str(), 0700) != 0 )
        return errno;
    _created = true;

    DIR *const dir = opendir(_from.c_str());
    if( dir == nullptr )
        return errno;

    // NC_TRASH_TEST_READDIR_EIO is a test hook: it makes the enumeration fail after the first entry
    // so that the error path can be exercised deterministically. It has no effect unless set.
    const bool fail_readdir = std::getenv("NC_TRASH_TEST_READDIR_EIO") != nullptr;
    int result = 0;
    int entries_read = 0;
    for( ;; ) {
        errno = 0;
        if( fail_readdir && entries_read > 0 ) {
            result = EIO;
            break;
        }
        const dirent *const entry = readdir(dir);
        if( entry == nullptr ) {
            // A NULL can mean both "end of the listing" and "the listing failed" - the two have to
            // be told apart, otherwise an incomplete copy is treated as a complete one.
            if( errno != 0 )
                result = errno;
            break;
        }
        ++entries_read;
        const std::string name = entry->d_name;
        if( name == "." || name == ".." )
            continue;
        std::string child_from = _from;
        child_from += '/';
        child_from += name;
        std::string child_to = _to;
        child_to += '/';
        child_to += name;
        if( _cancel_checker && _cancel_checker() ) {
            result = ECANCELED;
            break;
        }
        bool child_created = false;
        const int rc = CopyEntry(child_from, child_to, child_created, _cancel_checker);
        // A conflict with an entry that appeared inside a folder this call has just created is a
        // race, not a taken top-level name - the caller has to drop the partial tree.
        result = rc == EEXIST ? EIO : rc;
        if( result != 0 )
            break;
    }
    if( closedir(dir) != 0 && result == 0 )
        result = errno;
    if( result != 0 )
        return result;

    // The children are in place - bring the directory's own mode, times, ACL and extended
    // attributes over. This also restores a read-only source directory's final permissions.
    if( copyfile(_from.c_str(), _to.c_str(), nullptr, COPYFILE_METADATA) != 0 )
        return errno;
    return 0;
}

// Copies one entry, which must not exist yet. '_created' reports whether this call created the
// destination entry - the staging cleanup relies on it, so that a failure before the creation
// can't remove anything that belongs to somebody else. Directories are walked by hand so that
// every child gets the full metadata treatment; copyfile() itself only handles files.
int CopyEntry(const std::string &_from,
              const std::string &_to,
              bool &_created,
              const std::function<bool()> &_cancel_checker)
{
    _created = false;

    if( _cancel_checker && _cancel_checker() )
        return ECANCELED;

    struct stat st;
    if( lstat(_from.c_str(), &st) != 0 )
        return errno;

    if( S_ISLNK(st.st_mode) ) {
        std::string target;
        std::vector<char> buffer(1024);
        for( ;; ) {
            const ssize_t length = readlink(_from.c_str(), buffer.data(), buffer.size());
            if( length < 0 )
                return errno;
            if( static_cast<size_t>(length) < buffer.size() ) {
                target.assign(buffer.data(), static_cast<size_t>(length));
                break;
            }
            if( buffer.size() >= size_t{64} * 1024 )
                return ENAMETOOLONG;
            buffer.resize(buffer.size() * 2);
        }
        if( symlink(target.c_str(), _to.c_str()) != 0 )
            return errno;
        _created = true;
        if( const int rc = CopyAttributes(_from, _to); rc != 0 )
            return rc;
        const struct timespec times[2] = {st.st_atimespec, st.st_mtimespec};
        if( utimensat(AT_FDCWD, _to.c_str(), times, AT_SYMLINK_NOFOLLOW) != 0 )
            return errno;
        return 0;
    }
    if( S_ISDIR(st.st_mode) )
        return CopyDirectory(_from, _to, _created, _cancel_checker);
    if( S_ISREG(st.st_mode) ) {
        // Claim the name first: then a failed copy still leaves an entry this call owns, and the
        // cleanup can never be confused with an entry that was already there.
        const int fd = open(_to.c_str(), O_WRONLY | O_CREAT | O_EXCL, 0600);
        if( fd < 0 )
            return errno;
        close(fd);
        _created = true;
        // COPYFILE_ALL carries the data, the resource fork, the ACL and the extended attributes
        // (Finder tags, the quarantine flag, ...) over onto the claimed file.
        if( copyfile(_from.c_str(), _to.c_str(), nullptr, COPYFILE_ALL) != 0 )
            return errno;
        return 0;
    }
    if( S_ISFIFO(st.st_mode) ) {
        if( mkfifo(_to.c_str(), st.st_mode & 07777) != 0 )
            return errno;
        _created = true;
        return chmod(_to.c_str(), st.st_mode & 07777) == 0 ? 0 : errno;
    }
    if( S_ISCHR(st.st_mode) || S_ISBLK(st.st_mode) ) {
        if( mknod(_to.c_str(), st.st_mode, st.st_rdev) != 0 )
            return errno;
        _created = true;
        return 0;
    }
    return EOPNOTSUPP; // sockets and anything unknown can't be recreated by copying
}

// A hidden staging name next to '_target'. The copy is built there and only then committed with an
// exclusive rename, so the final name is never written to and the commit stays on one filesystem.
std::string StagingPath(const std::string &_target, const int _attempt)
{
    const std::filesystem::path target(_target);
    std::string name = ".nc-restore-";
    name += std::to_string(getpid());
    name += '-';
    name += std::to_string(_attempt);
    return (target.parent_path() / name).string();
}

// Copies the entry into a fresh staging name next to '_target' and claims '_target' with an
// atomic, non-replacing rename. Returns 0, EEXIST when the name is taken, or an errno. Whatever
// already occupies '_target' is never touched, and a failure only removes the staging copy.
int CopyEntryExclusive(const std::string &_from, const std::string &_to, const std::function<bool()> &_cancel_checker)
{
    constexpr int kMaxStagingAttempts = 32;
    for( int attempt = 0; attempt != kMaxStagingAttempts; ++attempt ) {
        const std::string staging = StagingPath(_to, attempt);
        bool created = false;
        const int copy_rc = CopyEntry(_from, staging, created, _cancel_checker);
        if( copy_rc == EEXIST )
            continue; // the staging name is taken as well - try the next one
        if( copy_rc != 0 ) {
            if( created ) {
                const int cleanup_rc = detail::RemoveStagingTree(staging);
                if( cleanup_rc != 0 )
                    return cleanup_rc;
            }
            return copy_rc;
        }

        const int commit_rc = RenameExclusive(staging, _to);
        if( commit_rc == 0 )
            return 0;
        const int cleanup_rc = detail::RemoveStagingTree(staging);
        if( cleanup_rc != 0 )
            return cleanup_rc;
        return commit_rc;
    }
    return EEXIST;
}

// Removes the recorded original location from the entry itself - with the default flags a symlink
// would hand the operation to the file it points at.
void RemoveOriginalPathAttribute(const std::string &_path) noexcept
{
    removexattr(_path.c_str(), g_OriginalPathAttr, XATTR_NOFOLLOW);
}

} // namespace

namespace detail {

int OpenTrashDirectory(const std::string &_path, const bool _read_contents)
{
    std::filesystem::path path(_path);
    // Discard trailing separators without normalizing away a component that could be a link.
    while( path != path.root_path() && path.filename().empty() )
        path = path.parent_path();
    if( !path.is_absolute() || path == path.root_path() || path.filename() == "." || path.filename() == ".." ) {
        errno = EINVAL;
        return -1;
    }

    const auto parent = path.parent_path();
    const auto ancestor = parent == parent.root_path() ? parent : parent.parent_path();
    constexpr int flags = O_RDONLY | O_NONBLOCK | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC;
    // The shared .Trashes directory normally grants search but not read access (01333).
    // Only the user's final trash directory needs to be readable for enumeration.
    constexpr int search_flags = O_SEARCH | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC;
    const int ancestor_fd = ::open(ancestor.c_str(), search_flags);
    if( ancestor_fd < 0 )
        return -1;
    // close() must not overwrite the error reported by a failed openat()/fstat().
    const ScopedFd close_ancestor{ancestor_fd};
    const std::string parent_name = parent == parent.root_path() ? "." : parent.filename().string();
    if( parent_name == ".." ) {
        errno = EINVAL;
        return -1;
    }
    const int parent_fd = ::openat(ancestor_fd, parent_name.c_str(), search_flags);
    if( parent_fd < 0 )
        return -1;
    const ScopedFd close_parent{parent_fd};

    const int fd = ::openat(parent_fd, path.filename().c_str(), _read_contents ? flags : search_flags);
    if( fd < 0 )
        return -1;
    struct stat parent_st;
    struct stat st;
    if( ::fstat(parent_fd, &parent_st) != 0 || ::fstat(fd, &st) != 0 ) {
        const int error = errno;
        ::close(fd);
        errno = error;
        return -1;
    }
    if( st.st_uid != getuid() || st.st_dev != parent_st.st_dev ) {
        ::close(fd);
        errno = EINVAL;
        return -1;
    }
    return fd;
}

const char *const kOriginalLocationAttribute = g_OriginalPathAttr;

int RemoveStagingTree(const std::string &_staging) noexcept
{
    // The copy may have inherited read-only directory modes from the source (e.g. 0500), which
    // would keep remove_all() from deleting the children, so owner write access is restored on
    // every directory first.
    struct stat st;
    if( ::lstat(_staging.c_str(), &st) == 0 && S_ISDIR(st.st_mode) ) {
        std::error_code ec;
        for( std::filesystem::recursive_directory_iterator
                 it{_staging, std::filesystem::directory_options::skip_permission_denied, ec},
             end;
             !ec && it != end;
             it.increment(ec) ) {
            // Both the query and the permission change must address the entry itself. A
            // directory symlink can point outside the staging tree, and a dangling link must
            // not stop the traversal before the remaining read-only directories are handled.
            if( std::filesystem::is_directory(it->symlink_status(ec)) )
                ::fchmodat(AT_FDCWD, it->path().c_str(), 0700, AT_SYMLINK_NOFOLLOW);
        }
        ::fchmodat(AT_FDCWD, _staging.c_str(), 0700, AT_SYMLINK_NOFOLLOW);
    }
    std::error_code ec;
    std::filesystem::remove_all(_staging, ec);
    return ec ? ec.value() : 0;
}

} // namespace detail

std::string TrashDirectory()
{
    NSString *const home = NSHomeDirectory();
    return home == nil ? std::string{} : std::string{home.UTF8String} + "/.Trash";
}

std::vector<std::string> TrashLocations()
{
    std::vector<std::string> locations;
    const std::string home_trash = TrashDirectory();
    if( IsValidTrashDirectory(home_trash) )
        locations.push_back(home_trash);

    // Every mounted local volume has its own per-user trash folder.
    const std::string uid = std::to_string(getuid());
    struct statfs *mounts = nullptr;
    const int count = getmntinfo(&mounts, MNT_NOWAIT);
    for( int i = 0; i < count; ++i ) {
        const std::string mount = mounts[i].f_mntonname;
        if( mount == "/" || !(mounts[i].f_flags & MNT_LOCAL) )
            continue;
        std::string trash = mount;
        trash += "/.Trashes/";
        trash += uid;
        if( IsValidTrashDirectory(trash) )
            locations.push_back(trash);
    }
    return locations;
}

std::string TrashContaining(const std::string &_path)
{
    std::string result;
    for( const std::string &location : TrashLocations() ) {
        if( _path == location || _path.starts_with(location + "/") ) {
            if( location.size() > result.size() )
                result = location;
        }
    }
    return result;
}

std::string TrashForVolumeOf(const std::string &_path)
{
    if( _path.empty() || _path.front() != '/' )
        return TrashDirectory();

    struct statfs *mounts = nullptr;
    const int count = getmntinfo(&mounts, MNT_NOWAIT);
    std::string best_mount;
    for( int i = 0; i < count; ++i ) {
        const std::string mount = mounts[i].f_mntonname;
        if( _path == mount || _path.starts_with(mount == "/" ? mount : mount + "/") ) {
            if( mount.size() > best_mount.size() )
                best_mount = mount;
        }
    }
    if( best_mount.empty() || best_mount == "/" )
        return TrashDirectory();

    std::string trash = best_mount;
    trash += "/.Trashes/";
    trash += std::to_string(getuid());
    return IsValidTrashDirectory(trash) ? trash : std::string{};
}

bool IsTrashDirectory(const std::string &_path)
{
    for( const std::string &location : TrashLocations() )
        if( _path == location )
            return true;
    return false;
}

bool IsInsideTrash(const std::string &_path)
{
    return !TrashContaining(_path).empty();
}

std::vector<std::string> ListTrashDirectory(const std::string &_directory, int &_error)
{
    _error = 0;
    std::vector<std::string> result;
    DIR *const dir = opendir(_directory.c_str());
    if( dir == nullptr ) {
        _error = errno;
        return result;
    }
    while( const dirent *const entry = readdir(dir) ) {
        const std::string name = entry->d_name;
        if( name == "." || name == ".." || name == ".DS_Store" )
            continue;
        std::string path = _directory;
        path += '/';
        path += name;
        result.push_back(std::move(path));
    }
    closedir(dir);
    return result;
}

std::optional<std::string> OriginalLocationFromDsStore(const std::string &_ds_store_path, const std::string &_filename)
{
    DsStoreParser parser(_ds_store_path);
    const auto locations = parser.PutBackLocations();
    const auto it = locations.find(_filename);
    if( it == locations.end() || it->second.parent.empty() || it->second.name.empty() )
        return std::nullopt;
    return JoinPath(it->second.parent, it->second.name);
}

std::optional<std::string> OriginalLocationOfTrashedItem(const std::string &_trash_item_path)
{
    std::string recorded;
    if( ReadAttribute(_trash_item_path, g_OriginalPathAttr, recorded) && !recorded.empty() )
        return recorded;

    const std::filesystem::path item(_trash_item_path);
    const std::string filename = item.filename().string();
    if( filename.empty() )
        return std::nullopt;
    const std::string trash = TrashContaining(_trash_item_path);
    return OriginalLocationFromDsStore((trash.empty() ? TrashDirectory() : trash) + "/.DS_Store", filename);
}

void RememberOriginalLocation(const std::string &_path)
{
    if( _path.empty() || _path.front() != '/' )
        return;
    if( IsInsideTrash(_path) )
        return;
    // Store the attribute on the entry itself: with the default flags a symlink would get the
    // attribute of the file it points at, which isn't the object being trashed.
    setxattr(_path.c_str(), g_OriginalPathAttr, _path.data(), _path.size(), 0, XATTR_NOFOLLOW);
}

PutBackResult PutBackTrashedItem(const std::string &_trash_item_path, const std::function<bool()> &_cancel_checker)
{
    PutBackResult result;

    if( _trash_item_path.empty() || _trash_item_path.front() != '/' ) {
        result.error = EINVAL;
        return result;
    }

    const std::optional<std::string> original = OriginalLocationOfTrashedItem(_trash_item_path);
    if( !original ) {
        result.error = ENOENT;
        return result;
    }

    // The recorded location comes from an extended attribute or from the Trash's .DS_Store - both
    // are writable by anything running as this user, and the latter also comes from whatever volume
    // the trash folder belongs to. Only a normalized absolute path outside of every trash folder is
    // accepted, so a crafted marker can't "restore" an item to an arbitrary relative location.
    std::filesystem::path target_path = std::filesystem::path(*original).lexically_normal();
    const std::string target_string = target_path.string();
    if( !target_path.is_absolute() || target_string == target_path.root_path().string() ||
        IsInsideTrash(target_string) || target_string == _trash_item_path ||
        target_string.starts_with(_trash_item_path + '/') ) {
        result.error = EINVAL;
        return result;
    }

    if( _cancel_checker && _cancel_checker() ) {
        result.error = ECANCELED;
        return result;
    }

    if( target_path.has_parent_path() ) {
        std::error_code ec;
        std::filesystem::create_directories(target_path.parent_path(), ec);
        if( ec ) {
            result.error = ec.value() != 0 ? ec.value() : EIO;
            return result;
        }
        // The lexical check above can be fooled by a symlinked path component: resolve the parent -
        // it exists now - and check where the item would really land. The resolved path is also what
        // the rename is given, so the validated location is the written one.
        std::error_code canonical_ec;
        const std::filesystem::path resolved_parent =
            std::filesystem::canonical(target_path.parent_path(), canonical_ec);
        if( canonical_ec ) {
            result.error = canonical_ec.value() != 0 ? canonical_ec.value() : EIO;
            return result;
        }
        target_path = resolved_parent / target_path.filename();
        if( IsInsideTrash(target_path.string()) ) {
            result.error = EINVAL;
            return result;
        }
    }

    // Walk the numbered names until one of them can be claimed. Claiming and placing the item are
    // the same operation, so a taken name is reported as EEXIST instead of silently overwriting.
    const std::string requested = target_path.string();
    bool cross_volume = false;
    for( int i = 1; i <= kMaxTargetCandidates; ++i ) {
        const std::string candidate = i == 1 ? requested : NumberedTarget(requested, i);

        int rc = 0;
        if( cross_volume ) {
            rc = CopyEntryExclusive(_trash_item_path, candidate, _cancel_checker);
        }
        else {
            rc = RenameExclusive(_trash_item_path, candidate);
            if( rc == EXDEV ) {
                // The trash and the original location sit on different volumes - copy the item.
                cross_volume = true;
                rc = CopyEntryExclusive(_trash_item_path, candidate, _cancel_checker);
            }
        }

        if( rc == 0 ) {
            if( cross_volume ) {
                // The copy is in place, so the restore itself has succeeded. Dropping the source
                // is best effort from here on, but the failure still has to be reported.
                std::error_code remove_ec;
                std::filesystem::remove_all(_trash_item_path, remove_ec);
                result.source_remains = static_cast<bool>(remove_ec);
            }
            result.restored = true;
            result.resulting_path = candidate;
            RemoveOriginalPathAttribute(candidate);
            return result;
        }
        if( rc == EEXIST )
            continue;

        result.error = rc;
        return result;
    }

    result.error = EEXIST;
    return result;
}

int TrashItemAtPath(const char *_path) noexcept
{
    if( _path == nullptr ) {
        errno = EINVAL;
        return -1;
    }
    RememberOriginalLocation(_path);

    const auto url = nc::base::CFPtr<CFURLRef>::adopt(CFURLCreateFromFileSystemRepresentation(
        nullptr, reinterpret_cast<const UInt8 *>(_path), std::string_view{_path}.length(), false));

    if( !url ) {
        errno = ENOENT;
        return -1;
    }

    NSError *error;
    const auto result = [NSFileManager.defaultManager trashItemAtURL:(__bridge NSURL *)url.get()
                                                    resultingItemURL:nil
                                                               error:&error];

    if( result ) {
        return 0;
    }
    else {
        if( error != nil && [error.domain isEqualToString:NSPOSIXErrorDomain] ) {
            errno = static_cast<int>(error.code);
        }
        else {
            errno = EPERM;
        }
        return -1;
    }
}

} // namespace nc::routedio
