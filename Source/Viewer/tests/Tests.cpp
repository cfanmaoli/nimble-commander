// Copyright (C) 2018-2024 Michael Kazakov. Subject to GNU General Public License version 3.
#include <catch2/catch_all.hpp>
#include <Base/CommonPaths.h>
#include <cerrno>
#include <unistd.h>
#include <cstdlib>
#include <string>
#include <sys/stat.h>
#include <vector>
#include <sys/fcntl.h>
#include <sys/dirent.h>
#include "Tests.h"

static auto g_TestDirPrefix = "_nc__viewer__test_";

int main(int argc, char *argv[])
{
    return Catch::Session().run(argc, argv);
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
