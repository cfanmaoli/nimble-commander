// Copyright (C) 2026 Michael Kazakov. Subject to GNU General Public License version 3.
#pragma once

#include <Base/Error.h>
#include <VFS/RarHelper.h>
#include <VFS/VFSDeclarations.h>
#include <chrono>
#include <expected>
#include <optional>
#include <string>
#include <string_view>
#include <sys/types.h>
#include <vector>

namespace nc::vfs {
class Host;
}

namespace nc::vfs::rar {

// The helper prints its output and exits; a stuck or hostile helper must not block the VFS worker
// threads forever. '_operation' bounds a whole list/link conversation, '_exit' bounds the final
// wait for the exit status and '_stall' bounds the gap between two chunks of a payload.
inline constexpr std::chrono::milliseconds kHelperOperationTimeout{120'000};
inline constexpr std::chrono::seconds kHelperExitTimeout{5};
inline constexpr std::chrono::milliseconds kHelperReadStallTimeout{60'000};

// Locates the ncrar-helper executable inside the ncrar-helper.app bundle in ~/Applications or
// /Applications. Returns nullopt when no usable helper is installed - the RAR support is optional
// and the app must work without it. A candidate must also answer its "version" command with a
// protocol this build understands.
[[nodiscard]] std::optional<std::string> FindHelper();

// Returns true when the first bytes of the file at _path carry the RAR signature, i.e. when the
// helper has a say about this file. Never inspects anything but the header.
[[nodiscard]] bool
LooksLikeRarArchive(Host &_parent, std::string_view _path, const VFSCancelChecker &_cancel_checker = {});

// Maps the helper's documented exit codes onto POSIX errors.
[[nodiscard]] Error ErrorForHelperExitCode(int _exit_code);

// A running helper process with its stdout connected to a pipe. The process is killed and reaped
// on destruction unless it has already been waited for.
class ChildProcess
{
public:
    ChildProcess() = default;
    ChildProcess(const ChildProcess &) = delete;
    ChildProcess &operator=(const ChildProcess &) = delete;
    ChildProcess(ChildProcess &&_rhs) noexcept;
    ChildProcess &operator=(ChildProcess &&_rhs) noexcept;
    ~ChildProcess();

    // Launches _helper_path with the specified arguments. The password, when present, is handed to
    // the child via the NCRAR_PASSWORD environment variable and never appears on the command line.
    [[nodiscard]] static std::expected<ChildProcess, Error> Spawn(const std::string &_helper_path,
                                                                  const std::vector<std::string> &_args,
                                                                  const std::optional<std::string> &_password);

    [[nodiscard]] bool IsValid() const noexcept;
    [[nodiscard]] int StdoutFD() const noexcept;

    // Reads up to _size bytes from the child's stdout. Returns 0 at the end of the stream.
    // '_stall_timeout' bounds how long the call waits for the next chunk, so a helper that stops
    // writing without exiting can't block the reader forever.
    [[nodiscard]] std::expected<size_t, Error>
    Read(void *_buf, size_t _size, std::chrono::milliseconds _stall_timeout = kHelperReadStallTimeout);

    // Waits for the child to exit and returns its exit code. Should be called at most once.
    [[nodiscard]] std::expected<int, Error> Wait();

    // Waits up to _timeout for the child to exit and returns its exit code, or nullopt when it is
    // still running by then. The child is not killed on timeout.
    [[nodiscard]] std::expected<std::optional<int>, Error> WaitFor(std::chrono::milliseconds _timeout);

    // Closes the pipe, kills the child if it is still running and reaps it. Idempotent.
    void Terminate() noexcept;

private:
    void Reset() noexcept;

    pid_t m_Pid = -1;
    int m_Fd = -1;
};

// Reads everything the child writes to stdout, checking for cancellation and for the total timeout
// while waiting. On a timeout the child is terminated. The output is capped at 512 MB - a listing of
// a million entries is well under a hundred.
[[nodiscard]] std::expected<std::string, Error>
ReadChildOutput(ChildProcess &_process,
                const VFSCancelChecker &_cancel_checker,
                std::chrono::milliseconds _timeout = kHelperOperationTimeout);

} // namespace nc::vfs::rar
