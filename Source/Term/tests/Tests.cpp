// Copyright (C) 2020-2024 Michael Kazakov. Subject to GNU General Public License version 3.
#include <catch2/catch_all.hpp>
#include <Base/CommonPaths.h>
#include <Base/ExecutionDeadline.h>
#include <Base/debug.h>
#include <cerrno>
#include <unistd.h>
#include <cstdlib>
#include <sys/stat.h>
#include <sys/fcntl.h>
#include <sys/dirent.h>
#include <string>
#include <vector>
#include "Tests.h"
#include <Log.h>
#include <spdlog/sinks/stdout_sinks.h>
#include <spdlog/sinks/ringbuffer_sink.h>
#include <iostream>

using namespace nc::term;

static auto g_TestDirPrefix = "_nc__term__test_";
[[clang::no_destroy]] static auto g_LogSink = std::make_shared<spdlog::sinks::ringbuffer_sink_mt>(1000);
[[clang::no_destroy]] static auto g_Log = std::make_shared<spdlog::logger>("term", g_LogSink);

static void DumpLog()
{
    std::cout << "Last log entries, up to 1000:" << '\n';
    for( const auto &line : g_LogSink->last_formatted(1000) )
        std::cout << line;
    std::cout << '\n';
}

struct CatchEventsListener : Catch::EventListenerBase {
    using EventListenerBase::EventListenerBase; // inherit constructor
    void assertionEnded(const Catch::AssertionStats &stats) override
    {
        if( !stats.assertionResult.isOk() ) {
            DumpLog();
        }
    }
};
CATCH_REGISTER_LISTENER(CatchEventsListener);

int main(int argc, char *argv[])
{
    const nc::base::ExecutionDeadline deadline(nc::base::AmIBeingDebugged() ? std::chrono::hours(1)
                                                                            : std::chrono::minutes(1));
    g_Log->set_level(spdlog::level::trace);
    Log::Set(g_Log);
    const int result = Catch::Session().run(argc, argv);
    return result;
}

static std::string MakeTempFilesStorage()
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

TempTestDir::TempTestDir()
{
    directory = MakeTempFilesStorage();
}

TempTestDir::~TempTestDir()
{
    std::error_code ec;
    std::filesystem::remove_all(directory, ec);
}
