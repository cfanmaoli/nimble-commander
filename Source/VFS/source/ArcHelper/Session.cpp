// Copyright (C) 2026 Michael Kazakov. Subject to GNU General Public License version 3.
#include "Session.h"
#include <rapidjson/document.h>
#include <rapidjson/stringbuffer.h>
#include <rapidjson/writer.h>
#include <algorithm>
#include <cerrno>
#include <cstring>
#include <limits>
#include <poll.h>
#include <tuple>
#include <unistd.h>

namespace nc::vfs::rar {

namespace {

// How long to wait for the helper's stdout before considering it wedged. A solid archive can take
// a while to decompress before it announces the payload size, so the budget is deliberately large.
constexpr int kPollSliceMs = 100;
constexpr int64_t kResponseTimeoutMs = 10 * 60 * 1000;
constexpr size_t kMaxLineSize = 4 * 1024 * 1024;

template <typename F>
std::string ComposeCommand(const char *_command, F &&_add)
{
    rapidjson::StringBuffer buffer;
    rapidjson::Writer<rapidjson::StringBuffer> writer(buffer);
    writer.StartObject();
    writer.Key("cmd");
    writer.String(_command);
    _add(writer);
    writer.EndObject();
    return std::string{buffer.GetString(), buffer.GetSize()};
}

std::optional<uint64_t> ReadResponseUint(const rapidjson::Value &_obj, const char *_name)
{
    const auto member = _obj.FindMember(_name);
    if( member == _obj.MemberEnd() )
        return std::nullopt;
    if( member->value.IsUint64() )
        return member->value.GetUint64();
    if( member->value.IsInt64() && member->value.GetInt64() >= 0 )
        return static_cast<uint64_t>(member->value.GetInt64());
    return std::nullopt;
}

// Returns the error carried by an {"ok":false,...} object, nullopt otherwise.
std::optional<Error> FailureError(const rapidjson::Document &_document)
{
    if( !_document.IsObject() )
        return std::nullopt;

    const auto ok = _document.FindMember("ok");
    if( ok == _document.MemberEnd() || !ok->value.IsBool() || ok->value.GetBool() )
        return std::nullopt;

    int code = 4;
    if( const auto code_member = _document.FindMember("code");
        code_member != _document.MemberEnd() && code_member->value.IsInt() )
        code = code_member->value.GetInt();
    return ErrorForHelperExitCode(code);
}

bool IsOkResponse(const rapidjson::Document &_document)
{
    const auto ok = _document.FindMember("ok");
    return ok != _document.MemberEnd() && ok->value.IsBool() && ok->value.GetBool();
}

// The first response of a fresh session is the only reliable way to tell an older helper that
// doesn't know "serve" apart from a helper that failed: the former exits without writing a line.
Error ErrorForMissingFirstResponse(const Error &_error)
{
    if( _error == Error{Error::POSIX, ECANCELED} || _error == Error{Error::POSIX, ETIMEDOUT} )
        return _error;
    return Error{Error::POSIX, ENOTSUP};
}

} // namespace

Session::~Session()
{
    if( m_Process ) {
        if( m_Healthy && m_PayloadRemaining == 0 && m_Buffer.empty() ) {
            // Be polite and let the helper exit on its own; Terminate() reaps it either way.
            static constexpr char close_command[] = "{\"cmd\":\"close\"}\n";
            static constexpr char quit_command[] = "{\"cmd\":\"quit\"}\n";
            std::ignore = m_Process->WriteAll(close_command, sizeof(close_command) - 1);
            std::ignore = m_Process->WriteAll(quit_command, sizeof(quit_command) - 1);
        }
        m_Process->Terminate();
    }
}

std::expected<Session, Error> Session::Open(const std::string &_helper_path,
                                            const std::string &_archive_path,
                                            const std::optional<std::string> &_password,
                                            const VFSCancelChecker &_cancel_checker)
{
    std::expected<ChildProcess, Error> process =
        ChildProcess::SpawnWithStdin(_helper_path, std::vector<std::string>{"serve"}, std::nullopt);
    if( !process )
        return std::unexpected(process.error());

    Session session;
    session.m_Process = std::move(*process);
    session.m_Healthy = true;

    const std::string command = ComposeCommand("open", [&](auto &_writer) {
        _writer.Key("archive");
        _writer.String(_archive_path.c_str(), rapidjson::SizeType(_archive_path.size()));
        if( _password && !_password->empty() ) {
            _writer.Key("password");
            _writer.String(_password->c_str(), rapidjson::SizeType(_password->size()));
        }
    });

    if( const std::expected<void, Error> sent = session.SendCommand(command, _cancel_checker); !sent ) {
        const Error error = sent.error();
        session.Break();
        return std::unexpected(ErrorForMissingFirstResponse(error));
    }

    std::expected<std::string, Error> line = session.ReadLine(_cancel_checker);
    if( !line ) {
        const Error error = line.error();
        session.Break();
        return std::unexpected(ErrorForMissingFirstResponse(error));
    }

    rapidjson::Document document;
    document.Parse(line->data(), line->size());
    if( document.HasParseError() || !document.IsObject() ) {
        session.Break();
        return std::unexpected(Error{Error::POSIX, EFTYPE});
    }
    if( const std::optional<Error> error = FailureError(document) ) {
        session.Break();
        return std::unexpected(*error);
    }
    if( !IsOkResponse(document) ) {
        session.Break();
        return std::unexpected(Error{Error::POSIX, EFTYPE});
    }

    return std::move(session);
}

bool Session::IsValid() const noexcept
{
    return m_Healthy && m_Process.has_value();
}

bool Session::IsHealthy() const noexcept
{
    return IsValid();
}

std::expected<Listing, Error> Session::List(const VFSCancelChecker &_cancel_checker)
{
    if( !IsValid() )
        return std::unexpected(Error{Error::POSIX, EBADF});
    if( m_PayloadRemaining != 0 || !m_Buffer.empty() )
        return std::unexpected(Error{Error::POSIX, EBUSY});

    if( const std::expected<void, Error> sent = SendCommand(ComposeCommand("list", [](auto &) {}), _cancel_checker);
        !sent )
        return std::unexpected(sent.error());

    std::string collected;
    while( true ) {
        std::expected<std::string, Error> line = ReadLine(_cancel_checker);
        if( !line )
            return std::unexpected(line.error());

        rapidjson::Document document;
        document.Parse(line->data(), line->size());
        if( document.HasParseError() || !document.IsObject() ) {
            Break();
            return std::unexpected(Error{Error::POSIX, EFTYPE});
        }
        if( const std::optional<Error> error = FailureError(document) )
            return std::unexpected(*error);

        collected += *line;
        collected += '\n';

        if( const auto done = document.FindMember("done");
            done != document.MemberEnd() && done->value.IsBool() && done->value.GetBool() )
            break;
    }

    std::optional<Listing> listing = ParseListing(collected);
    if( !listing ) {
        Break(); // a listing that doesn't parse means the stream can't be trusted anymore
        return std::unexpected(Error{Error::POSIX, EFTYPE});
    }
    return std::move(*listing);
}

std::expected<void, Error> Session::Close(const VFSCancelChecker &_cancel_checker)
{
    if( !IsValid() )
        return std::unexpected(Error{Error::POSIX, EBADF});
    if( m_PayloadRemaining != 0 || !m_Buffer.empty() )
        return std::unexpected(Error{Error::POSIX, EBUSY});

    if( const std::expected<void, Error> sent = SendCommand(ComposeCommand("close", [](auto &) {}), _cancel_checker);
        !sent )
        return std::unexpected(sent.error());

    std::expected<std::string, Error> line = ReadLine(_cancel_checker);
    if( !line )
        return std::unexpected(line.error());

    rapidjson::Document document;
    document.Parse(line->data(), line->size());
    if( document.HasParseError() || !document.IsObject() ) {
        Break();
        return std::unexpected(Error{Error::POSIX, EFTYPE});
    }
    if( const std::optional<Error> error = FailureError(document) )
        return std::unexpected(*error);
    if( !IsOkResponse(document) )
        return std::unexpected(Error{Error::POSIX, EFTYPE});
    return {};
}

std::expected<std::string, Error> Session::Link(const uint32_t _index, const VFSCancelChecker &_cancel_checker)
{
    if( !IsValid() )
        return std::unexpected(Error{Error::POSIX, EBADF});
    if( m_PayloadRemaining != 0 || !m_Buffer.empty() )
        return std::unexpected(Error{Error::POSIX, EBUSY});

    const std::string command = ComposeCommand("link", [&](auto &_writer) {
        _writer.Key("index");
        _writer.Uint(_index);
    });
    if( const std::expected<void, Error> sent = SendCommand(command, _cancel_checker); !sent )
        return std::unexpected(sent.error());

    std::expected<std::string, Error> line = ReadLine(_cancel_checker);
    if( !line )
        return std::unexpected(line.error());

    rapidjson::Document document;
    document.Parse(line->data(), line->size());
    if( document.HasParseError() || !document.IsObject() ) {
        Break();
        return std::unexpected(Error{Error::POSIX, EFTYPE});
    }
    if( const std::optional<Error> error = FailureError(document) )
        return std::unexpected(*error);

    const auto target = document.FindMember("target");
    if( target == document.MemberEnd() || !target->value.IsString() || target->value.GetStringLength() == 0 )
        return std::unexpected(Error{Error::POSIX, EFTYPE});
    return std::string{target->value.GetString(), target->value.GetStringLength()};
}

std::expected<uint64_t, Error> Session::BeginRead(const uint32_t _index, const VFSCancelChecker &_cancel_checker)
{
    if( !IsValid() )
        return std::unexpected(Error{Error::POSIX, EBADF});
    if( m_PayloadRemaining != 0 || !m_Buffer.empty() )
        return std::unexpected(Error{Error::POSIX, EBUSY}); // the previous payload wasn't drained

    const std::string command = ComposeCommand("read", [&](auto &_writer) {
        _writer.Key("index");
        _writer.Uint(_index);
    });
    if( const std::expected<void, Error> sent = SendCommand(command, _cancel_checker); !sent )
        return std::unexpected(sent.error());

    std::expected<std::string, Error> line = ReadLine(_cancel_checker);
    if( !line )
        return std::unexpected(line.error());

    rapidjson::Document document;
    document.Parse(line->data(), line->size());
    if( document.HasParseError() || !document.IsObject() ) {
        Break();
        return std::unexpected(Error{Error::POSIX, EFTYPE});
    }
    if( const std::optional<Error> error = FailureError(document) )
        return std::unexpected(*error);

    const auto event = document.FindMember("event");
    const std::optional<uint64_t> size = ReadResponseUint(document, "size");
    if( event == document.MemberEnd() || !event->value.IsString() || !size ||
        std::string_view{event->value.GetString(), event->value.GetStringLength()} != "data" ) {
        Break();
        return std::unexpected(Error{Error::POSIX, EFTYPE});
    }

    m_PayloadRemaining = *size;
    return m_PayloadRemaining;
}

std::expected<size_t, Error>
Session::ReadPayload(void *_buf, const size_t _size, const VFSCancelChecker &_cancel_checker)
{
    if( !IsValid() )
        return std::unexpected(Error{Error::POSIX, EBADF});
    if( _buf == nullptr && _size != 0 )
        return std::unexpected(Error{Error::POSIX, EINVAL});
    if( _size == 0 || m_PayloadRemaining == 0 )
        return 0;

    const size_t wanted = static_cast<size_t>(std::min<uint64_t>(_size, m_PayloadRemaining));
    size_t produced = 0;

    if( !m_Buffer.empty() ) {
        const size_t from_buffer = std::min(wanted, m_Buffer.size());
        std::memcpy(_buf, m_Buffer.data(), from_buffer);
        m_Buffer.erase(0, from_buffer);
        produced = from_buffer;
    }

    char *const destination = static_cast<char *>(_buf);
    while( produced < wanted ) {
        if( const std::expected<void, Error> ready = WaitReadable(_cancel_checker); !ready )
            return std::unexpected(ready.error());

        const std::expected<size_t, Error> read = m_Process->Read(destination + produced, wanted - produced);
        if( !read ) {
            Break();
            return std::unexpected(read.error());
        }
        if( *read == 0 ) {
            Break(); // the helper stopped before producing the whole payload
            return std::unexpected(Error{Error::POSIX, EIO});
        }
        produced += *read;
    }

    m_PayloadRemaining -= produced;
    return produced;
}

bool Session::HasPendingPayload() const noexcept
{
    return m_PayloadRemaining != 0;
}

void Session::Discard() noexcept
{
    Break();
}

void Session::Break() noexcept
{
    if( m_Process ) {
        m_Process->Terminate();
        m_Process.reset();
    }
    m_Buffer.clear();
    m_PayloadRemaining = 0;
    m_Healthy = false;
}

std::expected<void, Error> Session::SendCommand(const std::string_view _command,
                                                const VFSCancelChecker &_cancel_checker)
{
    if( !IsValid() || !m_Process )
        return std::unexpected(Error{Error::POSIX, EBADF});
    if( _cancel_checker && _cancel_checker() ) {
        Break();
        return std::unexpected(Error{Error::POSIX, ECANCELED});
    }

    std::string payload{_command};
    payload += '\n';
    const std::expected<void, Error> written = m_Process->WriteAll(payload.data(), payload.size());
    if( !written ) {
        Break();
        return std::unexpected(written.error());
    }
    return {};
}

std::expected<std::string, Error> Session::ReadLine(const VFSCancelChecker &_cancel_checker)
{
    if( !IsValid() || !m_Process )
        return std::unexpected(Error{Error::POSIX, EBADF});

    while( true ) {
        const size_t eol = m_Buffer.find('\n');
        if( eol != std::string::npos ) {
            std::string line = m_Buffer.substr(0, eol);
            m_Buffer.erase(0, eol + 1);
            if( !line.empty() && line.back() == '\r' )
                line.pop_back();
            return line;
        }

        if( m_Buffer.size() > kMaxLineSize ) {
            Break();
            return std::unexpected(Error{Error::POSIX, EFTYPE});
        }

        if( const std::expected<void, Error> ready = WaitReadable(_cancel_checker); !ready )
            return std::unexpected(ready.error());

        char chunk[16 * 1024];
        const std::expected<size_t, Error> read = m_Process->Read(chunk, sizeof(chunk));
        if( !read ) {
            Break();
            return std::unexpected(read.error());
        }
        if( *read == 0 ) {
            Break(); // the child has gone away
            return std::unexpected(Error{Error::POSIX, EIO});
        }
        m_Buffer.append(chunk, *read);
    }
}

std::expected<void, Error> Session::WaitReadable(const VFSCancelChecker &_cancel_checker)
{
    if( !m_Process )
        return std::unexpected(Error{Error::POSIX, EBADF});

    int64_t waited = 0;
    while( true ) {
        pollfd descriptor{};
        descriptor.fd = m_Process->StdoutFD();
        descriptor.events = POLLIN;
        const int result = ::poll(&descriptor, 1, kPollSliceMs);
        if( result < 0 ) {
            if( errno == EINTR )
                continue;
            Break();
            return std::unexpected(Error{Error::POSIX, errno});
        }
        if( result > 0 )
            return {};

        waited += kPollSliceMs;
        if( _cancel_checker && _cancel_checker() ) {
            Break();
            return std::unexpected(Error{Error::POSIX, ECANCELED});
        }
        if( waited >= kResponseTimeoutMs ) {
            Break();
            return std::unexpected(Error{Error::POSIX, ETIMEDOUT});
        }
    }
}

SessionLease::SessionLease(std::unique_ptr<Session> _session, Release _release)
    : m_Session(std::move(_session)), m_Release(std::move(_release))
{
}

SessionLease::~SessionLease()
{
    if( m_Session && m_Release )
        m_Release(std::move(m_Session), m_Healthy);
}

Session *SessionLease::operator->() const noexcept
{
    return m_Session.get();
}

Session &SessionLease::Get() const noexcept
{
    return *m_Session;
}

bool SessionLease::IsValid() const noexcept
{
    return m_Session && m_Session->IsValid();
}

void SessionLease::MarkBroken() noexcept
{
    m_Healthy = false;
}

} // namespace nc::vfs::rar
