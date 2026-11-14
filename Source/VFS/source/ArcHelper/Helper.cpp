// Copyright (C) 2026 Michael Kazakov. Subject to GNU General Public License version 3.
#include "Helper.h"
#include <Base/CommonPaths.h>
#include <Base/algo.h>
#include <VFS/Host.h>
#include <VFS/VFSFile.h>
#include <cerrno>
#include <csignal>
#include <cstring>
#include <tuple>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

namespace nc::vfs::rar {

namespace {

bool IsExecutable(const std::string &_path) noexcept
{
    return !_path.empty() && ::access(_path.c_str(), X_OK) == 0;
}

} // namespace

std::optional<std::string> FindHelper()
{
    if( const char *env = ::getenv("NCRAR_HELPER"); env != nullptr && env[0] != 0 ) {
        if( std::string path{env}; IsExecutable(path) )
            return path;
    }

    if( std::string path =
            nc::base::CommonPaths::Home() + "Library/Application Support/Nimble Commander-Fork/ncrar-helper";
        IsExecutable(path) )
        return path;

    for( const char *candidate : {"/usr/local/bin/ncrar-helper", "/opt/homebrew/bin/ncrar-helper"} )
        if( IsExecutable(candidate) )
            return std::string{candidate};

    return std::nullopt;
}

bool LooksLikeRarArchive(Host &_parent, const std::string_view _path, const VFSCancelChecker &_cancel_checker)
{
    const std::expected<std::shared_ptr<VFSFile>, Error> file = _parent.CreateFile(_path, _cancel_checker);
    if( !file )
        return false;
    if( const std::expected<void, Error> rc = (*file)->Open(VFSFlags::OF_Read, _cancel_checker); !rc )
        return false;
    const auto close = at_scope_end([&] { std::ignore = (*file)->Close(); });

    unsigned char magic[8] = {};
    const std::expected<size_t, Error> read = (*file)->Read(magic, sizeof(magic));
    if( !read || *read < 7 )
        return false;

    // Both RAR4 ("Rar!\x1a\x07\x00") and RAR5 ("Rar!\x1a\x07\x01\x00") carry this prefix.
    static constexpr unsigned char signature[] = {'R', 'a', 'r', '!', 0x1A, 0x07};
    return std::memcmp(magic, signature, sizeof(signature)) == 0;
}

Error ErrorForHelperExitCode(const int _exit_code)
{
    switch( _exit_code ) {
        case 2: // usage error
            return Error{Error::POSIX, EINVAL};
        case 3: // the archive cannot be opened
            return Error{Error::POSIX, EFTYPE};
        case 4: // the archive/entry cannot be read
            return Error{Error::POSIX, EIO};
        case 5: // a password is required or wrong
            return Error{Error::POSIX, ENEEDAUTH};
        default:
            return Error{Error::POSIX, EIO};
    }
}

ChildProcess::ChildProcess(ChildProcess &&_rhs) noexcept : m_Pid(_rhs.m_Pid), m_Fd(_rhs.m_Fd)
{
    _rhs.m_Pid = -1;
    _rhs.m_Fd = -1;
}

ChildProcess &ChildProcess::operator=(ChildProcess &&_rhs) noexcept
{
    if( this != &_rhs ) {
        Reset();
        m_Pid = _rhs.m_Pid;
        m_Fd = _rhs.m_Fd;
        _rhs.m_Pid = -1;
        _rhs.m_Fd = -1;
    }
    return *this;
}

ChildProcess::~ChildProcess()
{
    Terminate();
}

std::expected<ChildProcess, Error> ChildProcess::Spawn(const std::string &_helper_path,
                                                       const std::vector<std::string> &_args,
                                                       const std::optional<std::string> &_password)
{
    if( _helper_path.empty() )
        return std::unexpected(Error{Error::POSIX, ENOENT});

    // Everything the child needs is prepared before the fork - only async-signal-safe calls are
    // allowed between fork() and execve().
    std::vector<char *> argv;
    argv.reserve(_args.size() + 2);
    argv.push_back(const_cast<char *>(_helper_path.c_str()));
    for( const std::string &arg : _args )
        argv.push_back(const_cast<char *>(arg.c_str()));
    argv.push_back(nullptr);

    std::vector<std::string> env_storage;
    std::vector<char *> envp;
    if( _password ) {
        for( char **entry = ::environ; *entry != nullptr; ++entry )
            if( std::strncmp(*entry, "NCRAR_PASSWORD=", 15) != 0 )
                env_storage.emplace_back(*entry);
        env_storage.emplace_back("NCRAR_PASSWORD=" + *_password);
        envp.reserve(env_storage.size() + 1);
        for( std::string &entry : env_storage )
            envp.push_back(entry.data());
        envp.push_back(nullptr);
    }

    int fds[2] = {-1, -1};
    if( ::pipe(fds) != 0 )
        return std::unexpected(Error{Error::POSIX, errno});

    const pid_t pid = ::fork();
    if( pid < 0 ) {
        const int error = errno;
        ::close(fds[0]);
        ::close(fds[1]);
        return std::unexpected(Error{Error::POSIX, error});
    }

    if( pid == 0 ) {
        // Child.
        ::close(fds[0]);
        if( ::dup2(fds[1], STDOUT_FILENO) < 0 )
            ::_exit(126);
        if( fds[1] != STDOUT_FILENO )
            ::close(fds[1]);
        ::execve(_helper_path.c_str(), argv.data(), envp.empty() ? ::environ : envp.data());
        ::_exit(127);
    }

    ::close(fds[1]);

    ChildProcess process;
    process.m_Pid = pid;
    process.m_Fd = fds[0];
    return process;
}

bool ChildProcess::IsValid() const noexcept
{
    return m_Pid > 0 || m_Fd >= 0;
}

int ChildProcess::StdoutFD() const noexcept
{
    return m_Fd;
}

std::expected<size_t, Error> ChildProcess::Read(void *_buf, const size_t _size)
{
    if( m_Fd < 0 )
        return std::unexpected(Error{Error::POSIX, EBADF});

    while( true ) {
        const ssize_t read = ::read(m_Fd, _buf, _size);
        if( read < 0 ) {
            if( errno == EINTR )
                continue;
            return std::unexpected(Error{Error::POSIX, errno});
        }
        return static_cast<size_t>(read);
    }
}

std::expected<int, Error> ChildProcess::Wait()
{
    if( m_Pid <= 0 )
        return std::unexpected(Error{Error::POSIX, ECHILD});

    int status = 0;
    while( ::waitpid(m_Pid, &status, 0) < 0 )
        if( errno != EINTR )
            return std::unexpected(Error{Error::POSIX, errno});

    m_Pid = -1;
    if( WIFEXITED(status) )
        return WEXITSTATUS(status);
    return std::unexpected(Error{Error::POSIX, ECHILD}); // terminated by a signal
}

void ChildProcess::Terminate() noexcept
{
    Reset();
}

void ChildProcess::Reset() noexcept
{
    if( m_Fd >= 0 ) {
        ::close(m_Fd);
        m_Fd = -1;
    }

    if( m_Pid > 0 ) {
        ::kill(m_Pid, SIGTERM);
        // Give the helper a chance to shut down gracefully, then insist.
        int status = 0;
        bool reaped = false;
        for( int attempt = 0; attempt != 100; ++attempt ) {
            const pid_t result = ::waitpid(m_Pid, &status, WNOHANG);
            if( result == m_Pid ) {
                reaped = true;
                break;
            }
            if( result < 0 && errno != EINTR )
                break;
            ::usleep(10000);
        }
        if( !reaped ) {
            ::kill(m_Pid, SIGKILL);
            while( ::waitpid(m_Pid, &status, 0) < 0 && errno == EINTR ) {
            }
        }
        m_Pid = -1;
    }
}

} // namespace nc::vfs::rar
