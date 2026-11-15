// Copyright (C) 2018-2023 Michael Kazakov. Subject to GNU General Public License version 3.
#define CATCH_CONFIG_ENABLE_BENCHMARKING
#include <catch2/catch_all.hpp>

#define GTEST_DONT_DEFINE_FAIL 1
#define GTEST_DONT_DEFINE_SUCCEED 1
#include <gmock/gmock.h>

#include "Tests.h"
#include <Base/CommonPaths.h>
#include <Base/SysLocale.h>
#include <cerrno>
#include <unistd.h>
#include <cstdlib>
#include <ftw.h>
#include <string>
#include <vector>

#include <spdlog/sinks/stdout_sinks.h>
#include <VFS/Log.h>

static auto g_TestDirPrefix = "_nc__vfs__test_";

[[clang::no_destroy]] static auto g_LogSink = std::make_shared<spdlog::sinks::stdout_sink_mt>();
[[clang::no_destroy]] static auto g_Log = std::make_shared<spdlog::logger>("vfs", g_LogSink);

int main(int argc, char *argv[])
{
    //    g_Log->set_level(spdlog::level::trace);
    //    nc::vfs::Log::Set(g_Log);
    nc::base::SetSystemLocaleAsCLocale();
    ::testing::GTEST_FLAG(throw_on_failure) = true;
    ::testing::InitGoogleMock(&argc, argv);
    const int result = Catch::Session().run(argc, argv);
    return result;
}

TestDir::TestDir()
{
    directory = MakeTempFilesStorage();
}

TestDir::~TestDir()
{
    std::error_code ec;
    std::filesystem::remove_all(directory, ec);
}

std::string TestDir::MakeTempFilesStorage()
{
    // A unique directory per call: test binaries may run in parallel, and the leftovers of a
    // crashed run must not collide with the next one.
    const std::string base = nc::base::CommonPaths::AppTemporaryDirectory() + g_TestDirPrefix;
    for( int attempt = 1; attempt != 1000; ++attempt ) {
        const std::string path = base + std::to_string(::getpid()) + '-' + std::to_string(attempt);
        if( ::mkdir(path.c_str(), S_IRWXU) == 0 )
            return path + '/';
        if( errno != EEXIST )
            break;
    }
    throw std::runtime_error("cannot create a temporary test directory");
}
