// Copyright (C) 2026 Michael Kazakov. Subject to GNU General Public License version 3.
#pragma once

#include <Base/Error.h>
#include <VFS/VFSDeclarations.h>
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

// Locates the ncrar-helper executable. Checks $NCRAR_HELPER first, then the copy inside the
// user's Application Support directory, then the usual Homebrew prefixes. Returns nullopt when
// no usable helper is installed - the RAR support is optional and the app must work without it.
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

    // Same as Spawn(), but also connects a pipe to the child's stdin. Used by the persistent
    // "serve" mode, where commands are written to the child and responses are read back.
    [[nodiscard]] static std::expected<ChildProcess, Error> SpawnWithStdin(const std::string &_helper_path,
                                                                           const std::vector<std::string> &_args,
                                                                           const std::optional<std::string> &_password);

    [[nodiscard]] bool IsValid() const noexcept;
    [[nodiscard]] int StdoutFD() const noexcept;
    [[nodiscard]] int StdinFD() const noexcept;

    // Reads up to _size bytes from the child's stdout. Returns 0 at the end of the stream.
    [[nodiscard]] std::expected<size_t, Error> Read(void *_buf, size_t _size);

    // Writes all bytes to the child's stdin. A child that has gone away yields EPIPE instead of
    // killing the application with SIGPIPE.
    [[nodiscard]] std::expected<void, Error> WriteAll(const void *_buf, size_t _size);

    // Waits for the child to exit and returns its exit code. Should be called at most once.
    [[nodiscard]] std::expected<int, Error> Wait();

    // Closes the pipe, kills the child if it is still running and reaps it. Idempotent.
    void Terminate() noexcept;

private:
    static std::expected<ChildProcess, Error> SpawnImpl(const std::string &_helper_path,
                                                        const std::vector<std::string> &_args,
                                                        const std::optional<std::string> &_password,
                                                        bool _connect_stdin);
    void Reset() noexcept;

    pid_t m_Pid = -1;
    int m_Fd = -1;
    int m_StdinFd = -1;
};

} // namespace nc::vfs::rar
