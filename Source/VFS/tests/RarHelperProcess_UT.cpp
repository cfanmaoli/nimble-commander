// Copyright (C) 2026 Michael Kazakov. Subject to GNU General Public License version 3.
#include "Tests.h"
#include <Base/CommonPaths.h>
#include <Base/algo.h>
#include "../source/ArcHelper/Helper.h"
#include "../source/ArcHelper/Protocol.h"
#include <chrono>
#include <fcntl.h>
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

TEST_CASE(PREFIX "the version response is parsed")
{
    const std::optional<nc::vfs::rar::HelperVersion> version =
        nc::vfs::rar::ParseVersionResponse(R"({"protocol":1,"unrar":700})");
    REQUIRE(version);
    CHECK(version->protocol == 1);
    CHECK(version->unrar == 700);

    // A response without a protocol, with a mistyped protocol or with no JSON at all is refused.
    CHECK_FALSE(nc::vfs::rar::ParseVersionResponse(R"({"unrar":700})"));
    CHECK_FALSE(nc::vfs::rar::ParseVersionResponse(R"({"protocol":"1"})"));
    CHECK_FALSE(nc::vfs::rar::ParseVersionResponse("not a json"));
}

TEST_CASE(PREFIX "a helper doesn't inherit the application's file descriptors")
{
    int fds[2] = {-1, -1};
    REQUIRE(::pipe(fds) == 0);
    // The probe must not land on one of the standard descriptors - the child keeps those open.
    const int probe_fd = ::fcntl(fds[0], F_DUPFD, 3);
    REQUIRE(probe_fd >= 3);
    const auto close_pipe = at_scope_end([&] {
        ::close(fds[0]);
        ::close(fds[1]);
        ::close(probe_fd);
    });

    // /dev/fd/N exists in the child only when the descriptor was inherited.
    const std::string command =
        "test -e /dev/fd/" + std::to_string(probe_fd) + " && printf 'present' || printf 'absent'";
    std::expected<nc::vfs::rar::ChildProcess, nc::Error> process =
        nc::vfs::rar::ChildProcess::Spawn("/bin/sh", {"-c", command}, std::nullopt);
    REQUIRE(process);
    const auto terminate = at_scope_end([&] { process->Terminate(); });

    std::string output;
    char buffer[64];
    for( ;; ) {
        const std::expected<size_t, nc::Error> read = process->Read(buffer, sizeof(buffer));
        REQUIRE(read);
        if( *read == 0 )
            break;
        output.append(buffer, *read);
    }
    CHECK(output == "absent");
}

TEST_CASE(PREFIX "reading from a stalled helper times out")
{
    std::expected<nc::vfs::rar::ChildProcess, nc::Error> process =
        nc::vfs::rar::ChildProcess::Spawn("/bin/sh", {"-c", "sleep 30"}, std::nullopt);
    REQUIRE(process);
    const auto terminate = at_scope_end([&] { process->Terminate(); });

    char buffer[8];
    const std::expected<size_t, nc::Error> read = process->Read(buffer, sizeof(buffer), std::chrono::milliseconds{50});
    REQUIRE(!read);
    CHECK(read.error().Code() == ETIMEDOUT);
}

TEST_CASE(PREFIX "a listing that takes too long is abandoned")
{
    std::expected<nc::vfs::rar::ChildProcess, nc::Error> process =
        nc::vfs::rar::ChildProcess::Spawn("/bin/sh", {"-c", "sleep 30"}, std::nullopt);
    REQUIRE(process);
    const auto terminate = at_scope_end([&] { process->Terminate(); });

    const std::expected<std::string, nc::Error> output =
        nc::vfs::rar::ReadChildOutput(*process, {}, std::chrono::milliseconds{100});
    REQUIRE(!output);
    CHECK(output.error().Code() == ETIMEDOUT);
}

TEST_CASE(PREFIX "only a helper that speaks the known protocol is used")
{
    const std::filesystem::path home_helper = std::filesystem::path(nc::base::CommonPaths::Home()) /
                                              "Applications/ncrar-helper.app/Contents/MacOS/ncrar-helper";
    if( std::filesystem::exists(home_helper) || std::filesystem::exists("/Applications/ncrar-helper.app") )
        SKIP("a real helper is installed");

    const auto create_helper = [&](int _protocol) {
        std::filesystem::create_directories(home_helper.parent_path());
        {
            std::ofstream helper(home_helper);
            helper << "#!/bin/sh\n"
                   << "if [ \"$1\" = version ]; then printf '{\"protocol\":" << _protocol
                   << ",\"unrar\":0}\\n'; exit 0; fi\n"
                   << "exit 2\n";
        }
        std::filesystem::permissions(home_helper, std::filesystem::perms::owner_all);
        std::ignore = std::system(("codesign -s - --force '" + home_helper.string() + "' >/dev/null 2>&1").c_str());
    };
    const auto cleanup = at_scope_end([&] {
        std::error_code ec;
        std::filesystem::remove_all(home_helper.parent_path().parent_path().parent_path(), ec);
        // FindHelper() caches its answer; without this reset the cache would keep pointing at the
        // fake and every helper test that runs later in this process would try to spawn a missing
        // file. (An environment without a real helper is the normal CI case, so this matters.)
        nc::vfs::rar::SetHelperEnabled(false);
        nc::vfs::rar::SetHelperEnabled(true);
    });

    // A helper that reports a protocol this build doesn't know is treated as unusable.
    create_helper(99);
    nc::vfs::rar::SetHelperEnabled(false);
    nc::vfs::rar::SetHelperEnabled(true);
    CHECK_FALSE(nc::vfs::rar::FindHelper().has_value());

    // The protocol this build implements makes it usable.
    create_helper(nc::vfs::rar::kSupportedProtocolVersion);
    nc::vfs::rar::SetHelperEnabled(false);
    nc::vfs::rar::SetHelperEnabled(true);
    CHECK(nc::vfs::rar::FindHelper().has_value());
}

#undef PREFIX
