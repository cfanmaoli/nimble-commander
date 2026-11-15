#include <catch2/catch_all.hpp>

#define GTEST_DONT_DEFINE_FAIL 1
#define GTEST_DONT_DEFINE_SUCCEED 1
#include <gmock/gmock.h>

#include "UnitTests_main.h"
#include <Base/CommonPaths.h>
#include <cerrno>
#include <unistd.h>
#include <cstdlib>
#include <string>
#include <vector>

static auto g_TestDirPrefix = "_nc__base__test_";

int main(int argc, char *argv[])
{
    ::testing::GTEST_FLAG(throw_on_failure) = true;
    ::testing::InitGoogleMock(&argc, argv);
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
