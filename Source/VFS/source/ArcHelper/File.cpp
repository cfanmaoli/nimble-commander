// Copyright (C) 2026 Michael Kazakov. Subject to GNU General Public License version 3.
#include "File.h"
#include <algorithm>
#include <cassert>
#include <cstdint>
#include <tuple>

namespace nc::vfs::rar {

namespace {

std::optional<std::string> PasswordForHost(const RarHelperHost &_host)
{
    const std::string_view password = _host.Password();
    if( password.empty() )
        return std::nullopt;
    return std::string{password};
}

} // namespace

File::File(std::string_view _relative_path, const std::shared_ptr<RarHelperHost> &_host)
    : VFSFile(_relative_path, _host)
{
}

File::~File()
{
    std::ignore = Close();
}

std::expected<void, Error> File::Open(const unsigned long _open_flags, const VFSCancelChecker &_cancel_checker)
{
    if( std::string_view{Path()}.length() < 2 || Path()[0] != '/' )
        return std::unexpected(Error{Error::POSIX, ENOENT});

    if( _open_flags & VFSFlags::OF_Write )
        return std::unexpected(Error{Error::POSIX, ENOTSUP}); // archive files are read-only

    if( IsOpened() ) {
        if( const std::expected<void, Error> rc = Close(); !rc )
            return std::unexpected(rc.error());
    }

    const std::shared_ptr<RarHelperHost> host = std::dynamic_pointer_cast<RarHelperHost>(Host());
    if( !host )
        return std::unexpected(Error{Error::POSIX, EINVAL});

    std::string path = Path();
    if( host->NeedsPathResolving() ) {
        std::expected<std::string, Error> resolved = host->ResolvePath(path, true, _cancel_checker);
        if( !resolved )
            return std::unexpected(resolved.error());
        path = std::move(*resolved);
    }

    if( host->IsDirectory(path, _open_flags, _cancel_checker) && !(_open_flags & VFSFlags::OF_Directory) )
        return std::unexpected(Error{Error::POSIX, EISDIR});

    const std::optional<uint32_t> index = host->IndexForPath(path);
    if( !index )
        return std::unexpected(Error{Error::POSIX, ENOENT});

    const std::expected<VFSStat, Error> st = host->Stat(path, VFSFlags::F_NoFollow, _cancel_checker);
    if( !st )
        return std::unexpected(st.error());

    m_Position = 0;
    m_Size = st->size;
    m_Opened = true;

    // Empty entries don't need any decompression - and spawning the helper for them would walk the
    // whole archive for nothing.
    if( m_Size == 0 )
        return {};

    if( _cancel_checker && _cancel_checker() )
        return std::unexpected(Error{Error::POSIX, ECANCELED});

    // A persistent session is preferred: it keeps the archive open and reuses the cached listing,
    // so a solid archive isn't re-scanned for every entry.
    if( host->SupportsSessions() ) {
        m_Session = host->AcquireSession();
        if( !m_Session ) {
            std::expected<Session, Error> spawned = Session::Open(
                host->HelperPath(), std::string{host->JunctionPath()}, PasswordForHost(*host), _cancel_checker);
            if( spawned ) {
                m_Session = std::make_unique<SessionLease>(std::make_unique<Session>(std::move(*spawned)),
                                                           SessionLease::Release{});
            }
            else if( spawned.error() == Error{Error::POSIX, ENOTSUP} ) {
                host->DisableSessions(); // an older helper, use the one-shot commands below
            }
            else {
                m_Opened = false;
                return std::unexpected(spawned.error());
            }
        }

        if( m_Session ) {
            std::expected<uint64_t, Error> payload = m_Session->Get().BeginRead(*index, _cancel_checker);
            if( !payload ) {
                m_Session->MarkBroken();
                m_Session.reset();
                m_Opened = false;
                return std::unexpected(payload.error());
            }
            m_Size = *payload; // the helper's actual payload is authoritative
            if( m_Size == 0 )
                ReleaseSession(true);
            return {};
        }
    }

    const std::vector<std::string> args{"read", std::string{host->JunctionPath()}, std::to_string(*index)};
    std::expected<ChildProcess, Error> process = ChildProcess::Spawn(host->HelperPath(), args, PasswordForHost(*host));
    if( !process ) {
        m_Opened = false;
        return std::unexpected(process.error());
    }
    m_Process = std::move(*process);
    return {};
}

bool File::IsOpened() const
{
    return m_Opened;
}

std::expected<void, Error> File::Close()
{
    if( m_Session ) {
        // A session with a partially consumed payload can't be reused - it is out of sync.
        ReleaseSession(!m_Session->Get().HasPendingPayload());
    }
    TerminateStream();
    m_Opened = false;
    m_Position = 0;
    m_Size = 0;
    return {};
}

void File::TerminateStream() noexcept
{
    if( m_Process ) {
        m_Process->Terminate();
        m_Process.reset();
    }
}

void File::ReleaseSession(const bool _healthy) noexcept
{
    if( m_Session ) {
        if( !_healthy )
            m_Session->MarkBroken();
        m_Session.reset(); // the lease hands the session back to its pool, or shuts it down
    }
}

VFSFile::ReadParadigm File::GetReadParadigm() const
{
    return VFSFile::ReadParadigm::Sequential;
}

std::expected<uint64_t, Error> File::Pos() const
{
    if( !IsOpened() )
        return std::unexpected(Error{Error::POSIX, EINVAL});
    return m_Position;
}

std::expected<uint64_t, Error> File::Size() const
{
    if( !IsOpened() )
        return std::unexpected(Error{Error::POSIX, EINVAL});
    return m_Size;
}

bool File::Eof() const
{
    if( !IsOpened() )
        return true;
    return m_Position >= m_Size;
}

std::expected<size_t, Error> File::Read(void *_buf, const size_t _size)
{
    if( !IsOpened() )
        return std::unexpected(Error{Error::POSIX, EINVAL});
    if( Eof() || _size == 0 )
        return 0;

    assert(_buf != nullptr);

    const size_t to_read = static_cast<size_t>(std::min<uint64_t>(_size, m_Size - m_Position));

    if( m_Session ) {
        const std::expected<size_t, Error> read = m_Session->Get().ReadPayload(_buf, to_read, {});
        if( !read ) {
            m_Session->MarkBroken();
            m_Session.reset();
            return std::unexpected(read.error());
        }
        if( *read == 0 ) {
            // The helper has stopped before producing the whole payload - the archive is broken.
            m_Session->MarkBroken();
            m_Session.reset();
            return std::unexpected(Error{Error::POSIX, EIO});
        }

        m_Position += *read;
        if( m_Position >= m_Size )
            ReleaseSession(!m_Session->Get().HasPendingPayload());
        return *read;
    }

    if( !m_Process )
        return std::unexpected(Error{Error::POSIX, EIO});

    const std::expected<size_t, Error> read = m_Process->Read(_buf, to_read);
    if( !read )
        return std::unexpected(read.error());

    if( *read == 0 ) {
        // The helper has stopped before producing the whole payload - the archive is broken.
        const std::expected<int, Error> exit_code = m_Process->Wait();
        TerminateStream();
        if( !exit_code )
            return std::unexpected(Error{Error::POSIX, EIO});
        if( *exit_code != 0 )
            return std::unexpected(ErrorForHelperExitCode(*exit_code));
        return std::unexpected(Error{Error::POSIX, EIO});
    }

    m_Position += *read;
    if( m_Position >= m_Size )
        TerminateStream(); // the payload is fully read - don't keep the child around

    return *read;
}

std::expected<void, Error> File::Skip(size_t _size)
{
    if( !IsOpened() )
        return std::unexpected(Error{Error::POSIX, EINVAL});

    // Keep the trash buffer off the stack - the VFS code has a tight stack frame budget.
    const std::unique_ptr<char[]> trash = std::make_unique<char[]>(32 * 1024);
    while( _size > 0 ) {
        const size_t chunk = std::min<size_t>(_size, 32 * 1024);
        const std::expected<size_t, Error> read = Read(trash.get(), chunk);
        if( !read )
            return std::unexpected(read.error());
        if( *read == 0 )
            return std::unexpected(Error{Error::POSIX, EIO});
        _size -= *read;
    }
    return {};
}

std::expected<uint64_t, Error> File::Seek(const off_t _off, const int _basis)
{
    if( !IsOpened() )
        return std::unexpected(Error{Error::POSIX, EINVAL});

    int64_t target = 0;
    switch( _basis ) {
        case Seek_Set:
            target = _off;
            break;
        case Seek_Cur:
            target = static_cast<int64_t>(m_Position) + _off;
            break;
        case Seek_End:
            target = static_cast<int64_t>(m_Size) + _off;
            break;
        default:
            return std::unexpected(Error{Error::POSIX, EINVAL});
    }

    if( target < 0 || target > static_cast<int64_t>(m_Size) )
        return std::unexpected(Error{Error::POSIX, EINVAL});

    if( target == static_cast<int64_t>(m_Position) )
        return m_Position;

    // The payload comes out of a pipe, so only forward movements are possible.
    if( target < static_cast<int64_t>(m_Position) )
        return std::unexpected(Error{Error::POSIX, ENOTSUP});

    if( const std::expected<void, Error> rc = Skip(static_cast<size_t>(target - static_cast<int64_t>(m_Position)));
        !rc )
        return std::unexpected(rc.error());

    return m_Position;
}

} // namespace nc::vfs::rar
