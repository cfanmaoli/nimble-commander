// Copyright (C) 2020 Michael Kazakov. Subject to GNU General Public License version 3.
#include <catch2/catch_all.hpp>

#define GTEST_DONT_DEFINE_FAIL 1
#define GTEST_DONT_DEFINE_SUCCEED 1
#include <gmock/gmock.h>

#include <Base/CommonPaths.h>
#include <cerrno>
#include <unistd.h>
#include <cstdlib>
#include <string>
#include <sys/stat.h>
#include <sys/fcntl.h>
#include <sys/dirent.h>
#include <ftw.h>
#include <vector>

#include "Tests.h"

static auto g_TestDirPrefix = "_nc__common__test_";

int main(int argc, char *argv[])
{
    ::testing::GTEST_FLAG(throw_on_failure) = true;
    ::testing::InitGoogleMock(&argc, argv);
    const int result = Catch::Session().run(argc, argv);
    return result;
}

static int RMRF(const std::string &_path)
{
    const auto unlink_cb = [](const char *fpath,
                              [[maybe_unused]] const struct stat *sb,
                              int typeflag,
                              [[maybe_unused]] struct FTW *ftwbuf) {
        if( typeflag == FTW_F )
            unlink(fpath);
        else if( typeflag == FTW_D || typeflag == FTW_DNR || typeflag == FTW_DP )
            rmdir(fpath);
        return 0;
    };
    return nftw(_path.c_str(), unlink_cb, 64, FTW_DEPTH | FTW_PHYS | FTW_MOUNT);
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
    RMRF(directory);
}
