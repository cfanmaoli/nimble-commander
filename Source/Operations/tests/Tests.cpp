// Copyright (C) 2019-2026 Michael Kazakov. Subject to GNU General Public License version 3.
#include <algorithm>
#include <atomic>
#include <cstdlib>
#include <iostream>
#include <thread>
#include <unistd.h>
#include <catch2/catch_all.hpp>

#define GTEST_DONT_DEFINE_FAIL 1
#define GTEST_DONT_DEFINE_SUCCEED 1
#include <gmock/gmock.h>

#include "Tests.h"
#include "TestEnv.h"
#include <Base/CommonPaths.h>
#include <Base/dispatch_cpp.h>
#include <sys/wait.h>

#include <spdlog/sinks/stdout_sinks.h>
#include <VFS/Log.h>

static auto g_TestDirPrefix = "_nc__operations__test_";

[[clang::no_destroy]] static auto g_LogSink = std::make_shared<spdlog::sinks::stdout_sink_mt>();
[[clang::no_destroy]] static auto g_Log = std::make_shared<spdlog::logger>("vfs", g_LogSink);

static int Execute(const std::string &_command);
static bool RunMainLoopUntilExpectationOrTimeout(std::chrono::nanoseconds _timeout, std::function<bool()> _expectation);
static bool WaitUntilNativeFSManSeesVolumeAtPath(const std::filesystem::path &volume_path,
                                                 std::chrono::nanoseconds _time_limit);

int main(int argc, char *argv[])
{
    //    g_Log->set_level(spdlog::level::trace);
    //    nc::vfs::Log::Set(g_Log);

    ::testing::GTEST_FLAG(throw_on_failure) = true;
    ::testing::InitGoogleMock(&argc, argv);
    const int result = Catch::Session().run(argc, argv);
    return result;
}

static std::string MakeTempFilesStorage()
{
    const auto &base_path = nc::base::CommonPaths::AppTemporaryDirectory();
    const auto tmp_path = base_path + g_TestDirPrefix + "/";
    if( access(tmp_path.c_str(), F_OK) == 0 )
        std::filesystem::remove_all(tmp_path);
    if( mkdir(tmp_path.c_str(), S_IRWXU) != 0 )
        throw std::runtime_error("mkdir failed");
    return tmp_path;
}

TempTestDir::TempTestDir()
{
    directory = MakeTempFilesStorage();
}

TempTestDir::~TempTestDir()
{
    try {
        std::filesystem::remove_all(directory);
    } catch( const std::exception &ex ) {
        std::cerr << ex.what() << '\n';
    }
}

TempTestDmg::TempTestDmg(TempTestDir &_test_dir)
{
    // hdiutil is not always cooperative, especially on CI, and a leftover mount of a previous image
    // makes attaching a new one with the same volume name fail - use a unique name and retry.
    static std::atomic_uint instances = 0;
    const auto volume_name = "nc_test_" + std::to_string(::getpid()) + "_" + std::to_string(instances++);
    const auto dmg_path = _test_dir.directory / "tmp_image.dmg";
    const auto create_cmd =
        "/usr/bin/hdiutil create -size 1m -fs HFS+ -volname " + volume_name + " " + dmg_path.native();
    if( Execute(create_cmd) != 0 )
        return;

    const auto mount_cmd = "/usr/bin/hdiutil attach -nobrowse " + dmg_path.native();
    bool mounted = false;
    for( int attempt = 0; attempt != 3 && !mounted; ++attempt ) {
        mounted = Execute(mount_cmd) == 0;
        if( !mounted )
            std::this_thread::sleep_for(std::chrono::seconds(1));
    }
    if( !mounted )
        return;

    const auto volume_path = std::filesystem::path("/Volumes") / volume_name;
    if( !WaitUntilNativeFSManSeesVolumeAtPath(volume_path, std::chrono::seconds(15)) ) {
        Execute("/usr/bin/hdiutil detach " + volume_path.native());
        return;
    }
    directory = volume_path;
}

TempTestDmg::~TempTestDmg()
{
    if( !directory.empty() )
        Execute("/usr/bin/hdiutil detach " + directory.native());
}

static int Execute(const std::string &_command)
{
    FILE *const pipe = ::popen(_command.c_str(), "r");
    if( pipe == nullptr )
        return -1;
    char buffer[1024];
    while( std::fgets(buffer, sizeof buffer, pipe) != nullptr )
        ;
    const int status = ::pclose(pipe);
    const int rc = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    if( rc != 0 )
        std::cerr << "Command failed with code " << rc << ": " << _command << '\n';
    return rc;
}

static bool RunMainLoopUntilExpectationOrTimeout(std::chrono::nanoseconds _timeout, std::function<bool()> _expectation)
{
    dispatch_assert_main_queue();
    assert(_timeout.count() > 0);
    assert(_expectation);
    const auto start_tp = std::chrono::steady_clock::now();
    const auto time_slice = 1. / 100.; // 10 ms;
    while( true ) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, time_slice, false);
        if( std::chrono::steady_clock::now() - start_tp > _timeout )
            return false;
        if( _expectation() )
            return true;
    }
}

static bool WaitUntilNativeFSManSeesVolumeAtPath(const std::filesystem::path &volume_path,
                                                 std::chrono::nanoseconds _time_limit)
{
    const auto predicate = [volume_path] {
        auto volumes = TestEnv().native_fs_man->Volumes();
        return std::ranges::any_of(volumes,
                                   [volume_path](auto _fs_info) { return _fs_info->mounted_at_path == volume_path; });
    };
    return RunMainLoopUntilExpectationOrTimeout(_time_limit, predicate);
}
