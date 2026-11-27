// Copyright (C) 2014-2026 Michael Kazakov. Subject to GNU General Public License version 3.
#include <Base/CFPtr.h>
#include <cassert>
#include <cerrno>
#include <csignal>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <string_view>
#include <dirent.h>
#include <ftw.h>
#include <sys/mount.h>
#include <sys/param.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include "RoutedIOInterfaces.h"
#include <RoutedIO/Trash.h>

// hack to access function from libc implementation directly.
// this func does readdir but without mutex locking
struct dirent *_readdir_unlocked(DIR *, int) __DARWIN_INODE64(_readdir_unlocked);

namespace nc::routedio {

static const uid_t g_UID = getuid();
static const gid_t g_GID = getgid();

// trivial wrappers
bool PosixIOInterfaceNative::isrouted() const noexcept
{
    return false;
}
int PosixIOInterfaceNative::open(const char *_path, int _flags, int _mode) noexcept
{
    return ::open(_path, _flags, _mode);
}

int PosixIOInterfaceNative::close(int _fd) noexcept
{
    return ::close(_fd);
}

ssize_t PosixIOInterfaceNative::read(int _fildes, void *_buf, size_t _nbyte) noexcept
{
    return ::read(_fildes, _buf, _nbyte);
}

ssize_t PosixIOInterfaceNative::write(int _fildes, const void *_buf, size_t _nbyte) noexcept
{
    return ::write(_fildes, _buf, _nbyte);
}

off_t PosixIOInterfaceNative::lseek(int _fd, off_t _offset, int _whence) noexcept
{
    return ::lseek(_fd, _offset, _whence);
}

DIR *PosixIOInterfaceNative::opendir(const char *_path) noexcept
{
    return ::opendir(_path);
}

int PosixIOInterfaceNative::closedir(DIR *_dir) noexcept
{
    return ::closedir(_dir);
}

dirent *PosixIOInterfaceNative::readdir(DIR *_dir) noexcept
{
    return ::_readdir_unlocked(_dir, 1);
}

int PosixIOInterfaceNative::stat(const char *_path, struct ::stat *_st) noexcept
{
    return ::stat(_path, _st);
}

int PosixIOInterfaceNative::lstat(const char *_path, struct ::stat *_st) noexcept
{
    return ::lstat(_path, _st);
}

int PosixIOInterfaceNative::mkdir(const char *_path, mode_t _mode) noexcept
{
    return ::mkdir(_path, _mode);
}

int PosixIOInterfaceNative::chown(const char *_path, uid_t _uid, gid_t _gid) noexcept
{
    return ::chown(_path, _uid, _gid);
}

int PosixIOInterfaceNative::chflags(const char *_path, u_int _flags) noexcept
{
    return ::chflags(_path, _flags);
}

int PosixIOInterfaceNative::lchflags(const char *_path, u_int _flags) noexcept
{
    return ::lchflags(_path, _flags);
}

int PosixIOInterfaceNative::rmdir(const char *_path) noexcept
{
    return ::rmdir(_path);
}

int PosixIOInterfaceNative::unlink(const char *_path) noexcept
{
    return ::unlink(_path);
}

int PosixIOInterfaceNative::rename(const char *_old, const char *_new) noexcept
{
    return ::rename(_old, _new);
}

ssize_t PosixIOInterfaceNative::readlink(const char *_path, char *_symlink, size_t _buf_sz) noexcept
{
    return ::readlink(_path, _symlink, _buf_sz);
}

int PosixIOInterfaceNative::symlink(const char *_value, const char *_symlink_path) noexcept
{
    return ::symlink(_value, _symlink_path);
}

int PosixIOInterfaceNative::link(const char *_path_exist, const char *_path_newnode) noexcept
{
    return ::link(_path_exist, _path_newnode);
}

int PosixIOInterfaceNative::chmod(const char *_path, mode_t _mode) noexcept
{
    return ::chmod(_path, _mode);
}

int PosixIOInterfaceNative::chmtime(const char *_path, time_t _time) noexcept
{
    return ApplyTimeChange(_path, _time, ATTR_CMN_MODTIME);
}

int PosixIOInterfaceNative::chatime(const char *_path, time_t _time) noexcept
{
    return ApplyTimeChange(_path, _time, ATTR_CMN_ACCTIME);
}

int PosixIOInterfaceNative::chctime(const char *_path, time_t _time) noexcept
{
    return ApplyTimeChange(_path, _time, ATTR_CMN_CHGTIME);
}

int PosixIOInterfaceNative::chbtime(const char *_path, time_t _time) noexcept
{
    return ApplyTimeChange(_path, _time, ATTR_CMN_CRTIME);
}

int PosixIOInterfaceNative::killpg(int _pid, int _signal) noexcept
{
    return ::killpg(_pid, _signal);
}

int PosixIOInterfaceNative::trash(const char *_path) noexcept
{
    return TrashItemAtPath(_path);
}

int PosixIOInterfaceNative::ApplyTimeChange(const char *_path, time_t _time, uint32_t _attr)
{
    struct attrlist attrs;
    memset(&attrs, 0, sizeof(attrs));
    attrs.bitmapcount = ATTR_BIT_MAP_COUNT;
    attrs.commonattr = _attr;
    timespec time = {.tv_sec = _time, .tv_nsec = 0};
    return setattrlist(_path, &attrs, &time, sizeof(time), 0);
}

static bool ShouldEscalateToHelper(const int _err) noexcept
{
    return _err == EACCES || _err == EPERM;
}

static int SendSimpleRequest(xpc_connection_t _conn, xpc_object_t _message, const int _fallback_err) noexcept
{
    xpc_object_t reply = xpc_connection_send_message_with_reply_sync(_conn, _message);
    xpc_release(_message);

    if( xpc_get_type(reply) == XPC_TYPE_ERROR ) {
        xpc_release(reply);
        errno = _fallback_err;
        return -1;
    }

    if( const auto err = xpc_dictionary_get_int64(reply, "error") ) {
        xpc_release(reply);
        errno = static_cast<int>(err);
        return -1;
    }

    if( !xpc_dictionary_get_bool(reply, "ok") ) {
        xpc_release(reply);
        errno = EIO;
        return -1;
    }

    xpc_release(reply);
    return 0;
}

static int SendStatRequest(xpc_connection_t _conn,
                           const char *_operation,
                           const char *_path,
                           struct ::stat *_st,
                           const int _fallback_err) noexcept
{
    xpc_object_t message = xpc_dictionary_create(nullptr, nullptr, 0);
    xpc_dictionary_set_string(message, "operation", _operation);
    xpc_dictionary_set_string(message, "path", _path);

    xpc_object_t reply = xpc_connection_send_message_with_reply_sync(_conn, message);
    xpc_release(message);

    if( xpc_get_type(reply) == XPC_TYPE_ERROR ) {
        xpc_release(reply);
        errno = _fallback_err;
        return -1;
    }

    if( const auto err = xpc_dictionary_get_int64(reply, "error") ) {
        xpc_release(reply);
        errno = static_cast<int>(err);
        return -1;
    }

    size_t st_size = 0;
    const void *v = xpc_dictionary_get_data(reply, "st", &st_size);
    if( v == nullptr || st_size != sizeof(struct ::stat) ) {
        xpc_release(reply);
        errno = EIO;
        return -1;
    }

    memcpy(_st, v, st_size);
    xpc_release(reply);
    return 0;
}

// Each routed POSIX method tries direct I/O first and escalates to the privileged helper only when
// direct access fails with EACCES or EPERM. On macOS, per-folder TCC grants (Removable Volumes,
// Network Volumes, Desktop, Documents, Downloads) belong to the app's user session (auid), whereas
// the privileged helper runs as a system LaunchDaemon (auid=0) and cannot inherit those grants.
// Trying direct I/O first uses the app's own TCC permissions, avoids unnecessary XPC round-trips
// and root-ownership fixups, and still escalates whenever root privileges are genuinely needed.

PosixIOInterfaceRouted::PosixIOInterfaceRouted(RoutedIO &_inst) : inst(_inst)
{
}

bool PosixIOInterfaceRouted::isrouted() const noexcept
{
    return inst.Enabled();
}

xpc_connection_t PosixIOInterfaceRouted::Connection()
{
    if( !inst.Enabled() )
        return nullptr;
    return inst.Connection();
}

int PosixIOInterfaceRouted::OpenViaHelper(xpc_connection_t _conn,
                                          const char *_path,
                                          int _flags,
                                          int _mode,
                                          const int _fallback_err) noexcept
{
    bool need_owner_fixup = false;
    if( (_flags & O_CREAT) != 0 ) {
        // Check if the call will create a new file so we can chown it back to ourselves afterwards.
        struct ::stat st;
        if( this->stat(_path, &st) != 0 )
            need_owner_fixup = true;
    }

    xpc_object_t message = xpc_dictionary_create(nullptr, nullptr, 0);
    xpc_dictionary_set_string(message, "operation", "open");
    xpc_dictionary_set_string(message, "path", _path);
    xpc_dictionary_set_int64(message, "flags", _flags);
    xpc_dictionary_set_int64(message, "mode", _mode);

    xpc_object_t reply = xpc_connection_send_message_with_reply_sync(_conn, message);
    xpc_release(message);

    if( xpc_get_type(reply) == XPC_TYPE_ERROR ) {
        xpc_release(reply);
        errno = _fallback_err;
        return -1;
    }

    if( const int64_t err = xpc_dictionary_get_int64(reply, "error") ) {
        xpc_release(reply);
        errno = static_cast<int>(err);
        return -1;
    }

    const int fd = xpc_dictionary_dup_fd(reply, "fd");
    xpc_release(reply);

    if( fd < 0 ) {
        errno = EIO;
        return -1;
    }

    if( need_owner_fixup )
        this->chown(_path, g_UID, -1);

    return fd;
}

int PosixIOInterfaceRouted::open(const char *_path, int _flags, int _mode) noexcept
{
    if( const int direct_fd = super::open(_path, _flags, _mode); direct_fd >= 0 )
        return direct_fd;

    const int direct_err = errno;
    if( !ShouldEscalateToHelper(direct_err) ) {
        errno = direct_err;
        return -1;
    }

    xpc_connection_t conn = Connection();
    if( !conn ) {
        errno = direct_err;
        return -1;
    }

    return OpenViaHelper(conn, _path, _flags, _mode, direct_err);
}

int PosixIOInterfaceRouted::stat(const char *_path, struct ::stat *_st) noexcept
{
    if( super::stat(_path, _st) == 0 )
        return 0;

    const int direct_err = errno;
    if( !ShouldEscalateToHelper(direct_err) ) {
        errno = direct_err;
        return -1;
    }

    xpc_connection_t conn = Connection();
    if( !conn ) {
        errno = direct_err;
        return -1;
    }

    return SendStatRequest(conn, "stat", _path, _st, direct_err);
}

int PosixIOInterfaceRouted::lstat(const char *_path, struct ::stat *_st) noexcept
{
    if( super::lstat(_path, _st) == 0 )
        return 0;

    const int direct_err = errno;
    if( !ShouldEscalateToHelper(direct_err) ) {
        errno = direct_err;
        return -1;
    }

    xpc_connection_t conn = Connection();
    if( !conn ) {
        errno = direct_err;
        return -1;
    }

    return SendStatRequest(conn, "lstat", _path, _st, direct_err);
}

int PosixIOInterfaceRouted::close(int _fd) noexcept
{
    return super::close(_fd);
}

DIR *PosixIOInterfaceRouted::opendir(const char *_path) noexcept
{
    if( DIR *const dir = super::opendir(_path) )
        return dir;

    const int direct_err = errno;
    if( !ShouldEscalateToHelper(direct_err) ) {
        errno = direct_err;
        return nullptr;
    }

    xpc_connection_t conn = Connection();
    if( !conn ) {
        errno = direct_err;
        return nullptr;
    }

    const int fd = OpenViaHelper(conn, _path, O_RDONLY | O_NONBLOCK | O_DIRECTORY | O_CLOEXEC, 0, direct_err);
    if( fd < 0 )
        return nullptr;

    DIR *const dir = fdopendir(fd);
    if( !dir ) {
        const int err = errno;
        ::close(fd);
        errno = err;
    }
    return dir;
}

int PosixIOInterfaceRouted::mkdir(const char *_path, mode_t _mode) noexcept
{
    if( super::mkdir(_path, _mode) == 0 )
        return 0;

    const int direct_err = errno;
    if( !ShouldEscalateToHelper(direct_err) ) {
        errno = direct_err;
        return -1;
    }

    xpc_connection_t conn = Connection();
    if( !conn ) {
        errno = direct_err;
        return -1;
    }

    xpc_object_t message = xpc_dictionary_create(nullptr, nullptr, 0);
    xpc_dictionary_set_string(message, "operation", "mkdir");
    xpc_dictionary_set_string(message, "path", _path);
    xpc_dictionary_set_int64(message, "mode", _mode);

    if( SendSimpleRequest(conn, message, direct_err) != 0 )
        return -1;

    // The directory was created by root; restore ownership to the current user.
    this->chown(_path, g_UID, -1);
    return 0;
}

int PosixIOInterfaceRouted::chown(const char *_path, uid_t _uid, gid_t _gid) noexcept
{
    if( super::chown(_path, _uid, _gid) == 0 )
        return 0;

    const int direct_err = errno;
    if( !ShouldEscalateToHelper(direct_err) ) {
        errno = direct_err;
        return -1;
    }

    xpc_connection_t conn = Connection();
    if( !conn ) {
        errno = direct_err;
        return -1;
    }

    xpc_object_t message = xpc_dictionary_create(nullptr, nullptr, 0);
    xpc_dictionary_set_string(message, "operation", "chown");
    xpc_dictionary_set_string(message, "path", _path);
    xpc_dictionary_set_int64(message, "uid", _uid);
    xpc_dictionary_set_int64(message, "gid", _gid);

    return SendSimpleRequest(conn, message, direct_err);
}

int PosixIOInterfaceRouted::chflags(const char *_path, u_int _flags) noexcept
{
    if( super::chflags(_path, _flags) == 0 )
        return 0;

    const int direct_err = errno;
    if( !ShouldEscalateToHelper(direct_err) ) {
        errno = direct_err;
        return -1;
    }

    xpc_connection_t conn = Connection();
    if( !conn ) {
        errno = direct_err;
        return -1;
    }

    xpc_object_t message = xpc_dictionary_create(nullptr, nullptr, 0);
    xpc_dictionary_set_string(message, "operation", "chflags");
    xpc_dictionary_set_string(message, "path", _path);
    xpc_dictionary_set_int64(message, "flags", _flags);

    return SendSimpleRequest(conn, message, direct_err);
}

int PosixIOInterfaceRouted::lchflags(const char *_path, u_int _flags) noexcept
{
    if( super::lchflags(_path, _flags) == 0 )
        return 0;

    const int direct_err = errno;
    if( !ShouldEscalateToHelper(direct_err) ) {
        errno = direct_err;
        return -1;
    }

    xpc_connection_t conn = Connection();
    if( !conn ) {
        errno = direct_err;
        return -1;
    }

    xpc_object_t message = xpc_dictionary_create(nullptr, nullptr, 0);
    xpc_dictionary_set_string(message, "operation", "lchflags");
    xpc_dictionary_set_string(message, "path", _path);
    xpc_dictionary_set_int64(message, "flags", _flags);

    return SendSimpleRequest(conn, message, direct_err);
}

int PosixIOInterfaceRouted::rmdir(const char *_path) noexcept
{
    if( super::rmdir(_path) == 0 )
        return 0;

    const int direct_err = errno;
    if( !ShouldEscalateToHelper(direct_err) ) {
        errno = direct_err;
        return -1;
    }

    xpc_connection_t conn = Connection();
    if( !conn ) {
        errno = direct_err;
        return -1;
    }

    xpc_object_t message = xpc_dictionary_create(nullptr, nullptr, 0);
    xpc_dictionary_set_string(message, "operation", "rmdir");
    xpc_dictionary_set_string(message, "path", _path);

    return SendSimpleRequest(conn, message, direct_err);
}

int PosixIOInterfaceRouted::unlink(const char *_path) noexcept
{
    if( super::unlink(_path) == 0 )
        return 0;

    const int direct_err = errno;
    if( !ShouldEscalateToHelper(direct_err) ) {
        errno = direct_err;
        return -1;
    }

    xpc_connection_t conn = Connection();
    if( !conn ) {
        errno = direct_err;
        return -1;
    }

    xpc_object_t message = xpc_dictionary_create(nullptr, nullptr, 0);
    xpc_dictionary_set_string(message, "operation", "unlink");
    xpc_dictionary_set_string(message, "path", _path);

    return SendSimpleRequest(conn, message, direct_err);
}

int PosixIOInterfaceRouted::rename(const char *_old, const char *_new) noexcept
{
    if( super::rename(_old, _new) == 0 )
        return 0;

    const int direct_err = errno;
    if( !ShouldEscalateToHelper(direct_err) ) {
        errno = direct_err;
        return -1;
    }

    xpc_connection_t conn = Connection();
    if( !conn ) {
        errno = direct_err;
        return -1;
    }

    xpc_object_t message = xpc_dictionary_create(nullptr, nullptr, 0);
    xpc_dictionary_set_string(message, "operation", "rename");
    xpc_dictionary_set_string(message, "oldpath", _old);
    xpc_dictionary_set_string(message, "newpath", _new);

    return SendSimpleRequest(conn, message, direct_err);
}

ssize_t PosixIOInterfaceRouted::readlink(const char *_path, char *_symlink, size_t _buf_sz) noexcept
{
    if( const ssize_t direct_sz = super::readlink(_path, _symlink, _buf_sz); direct_sz >= 0 )
        return direct_sz;

    const int direct_err = errno;
    if( !ShouldEscalateToHelper(direct_err) ) {
        errno = direct_err;
        return -1;
    }

    xpc_connection_t conn = Connection();
    if( !conn ) {
        errno = direct_err;
        return -1;
    }

    xpc_object_t message = xpc_dictionary_create(nullptr, nullptr, 0);
    xpc_dictionary_set_string(message, "operation", "readlink");
    xpc_dictionary_set_string(message, "path", _path);

    xpc_object_t reply = xpc_connection_send_message_with_reply_sync(conn, message);
    xpc_release(message);

    if( xpc_get_type(reply) == XPC_TYPE_ERROR ) {
        xpc_release(reply);
        errno = direct_err;
        return -1;
    }

    if( const auto err = xpc_dictionary_get_int64(reply, "error") ) {
        xpc_release(reply);
        errno = static_cast<int>(err);
        return -1;
    }

    const char *value = xpc_dictionary_get_string(reply, "link");
    if( !value ) {
        xpc_release(reply);
        errno = EIO;
        return -1;
    }

    const size_t sz = std::string_view{value}.length();
    if( sz + 1 >= _buf_sz ) {
        xpc_release(reply);
        errno = ERANGE;
        return -1;
    }
    memcpy(_symlink, value, sz + 1);

    xpc_release(reply);

    return static_cast<ssize_t>(sz);
}

int PosixIOInterfaceRouted::symlink(const char *_value, const char *_symlink_path) noexcept
{
    if( super::symlink(_value, _symlink_path) == 0 )
        return 0;

    const int direct_err = errno;
    if( !ShouldEscalateToHelper(direct_err) ) {
        errno = direct_err;
        return -1;
    }

    xpc_connection_t conn = Connection();
    if( !conn ) {
        errno = direct_err;
        return -1;
    }

    xpc_object_t message = xpc_dictionary_create(nullptr, nullptr, 0);
    xpc_dictionary_set_string(message, "operation", "symlink");
    xpc_dictionary_set_string(message, "path", _symlink_path);
    xpc_dictionary_set_string(message, "value", _value);

    return SendSimpleRequest(conn, message, direct_err);
}

int PosixIOInterfaceRouted::link(const char *_path_exist, const char *_path_newnode) noexcept
{
    if( super::link(_path_exist, _path_newnode) == 0 )
        return 0;

    const int direct_err = errno;
    if( !ShouldEscalateToHelper(direct_err) ) {
        errno = direct_err;
        return -1;
    }

    xpc_connection_t conn = Connection();
    if( !conn ) {
        errno = direct_err;
        return -1;
    }

    xpc_object_t message = xpc_dictionary_create(nullptr, nullptr, 0);
    xpc_dictionary_set_string(message, "operation", "link");
    xpc_dictionary_set_string(message, "exist", _path_exist);
    xpc_dictionary_set_string(message, "newnode", _path_newnode);

    return SendSimpleRequest(conn, message, direct_err);
}

int PosixIOInterfaceRouted::chmod(const char *_path, mode_t _mode) noexcept
{
    if( super::chmod(_path, _mode) == 0 )
        return 0;

    const int direct_err = errno;
    if( !ShouldEscalateToHelper(direct_err) ) {
        errno = direct_err;
        return -1;
    }

    xpc_connection_t conn = Connection();
    if( !conn ) {
        errno = direct_err;
        return -1;
    }

    xpc_object_t message = xpc_dictionary_create(nullptr, nullptr, 0);
    xpc_dictionary_set_string(message, "operation", "chmod");
    xpc_dictionary_set_string(message, "path", _path);
    xpc_dictionary_set_int64(message, "mode", _mode);

    return SendSimpleRequest(conn, message, direct_err);
}

int PosixIOInterfaceRouted::chmtime(const char *_path, time_t _time) noexcept
{
    if( super::chmtime(_path, _time) == 0 )
        return 0;

    const int direct_err = errno;
    if( !ShouldEscalateToHelper(direct_err) ) {
        errno = direct_err;
        return -1;
    }

    xpc_connection_t conn = Connection();
    if( !conn ) {
        errno = direct_err;
        return -1;
    }

    xpc_object_t message = xpc_dictionary_create(nullptr, nullptr, 0);
    xpc_dictionary_set_string(message, "operation", "chmtime");
    xpc_dictionary_set_string(message, "path", _path);
    xpc_dictionary_set_int64(message, "time", _time);

    return SendSimpleRequest(conn, message, direct_err);
}

int PosixIOInterfaceRouted::chatime(const char *_path, time_t _time) noexcept
{
    if( super::chatime(_path, _time) == 0 )
        return 0;

    const int direct_err = errno;
    if( !ShouldEscalateToHelper(direct_err) ) {
        errno = direct_err;
        return -1;
    }

    xpc_connection_t conn = Connection();
    if( !conn ) {
        errno = direct_err;
        return -1;
    }

    xpc_object_t message = xpc_dictionary_create(nullptr, nullptr, 0);
    xpc_dictionary_set_string(message, "operation", "chatime");
    xpc_dictionary_set_string(message, "path", _path);
    xpc_dictionary_set_int64(message, "time", _time);

    return SendSimpleRequest(conn, message, direct_err);
}

int PosixIOInterfaceRouted::chbtime(const char *_path, time_t _time) noexcept
{
    if( super::chbtime(_path, _time) == 0 )
        return 0;

    const int direct_err = errno;
    if( !ShouldEscalateToHelper(direct_err) ) {
        errno = direct_err;
        return -1;
    }

    xpc_connection_t conn = Connection();
    if( !conn ) {
        errno = direct_err;
        return -1;
    }

    xpc_object_t message = xpc_dictionary_create(nullptr, nullptr, 0);
    xpc_dictionary_set_string(message, "operation", "chbtime");
    xpc_dictionary_set_string(message, "path", _path);
    xpc_dictionary_set_int64(message, "time", _time);

    return SendSimpleRequest(conn, message, direct_err);
}

int PosixIOInterfaceRouted::chctime(const char *_path, time_t _time) noexcept
{
    if( super::chctime(_path, _time) == 0 )
        return 0;

    const int direct_err = errno;
    if( !ShouldEscalateToHelper(direct_err) ) {
        errno = direct_err;
        return -1;
    }

    xpc_connection_t conn = Connection();
    if( !conn ) {
        errno = direct_err;
        return -1;
    }

    xpc_object_t message = xpc_dictionary_create(nullptr, nullptr, 0);
    xpc_dictionary_set_string(message, "operation", "chctime");
    xpc_dictionary_set_string(message, "path", _path);
    xpc_dictionary_set_int64(message, "time", _time);

    return SendSimpleRequest(conn, message, direct_err);
}

int PosixIOInterfaceRouted::killpg(int _pid, int _signal) noexcept
{
    if( super::killpg(_pid, _signal) == 0 )
        return 0;

    const int direct_err = errno;
    if( !ShouldEscalateToHelper(direct_err) ) {
        errno = direct_err;
        return -1;
    }

    xpc_connection_t conn = Connection();
    if( !conn ) {
        errno = direct_err;
        return -1;
    }

    xpc_object_t message = xpc_dictionary_create(nullptr, nullptr, 0);
    xpc_dictionary_set_string(message, "operation", "killpg");
    xpc_dictionary_set_int64(message, "pid", _pid);
    xpc_dictionary_set_int64(message, "signal", _signal);

    return SendSimpleRequest(conn, message, direct_err);
}

int PosixIOInterfaceRouted::trash(const char *_path) noexcept
{
    // Trashing is deliberately never sent to the privileged helper: the helper runs as root, so the
    // item would land in root's own trash, where this process can neither see nor restore it - the
    // user would be told that the item was moved to the trash while it effectively disappeared.
    // Files that only the helper can touch are still deletable through Delete Permanently.
    return super::trash(_path);
}

} // namespace nc::routedio
