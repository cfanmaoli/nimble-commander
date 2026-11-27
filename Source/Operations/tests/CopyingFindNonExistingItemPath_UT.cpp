// Copyright (C) 2017-2025 Michael Kazakov. Subject to GNU General Public License version 3.
#include "Tests.h"
#include "TestEnv.h"
#include "../source/Copying/Helpers.h"
#include "../source/Copying/ChecksumExpectation.h"

namespace CopyingTests {

using nc::ops::copying::FindNonExistingItemPath;

#define PREFIX "nc::ops::FindNonExistingItemPath "

TEST_CASE(PREFIX "checksum expectation accepts a SHA-256 digest")
{
    const std::vector<uint8_t> digest(32, 0xAB);
    const nc::ops::copying::ChecksumExpectation expectation(0, "/tmp/destination", digest);
    CHECK(expectation.digest_size == digest.size());
    CHECK(expectation == digest);

    const std::vector<uint8_t> md5(16, 0xCD);
    CHECK_FALSE(expectation == md5);

    const std::vector<uint8_t> same_prefix_md5(16, 0xAB);
    CHECK_FALSE(expectation == same_prefix_md5);

    CHECK_THROWS_AS(nc::ops::copying::ChecksumExpectation(0, "/tmp/destination", std::vector<uint8_t>{}),
                    std::invalid_argument);
    CHECK_THROWS_AS(nc::ops::copying::ChecksumExpectation(0, "/tmp/destination", std::vector<uint8_t>(33, 0x11)),
                    std::invalid_argument);
}

TEST_CASE(PREFIX "regular file without extension")
{
    const TempTestDir dir;

    const auto orig_path = dir.directory / "item";
    close(open((orig_path / "item").c_str(), O_WRONLY | O_CREAT, S_IWUSR | S_IRUSR));

    auto proposed_path = FindNonExistingItemPath(orig_path.native(), *TestEnv().vfs_native);

    CHECK(proposed_path == (dir.directory / "item 2").native());
}

TEST_CASE(PREFIX "doesnt check the initial path")
{
    const TempTestDir dir;
    const auto orig_path = dir.directory / "item";

    auto proposed_path = FindNonExistingItemPath(orig_path.native(), *TestEnv().vfs_native);

    CHECK(proposed_path == (dir.directory / "item 2").native());
}

TEST_CASE(PREFIX "regular file without extension when possible targets already exists")
{
    const TempTestDir dir;
    const auto orig_path = dir.directory / "item";
    close(open((dir.directory / "item").c_str(), O_WRONLY | O_CREAT, S_IWUSR | S_IRUSR));
    close(open((dir.directory / "item 2").c_str(), O_WRONLY | O_CREAT, S_IWUSR | S_IRUSR));
    close(open((dir.directory / "item 3").c_str(), O_WRONLY | O_CREAT, S_IWUSR | S_IRUSR));
    close(open((dir.directory / "item 4").c_str(), O_WRONLY | O_CREAT, S_IWUSR | S_IRUSR));

    auto proposed_path = FindNonExistingItemPath(orig_path.native(), *TestEnv().vfs_native);

    CHECK(proposed_path == (dir.directory / "item 5").native());
}

TEST_CASE(PREFIX "regular file with extension")
{
    const TempTestDir dir;
    const auto orig_path = dir.directory / "item.zip";

    auto proposed_path = FindNonExistingItemPath(orig_path.native(), *TestEnv().vfs_native);

    CHECK(proposed_path == (dir.directory / "item 2.zip").native());
}

TEST_CASE(PREFIX "regular file with extension when possible targets already exists")
{
    const TempTestDir dir;
    const auto orig_path = dir.directory / "item.zip";
    close(open((dir.directory / "item.zip").c_str(), O_WRONLY | O_CREAT, S_IWUSR | S_IRUSR));
    close(open((dir.directory / "item 2.zip").c_str(), O_WRONLY | O_CREAT, S_IWUSR | S_IRUSR));
    close(open((dir.directory / "item 3.zip").c_str(), O_WRONLY | O_CREAT, S_IWUSR | S_IRUSR));
    close(open((dir.directory / "item 4.zip").c_str(), O_WRONLY | O_CREAT, S_IWUSR | S_IRUSR));

    auto proposed_path = FindNonExistingItemPath(orig_path.native(), *TestEnv().vfs_native);

    CHECK(proposed_path == (dir.directory / "item 5.zip").native());
}

TEST_CASE(PREFIX "checks magnitudes of tens")
{
    const TempTestDir dir;
    const auto orig_path = dir.directory / "item.zip";
    close(open((dir.directory / "item.zip").c_str(), O_WRONLY | O_CREAT, S_IWUSR | S_IRUSR));
    for( int i = 2; i <= 9; ++i )
        close(open(
            (dir.directory / ("item " + std::to_string(i) + ".zip")).c_str(), O_WRONLY | O_CREAT, S_IWUSR | S_IRUSR));

    auto proposed_path = FindNonExistingItemPath(orig_path.native(), *TestEnv().vfs_native);

    CHECK(proposed_path == (dir.directory / "item 10.zip").native());
}

TEST_CASE(PREFIX "checks magnitudes of hundreds")
{
    const TempTestDir dir;
    const auto orig_path = dir.directory / "item.zip";
    close(open((dir.directory / "item.zip").c_str(), O_WRONLY | O_CREAT, S_IWUSR | S_IRUSR));
    for( int i = 2; i <= 99; ++i )
        close(open(
            (dir.directory / ("item " + std::to_string(i) + ".zip")).c_str(), O_WRONLY | O_CREAT, S_IWUSR | S_IRUSR));

    auto proposed_path = FindNonExistingItemPath(orig_path.native(), *TestEnv().vfs_native);

    CHECK(proposed_path == (dir.directory / "item 100.zip").native());
}

TEST_CASE(PREFIX "returns empty string on cancellation")
{
    const TempTestDir dir;
    const auto orig_path = dir.directory / "item.zip";
    const auto cancel = [] { return true; };

    const auto proposed_path = FindNonExistingItemPath(orig_path.native(), *TestEnv().vfs_native, cancel);

    CHECK(proposed_path.empty());
}

} // namespace CopyingTests

#undef PREFIX
