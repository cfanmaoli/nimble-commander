// Copyright (C) 2026 Michael Kazakov. Subject to GNU General Public License version 3.
#pragma once

#include "Helper.h"
#include "Protocol.h"
#include <Base/Error.h>
#include <VFS/VFSDeclarations.h>
#include <cstdint>
#include <expected>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <string_view>

namespace nc::vfs::rar {

// A persistent ncrar-helper process started with "serve". Commands are JSON objects, one per line
// on the child's stdin; responses are JSON lines on its stdout, and the "read" command streams a
// binary payload after a {"event":"data","size":N} header.
//
// A session serves one command sequence at a time - it is not thread-safe and must not be shared.
// RarHelperHost hands out SessionLease objects for that reason.
class Session
{
public:
    Session() = default;
    Session(const Session &) = delete;
    Session &operator=(const Session &) = delete;
    Session(Session &&_rhs) noexcept = default;
    Session &operator=(Session &&_rhs) noexcept = default;
    ~Session();

    // Starts the helper in serve mode and sends the "open" command. Returns ENOTSUP when the
    // helper doesn't understand "serve" - an older binary the caller should use the one-shot
    // commands with instead.
    [[nodiscard]] static std::expected<Session, Error> Open(const std::string &_helper_path,
                                                            const std::string &_archive_path,
                                                            const std::optional<std::string> &_password,
                                                            const VFSCancelChecker &_cancel_checker = {});

    [[nodiscard]] bool IsValid() const noexcept;
    [[nodiscard]] bool IsHealthy() const noexcept;

    // Replays the entry listing cached by the helper's "open".
    [[nodiscard]] std::expected<Listing, Error> List(const VFSCancelChecker &_cancel_checker = {});

    // Sends "close" and drops the cached archive. The process stays alive and accepts another open.
    [[nodiscard]] std::expected<void, Error> Close(const VFSCancelChecker &_cancel_checker = {});

    // Target of the link entry at _index. RAR5 targets come from the listing cache; the helper
    // recovers RAR4 unix symlink targets from the entry payload on demand.
    [[nodiscard]] std::expected<std::string, Error> Link(uint32_t _index, const VFSCancelChecker &_cancel_checker = {});

    // Starts streaming the payload of the entry at _index and returns its size. The payload has to
    // be drained with ReadPayload(); a session with a partially read payload cannot be reused.
    [[nodiscard]] std::expected<uint64_t, Error> BeginRead(uint32_t _index,
                                                           const VFSCancelChecker &_cancel_checker = {});
    [[nodiscard]] std::expected<size_t, Error>
    ReadPayload(void *_buf, size_t _size, const VFSCancelChecker &_cancel_checker = {});
    [[nodiscard]] bool HasPendingPayload() const noexcept;

    // Stops the child with SIGTERM and makes the session unusable. Used for cancellation and after
    // a protocol error that leaves the stream out of sync; a fresh session is needed afterwards.
    void Discard() noexcept;

private:
    void Break() noexcept;
    [[nodiscard]] std::expected<void, Error> SendCommand(std::string_view _command,
                                                         const VFSCancelChecker &_cancel_checker);
    [[nodiscard]] std::expected<std::string, Error> ReadLine(const VFSCancelChecker &_cancel_checker);
    [[nodiscard]] std::expected<void, Error> WaitReadable(const VFSCancelChecker &_cancel_checker);

    std::optional<ChildProcess> m_Process;
    std::string m_Buffer; // data read from the child but not consumed yet
    uint64_t m_PayloadRemaining = 0;
    bool m_Healthy = false;
};

// An exclusive claim on a Session for the duration of one command sequence, e.g. one file read.
// The owner is handed the session back (or told to drop it) when the lease goes away.
class SessionLease
{
public:
    using Release = std::function<void(std::unique_ptr<Session> _session, bool _healthy)>;

    // Takes ownership of _session; _release may be empty when the lease owns a private session.
    SessionLease(std::unique_ptr<Session> _session, Release _release);
    SessionLease(const SessionLease &) = delete;
    SessionLease &operator=(const SessionLease &) = delete;
    ~SessionLease();

    [[nodiscard]] Session *operator->() const noexcept;
    [[nodiscard]] Session &Get() const noexcept;
    [[nodiscard]] bool IsValid() const noexcept;

    // Tells the owner that the session must not be reused (cancellation, partial payload, ...).
    void MarkBroken() noexcept;

private:
    std::unique_ptr<Session> m_Session;
    Release m_Release;
    bool m_Healthy = true;
};

} // namespace nc::vfs::rar
