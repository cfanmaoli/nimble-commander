// Copyright (C) 2026 Michael Kazakov. Subject to GNU General Public License version 3.
#include "Tests.h"
#include <Base/algo.h>
#include <RoutedIO/Trash.h>
#include <cstdlib>
#include <fcntl.h>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <string>
#include <string_view>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <tuple>
#include <unistd.h>

#define PREFIX "Trash "

namespace {

// The attribute that the put-back reads its original location from. RoutedIO keeps the name
// private, so the tests spell it out - a rename there is a protocol change anyway.
constexpr const char *kOriginalPathAttr = "info.filesmanager.trash.originalPath";

void WriteFile(const std::string &_path, std::string_view _content)
{
    if( const std::filesystem::path parent = std::filesystem::path(_path).parent_path(); !parent.empty() )
        std::filesystem::create_directories(parent);
    std::ofstream file{_path, std::ios::binary | std::ios::trunc};
    file.write(_content.data(), static_cast<std::streamsize>(_content.size()));
}

std::string ReadFile(const std::string &_path)
{
    std::ifstream file{_path, std::ios::binary};
    return std::string{std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>()};
}

// Marks an item as trashed from '_original'. The production code records this when it moves an item
// into the Trash; the tests set it directly to be able to place an item anywhere.
void RememberOriginalPath(const std::string &_item, const std::string &_original)
{
    REQUIRE(::setxattr(_item.c_str(), kOriginalPathAttr, _original.data(), _original.size(), 0, XATTR_NOFOLLOW) == 0);
}

long AttributeSize(const std::string &_path, const char *_name, const int _flags = XATTR_NOFOLLOW)
{
    return static_cast<long>(::getxattr(_path.c_str(), _name, nullptr, 0, 0, _flags));
}

bool WriteResourceFork(const std::string &_path, std::string_view _data)
{
    const std::string fork = _path + "/..namedfork/rsrc";
    const int fd = ::open(fork.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if( fd < 0 )
        return false;
    const ssize_t written = ::write(fd, _data.data(), _data.size());
    ::close(fd);
    return written == static_cast<ssize_t>(_data.size());
}

void SetModificationTime(const std::string &_path, const time_t _time)
{
    const struct timespec times[2] = {
        {.tv_sec = _time, .tv_nsec = 0},
        {.tv_sec = _time, .tv_nsec = 0},
    };
    REQUIRE(::utimensat(AT_FDCWD, _path.c_str(), times, AT_SYMLINK_NOFOLLOW) == 0);
}

time_t ModificationTime(const std::string &_path)
{
    struct stat st;
    REQUIRE(::lstat(_path.c_str(), &st) == 0);
    return st.st_mtimespec.tv_sec;
}

// The put-back builds a cross-volume copy under a hidden staging name and only then claims the
// destination. Nothing may be left behind once the call returns, whether it succeeded or not.
size_t StagingEntryCount(const std::string &_directory)
{
    size_t count = 0;
    std::error_code ec;
    for( std::filesystem::directory_iterator it{_directory, ec}, end; !ec && it != end; it.increment(ec) )
        if( it->path().filename().string().starts_with(".nc-restore-") )
            ++count;
    return count;
}

mode_t ModeOf(const std::string &_path)
{
    struct stat st;
    REQUIRE(::lstat(_path.c_str(), &st) == 0);
    return st.st_mode & 07777;
}

} // namespace

TEST_CASE(PREFIX "put-back does not replace a dangling symlink")
{
    TestDir dir;
    const std::string trashed = (dir.directory / "item.txt").string();
    WriteFile(trashed, "restored content");

    // A dangling link still occupies its name - the item must get a numbered one instead of
    // silently destroying the link.
    const std::string target = (dir.directory / "original" / "item.txt").string();
    std::filesystem::create_directories(std::filesystem::path(target).parent_path());
    REQUIRE(::symlink("/nowhere", target.c_str()) == 0);
    RememberOriginalPath(trashed, target);

    const nc::routedio::PutBackResult outcome = nc::routedio::PutBackTrashedItem(trashed);
    CHECK(outcome.error == 0);
    CHECK(outcome.restored);
    CHECK(!outcome.source_remains);

    const std::string expected = (dir.directory / "original" / "item 2.txt").string();
    CHECK(outcome.resulting_path == expected);
    CHECK(std::filesystem::is_symlink(target));
    CHECK(std::filesystem::is_regular_file(expected));
    CHECK(ReadFile(expected) == "restored content");
    CHECK(!std::filesystem::exists(trashed));
}

TEST_CASE(PREFIX "put-back givens an occupied name a numbered one")
{
    TestDir dir;
    const std::string trashed = (dir.directory / "trash" / "report.pdf").string();
    WriteFile(trashed, "new");
    const std::string target = (dir.directory / "original" / "report.pdf").string();
    WriteFile(target, "existing");
    RememberOriginalPath(trashed, target);

    const nc::routedio::PutBackResult outcome = nc::routedio::PutBackTrashedItem(trashed);
    CHECK(outcome.error == 0);
    CHECK(outcome.restored);
    CHECK(outcome.resulting_path == (dir.directory / "original" / "report 2.pdf").string());
    CHECK(ReadFile(target) == "existing");
    CHECK(ReadFile(outcome.resulting_path) == "new");
}

TEST_CASE(PREFIX "put-back keeps the original-location marker on a symlink itself")
{
    TestDir dir;
    const std::string payload = (dir.directory / "data" / "payload.txt").string();
    WriteFile(payload, "content");
    const std::string link = (dir.directory / "data" / "link.txt").string();
    REQUIRE(::symlink("payload.txt", link.c_str()) == 0);

    // The marker belongs to the link: with the default (following) behaviour it would end up on
    // the file the link points at, which isn't the object being trashed.
    nc::routedio::RememberOriginalLocation(link);
    CHECK(AttributeSize(link, kOriginalPathAttr) == static_cast<long>(link.size()));
    CHECK(AttributeSize(payload, kOriginalPathAttr) == -1);

    // Move the link into the Trash - the marker travels with it.
    const std::string trashed = (dir.directory / "Trash" / "link.txt").string();
    std::filesystem::create_directories(std::filesystem::path(trashed).parent_path());
    std::filesystem::rename(link, trashed);

    const nc::routedio::PutBackResult outcome = nc::routedio::PutBackTrashedItem(trashed);
    CHECK(outcome.error == 0);
    CHECK(outcome.restored);
    CHECK(outcome.resulting_path == link);
    CHECK(std::filesystem::is_symlink(link));
    CHECK(std::filesystem::read_symlink(link) == "payload.txt");
    // The marker is gone from the restored link and never appears on its target.
    CHECK(AttributeSize(link, kOriginalPathAttr) == -1);
    CHECK(AttributeSize(payload, kOriginalPathAttr) == -1);
    CHECK(ReadFile(payload) == "content");
}

TEST_CASE(PREFIX "put-back reports an item without a known original location")
{
    TestDir dir;
    const std::string trashed = (dir.directory / ("nc-no-original-location-" + std::to_string(::getpid()))).string();
    WriteFile(trashed, "orphan");

    const nc::routedio::PutBackResult outcome = nc::routedio::PutBackTrashedItem(trashed);
    CHECK(!outcome.restored);
    CHECK(outcome.error == ENOENT);
    CHECK(outcome.resulting_path.empty());
    CHECK(std::filesystem::exists(trashed));
}

TEST_CASE(PREFIX "put-back across volumes preserves the data and the metadata")
{
    TestDir dir;
    const auto image = (dir.directory / "volume.dmg").string();
    const auto mount = (dir.directory / "mnt").string();
    std::filesystem::create_directories(mount);

    if( std::system(("hdiutil create -quiet -size 32m -fs APFS -volname NCTrashUT '" + image + "'").c_str()) != 0 )
        SKIP("can't create a temporary disk image");
    const auto detach = at_scope_end(
        [&] { std::ignore = std::system(("hdiutil detach -quiet '" + mount + "' >/dev/null 2>&1").c_str()); });
    if( std::system(("hdiutil attach -quiet -nobrowse -mountpoint '" + mount + "' '" + image + "'").c_str()) != 0 )
        SKIP("can't attach a temporary disk image");

    SECTION("a file keeps its extended attributes, resource fork and timestamps")
    {
        const std::string trashed = mount + "/item.txt";
        WriteFile(trashed, "cross-volume content");
        REQUIRE(::setxattr(trashed.c_str(), "user.nc-test", "v", 1, 0, 0) == 0);
        REQUIRE(WriteResourceFork(trashed, "0123456789abcdef"));
        SetModificationTime(trashed, 1'000'000'000);
        const std::string target = (dir.directory / "original" / "item.txt").string();
        RememberOriginalPath(trashed, target);

        const nc::routedio::PutBackResult outcome = nc::routedio::PutBackTrashedItem(trashed);
        REQUIRE(outcome.error == 0);
        REQUIRE(outcome.restored);
        CHECK(outcome.resulting_path == target);
        CHECK(!std::filesystem::exists(trashed));
        CHECK(ReadFile(target) == "cross-volume content");
        CHECK(AttributeSize(target, "user.nc-test") == 1);
        CHECK(AttributeSize(target, "com.apple.ResourceFork") == 16);
        CHECK(ModificationTime(target) == 1'000'000'000);
    }

    SECTION("a directory is copied together with its contents")
    {
        const std::string trashed = mount + "/tree";
        WriteFile(trashed + "/nested/file.txt", "nested content");
        const std::string target = (dir.directory / "original" / "tree").string();
        RememberOriginalPath(trashed, target);

        const nc::routedio::PutBackResult outcome = nc::routedio::PutBackTrashedItem(trashed);
        REQUIRE(outcome.error == 0);
        REQUIRE(outcome.restored);
        CHECK(ReadFile(target + "/nested/file.txt") == "nested content");
        CHECK(!std::filesystem::exists(trashed));
    }

    SECTION("a source that can't be removed is reported")
    {
        const std::string folder = mount + "/locked";
        const std::string trashed = folder + "/item.txt";
        WriteFile(trashed, "keep the source");
        const std::string target = (dir.directory / "original" / "locked.txt").string();
        RememberOriginalPath(trashed, target);

        // The copy itself only needs to read the folder - dropping the source needs write access.
        REQUIRE(::chmod(folder.c_str(), 0500) == 0);
        const auto restore_mode = at_scope_end([&] { std::ignore = ::chmod(folder.c_str(), 0700); });

        const nc::routedio::PutBackResult outcome = nc::routedio::PutBackTrashedItem(trashed);
        CHECK(outcome.error == 0);
        CHECK(outcome.restored);
        CHECK(outcome.source_remains);
        CHECK(ReadFile(target) == "keep the source");
        CHECK(std::filesystem::exists(trashed));
    }

    SECTION("a failing copy leaves the existing target untouched")
    {
        const std::string trashed = mount + "/secret.bin";
        WriteFile(trashed, "unreadable");
        const std::string target = (dir.directory / "original" / "secret.bin").string();
        WriteFile(target, "pre-existing");
        RememberOriginalPath(trashed, target);
        REQUIRE(::chmod(trashed.c_str(), 0000) == 0);
        const auto restore_mode = at_scope_end([&] { std::ignore = ::chmod(trashed.c_str(), 0600); });

        const nc::routedio::PutBackResult outcome = nc::routedio::PutBackTrashedItem(trashed);
        CHECK(!outcome.restored);
        CHECK(outcome.error != 0);
        // The copy never got to touch the destination, and its staging leftovers are gone.
        CHECK(ReadFile(target) == "pre-existing");
        CHECK(std::filesystem::exists(trashed));
        CHECK(StagingEntryCount(std::filesystem::path(target).parent_path().string()) == 0);
    }

    SECTION("a read-only directory is restored together with its contents")
    {
        const std::string trashed = mount + "/ro";
        WriteFile(trashed + "/child.txt", "child");
        const std::string target = (dir.directory / "original" / "ro").string();
        RememberOriginalPath(trashed, target);
        // The marker has to be written while the directory is still writable.
        REQUIRE(::chmod(trashed.c_str(), 0500) == 0);

        const nc::routedio::PutBackResult outcome = nc::routedio::PutBackTrashedItem(trashed);
        const auto restore_mode = at_scope_end([&] { std::ignore = ::chmod(target.c_str(), 0700); });
        REQUIRE(outcome.error == 0);
        REQUIRE(outcome.restored);
        CHECK(ReadFile(target + "/child.txt") == "child");
        CHECK(ModeOf(target) == 0500);
        // Dropping the source needs write access to the source directory itself, so it stays.
        CHECK(outcome.source_remains);
    }

    SECTION("an occupied cross-volume name gets a numbered one")
    {
        const std::string trashed = mount + "/item2.txt";
        WriteFile(trashed, "new");
        const std::string target = (dir.directory / "original" / "item2.txt").string();
        WriteFile(target, "old");
        RememberOriginalPath(trashed, target);

        const nc::routedio::PutBackResult outcome = nc::routedio::PutBackTrashedItem(trashed);
        REQUIRE(outcome.error == 0);
        REQUIRE(outcome.restored);
        CHECK(outcome.resulting_path == (dir.directory / "original" / "item2 2.txt").string());
        CHECK(ReadFile(target) == "old");
        CHECK(ReadFile(outcome.resulting_path) == "new");
        CHECK(!std::filesystem::exists(trashed));
        CHECK(StagingEntryCount(std::filesystem::path(target).parent_path().string()) == 0);
    }
}

#undef PREFIX
