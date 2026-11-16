// Copyright (C) 2026 Michael Kazakov. Subject to GNU General Public License version 3.
#include "Tests.h"
#include "../source/ArcHelper/Helper.h"
#include <chrono>
#include <filesystem>
#include <fstream>
#include <string>
#include <tuple>
#include <vector>

#define PREFIX "RarHelper "

namespace {

// The exit status of the helper is the only place where it reports a checksum mismatch: it hands
// the payload out first and only then says whether the archive was valid. These tests pin down that
// the status is observable after the payload has been read.
std::optional<int> WaitForExit(const std::chrono::milliseconds _timeout, const char *_command)
{
    std::expected<nc::vfs::rar::ChildProcess, nc::Error> process =
        nc::vfs::rar::ChildProcess::Spawn("/bin/sh", {"-c", _command}, std::nullopt);
    if( !process )
        return std::nullopt;
    char buffer[64] = {};
    std::ignore = process->Read(buffer, sizeof(buffer));
    const std::expected<std::optional<int>, nc::Error> exit_code = process->WaitFor(_timeout);
    if( !exit_code || !exit_code->has_value() )
        return std::nullopt;
    return *exit_code;
}

} // namespace

TEST_CASE(PREFIX "a successful exit is reported after the payload")
{
    CHECK(WaitForExit(std::chrono::milliseconds{2000}, "printf 'payload'; exit 0") == 0);
}

TEST_CASE(PREFIX "a failure after the payload is reported")
{
    // The complete payload arrives first - that is exactly the case that used to be treated as a
    // successful read.
    CHECK(WaitForExit(std::chrono::milliseconds{2000}, "printf 'payload'; exit 4") == 4);
}

TEST_CASE(PREFIX "a helper that keeps running is not mistaken for a finished one")
{
    const std::optional<int> exit_code = WaitForExit(std::chrono::milliseconds{100}, "printf 'payload'; sleep 30");
    CHECK(!exit_code.has_value());
}

TEST_CASE(PREFIX "the helper executable must carry a code signature")
{
    const TestDir dir;

    // A copy of a system binary keeps its Apple-issued signature inside the Mach-O file.
    const std::string signed_path = (dir.directory / "signed-binary").string();
    std::filesystem::copy_file("/bin/cp", signed_path);
    CHECK(nc::vfs::rar::HasValidCodeSignature(signed_path));

    // A plain script is not signed - the app must not spawn something like that just because it sits
    // where the helper is expected.
    const std::string unsigned_path = (dir.directory / "unsigned-binary").string();
    {
        std::ofstream unsigned_file(unsigned_path);
        unsigned_file << "#!/bin/sh\nexit 0\n";
    }
    CHECK_FALSE(nc::vfs::rar::HasValidCodeSignature(unsigned_path));

    // A missing file is refused as well.
    CHECK_FALSE(nc::vfs::rar::HasValidCodeSignature((dir.directory / "missing").string()));
}

TEST_CASE(PREFIX "helper exit codes map onto POSIX errors")
{
    CHECK(nc::vfs::rar::ErrorForHelperExitCode(4) == nc::Error{nc::Error::POSIX, EIO});
    CHECK(nc::vfs::rar::ErrorForHelperExitCode(5) == nc::Error{nc::Error::POSIX, ENEEDAUTH});
    CHECK(nc::vfs::rar::ErrorForHelperExitCode(3) == nc::Error{nc::Error::POSIX, EFTYPE});
}

#undef PREFIX
