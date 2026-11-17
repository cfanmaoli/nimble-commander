// Copyright (C) 2026 Michael Kazakov. Subject to GNU General Public License version 3.
#include "Tests.h"
#include <Base/algo.h>
#include <RoutedIO/Trash.h>
#include "../../RoutedIO/source/Trash.h" // detail::RemoveStagingTree, tested directly below
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

    SECTION("a directory enumeration failure is not treated as a complete copy")
    {
        const std::string trashed = mount + "/tree2";
        WriteFile(trashed + "/child.txt", "child");
        const std::string target = (dir.directory / "original" / "tree2").string();
        RememberOriginalPath(trashed, target);

        // Make readdir() fail after the first entry, as it would on a hardware error. The partial
        // directory must not be committed, and the source must stay in place.
        REQUIRE(::setenv("NC_TRASH_TEST_READDIR_EIO", "1", 1) == 0);
        const auto unset = at_scope_end([&] { ::unsetenv("NC_TRASH_TEST_READDIR_EIO"); });

        const nc::routedio::PutBackResult outcome = nc::routedio::PutBackTrashedItem(trashed);
        CHECK(!outcome.restored);
        CHECK(outcome.error == EIO);
        CHECK(std::filesystem::exists(trashed));
        CHECK(std::filesystem::exists(trashed + "/child.txt"));
        CHECK(!std::filesystem::exists(target));
        CHECK(StagingEntryCount(std::filesystem::path(target).parent_path().string()) == 0);
    }

    SECTION("a read-only directory that hits an occupied name leaves no staging copy")
    {
        const std::string trashed = mount + "/ro2";
        WriteFile(trashed + "/child.txt", "child");
        const std::string target = (dir.directory / "original" / "ro2").string();
        RememberOriginalPath(trashed, target);
        REQUIRE(::chmod(trashed.c_str(), 0500) == 0);
        std::filesystem::create_directories(target);

        const nc::routedio::PutBackResult outcome = nc::routedio::PutBackTrashedItem(trashed);
        REQUIRE(outcome.error == 0);
        REQUIRE(outcome.restored);
        const auto restore_mode = at_scope_end([&] { std::ignore = ::chmod(outcome.resulting_path.c_str(), 0700); });
        CHECK(outcome.resulting_path == (dir.directory / "original" / "ro2 2").string());
        CHECK(std::filesystem::is_directory(target)); // the occupied name stayed untouched
        CHECK(ReadFile(outcome.resulting_path + "/child.txt") == "child");
        CHECK(StagingEntryCount(std::filesystem::path(target).parent_path().string()) == 0);
        // The restored copy is read-only again, so the source can't be dropped - that is reported.
        CHECK(outcome.source_remains);
    }

    SECTION("a cancelled cross-volume copy leaves the item and no staging behind")
    {
        const std::string trashed = mount + "/cancel-dir";
        for( int i = 0; i != 8; ++i )
            WriteFile(trashed + "/file" + std::to_string(i) + ".txt", "x");
        const std::string target = (dir.directory / "original" / "cancel-dir").string();
        RememberOriginalPath(trashed, target);

        int checks = 0;
        const nc::routedio::PutBackResult outcome =
            nc::routedio::PutBackTrashedItem(trashed, [&checks] { return ++checks > 4; });
        CHECK(outcome.error == ECANCELED);
        CHECK(!outcome.restored);
        CHECK(std::filesystem::exists(trashed)); // the item is still in the trash
        CHECK(!std::filesystem::exists(target));
        CHECK(StagingEntryCount(std::filesystem::path(target).parent_path().string()) == 0);
    }

    SECTION("a tree with links and a read-only folder is restored as a copy")
    {
        const std::string external = (dir.directory / "external").string();
        WriteFile(external + "/file.txt", "untouched");
        REQUIRE(::chmod(external.c_str(), 0755) == 0);
        REQUIRE(::chmod((external + "/file.txt").c_str(), 0644) == 0);

        const std::string trashed = mount + "/links";
        WriteFile(trashed + "/readonly/child.txt", "child");
        REQUIRE(::symlink(external.c_str(), (trashed + "/directory-link").c_str()) == 0);
        REQUIRE(::symlink((external + "/file.txt").c_str(), (trashed + "/file-link").c_str()) == 0);
        REQUIRE(::symlink("missing", (trashed + "/dangling-link").c_str()) == 0);
        REQUIRE(::chmod((trashed + "/readonly").c_str(), 0500) == 0);

        const std::string target = (dir.directory / "original" / "links").string();
        std::filesystem::create_directories(target); // the restored copy gets a numbered name
        RememberOriginalPath(trashed, target);
        const std::string restored = (dir.directory / "original" / "links 2").string();
        const auto restore_mode = at_scope_end([&] {
            std::ignore = ::chmod((trashed + "/readonly").c_str(), 0700);
            std::ignore = ::chmod((restored + "/readonly").c_str(), 0700);
        });

        const nc::routedio::PutBackResult outcome = nc::routedio::PutBackTrashedItem(trashed);
        REQUIRE(outcome.error == 0);
        REQUIRE(outcome.restored);
        CHECK(outcome.resulting_path == restored);
        CHECK(ModeOf(external) == 0755);
        CHECK(ModeOf(external + "/file.txt") == 0644);
        CHECK(ReadFile(external + "/file.txt") == "untouched");
        CHECK(ReadFile(restored + "/readonly/child.txt") == "child");
        CHECK(std::filesystem::read_symlink(restored + "/directory-link") == external);
        CHECK(std::filesystem::read_symlink(restored + "/dangling-link") == "missing");
        CHECK(StagingEntryCount(std::filesystem::path(target).parent_path().string()) == 0);
    }
}

TEST_CASE(PREFIX "staging cleanup leaves symlink targets outside the copy alone")
{
    TestDir dir;
    const std::string external = (dir.directory / "external").string();
    WriteFile(external + "/file.txt", "untouched");
    REQUIRE(::chmod(external.c_str(), 0755) == 0);
    REQUIRE(::chmod((external + "/file.txt").c_str(), 0644) == 0);

    // A staging tree shaped like the one a cross-volume put-back leaves behind: a read-only
    // folder, links pointing outside the copy and a dangling link.
    const std::string staging = (dir.directory / "staging").string();
    WriteFile(staging + "/readonly/child.txt", "child");
    REQUIRE(::symlink(external.c_str(), (staging + "/directory-link").c_str()) == 0);
    REQUIRE(::symlink((external + "/file.txt").c_str(), (staging + "/file-link").c_str()) == 0);
    REQUIRE(::symlink("missing", (staging + "/dangling-link").c_str()) == 0);
    REQUIRE(::chmod((staging + "/readonly").c_str(), 0500) == 0);

    CHECK(nc::routedio::detail::RemoveStagingTree(staging) == 0);
    CHECK(!std::filesystem::exists(staging));
    // The cleanup may only change the staging tree itself, never what the links point at.
    CHECK(ModeOf(external) == 0755);
    CHECK(ModeOf(external + "/file.txt") == 0644);
    CHECK(ReadFile(external + "/file.txt") == "untouched");
}

TEST_CASE(PREFIX "emptying a trash folder removes items without following links")
{
    TestDir dir;
    const std::string external = (dir.directory / "external").string();
    WriteFile(external + "/keep.txt", "keep");
    const std::string trash = (dir.directory / "trash").string();
    WriteFile(trash + "/file.txt", "x");
    WriteFile(trash + "/sub/child.txt", "y");
    REQUIRE(::symlink(external.c_str(), (trash + "/link").c_str()) == 0);
    REQUIRE(::symlink((external + "/keep.txt").c_str(), (trash + "/file-link").c_str()) == 0);
    WriteFile(trash + "/.DS_Store", "ds");

    const nc::routedio::EmptyTrashResult result = nc::routedio::EmptyTrashDirectory(trash);
    CHECK(result.error == 0);
    CHECK(result.deleted == 4); // file.txt, sub, link, file-link
    CHECK(result.failed == 0);
    CHECK(!std::filesystem::exists(trash + "/file.txt"));
    CHECK(!std::filesystem::exists(trash + "/sub"));
    CHECK(!std::filesystem::exists(trash + "/link"));
    // The links were deleted as entries - their targets are untouched.
    CHECK(ReadFile(external + "/keep.txt") == "keep");
    // The Finder's bookkeeping file is not ours to delete.
    CHECK(std::filesystem::exists(trash + "/.DS_Store"));
}

TEST_CASE(PREFIX "a trash folder that is a symlink is refused")
{
    TestDir dir;
    const std::string external = (dir.directory / "external").string();
    WriteFile(external + "/keep.txt", "keep");
    const std::string fake_trash = (dir.directory / "trash-link").string();
    REQUIRE(::symlink(external.c_str(), fake_trash.c_str()) == 0);

    const nc::routedio::EmptyTrashResult result = nc::routedio::EmptyTrashDirectory(fake_trash);
    CHECK(result.error == ENOTDIR);
    CHECK(result.deleted == 0);
    CHECK(ReadFile(external + "/keep.txt") == "keep");
}

TEST_CASE(PREFIX "emptying a trash folder never deletes into a volume mounted below an item")
{
    TestDir dir;
    const std::string trash = (dir.directory / "trash").string();
    const std::string mount = trash + "/sub/nested";
    WriteFile(trash + "/item.txt", "x");
    std::filesystem::create_directories(mount);

    const auto image = (dir.directory / "volume.dmg").string();
    if( std::system(("hdiutil create -quiet -size 16m -fs APFS -volname NCEmptyUT '" + image + "'").c_str()) != 0 )
        SKIP("can't create a temporary disk image");
    const auto detach = at_scope_end(
        [&] { std::ignore = std::system(("hdiutil detach -quiet '" + mount + "' >/dev/null 2>&1").c_str()); });
    if( std::system(("hdiutil attach -quiet -nobrowse -mountpoint '" + mount + "' '" + image + "'").c_str()) != 0 )
        SKIP("can't attach a temporary disk image");
    WriteFile(mount + "/keep.txt", "keep");

    const nc::routedio::EmptyTrashResult result = nc::routedio::EmptyTrashDirectory(trash);
    CHECK(result.error == 0);
    CHECK(result.deleted == 1); // just item.txt
    CHECK(result.failed == 1);  // 'sub' is left alone because it contains a mounted volume
    CHECK(ReadFile(mount + "/keep.txt") == "keep");
    CHECK(std::filesystem::exists(trash + "/sub"));
}

TEST_CASE(PREFIX "a put-back can be cancelled before it starts")
{
    TestDir dir;
    const std::string trash = (dir.directory / "trash").string();
    std::filesystem::create_directories(trash);
    const std::string item = trash + "/item.txt";
    WriteFile(item, "x");
    RememberOriginalPath(item, (dir.directory / "original" / "item.txt").string());

    const nc::routedio::PutBackResult outcome = nc::routedio::PutBackTrashedItem(item, [] { return true; });
    CHECK(outcome.error == ECANCELED);
    CHECK(!outcome.restored);
    CHECK(std::filesystem::exists(item));
}

TEST_CASE(PREFIX "put-back refuses a destination that resolves into a trash folder")
{
    const std::vector<std::string> locations = nc::routedio::TrashLocations();
    if( locations.empty() )
        SKIP("no trash folder is available");

    TestDir dir;
    const std::string trash = (dir.directory / "trash").string();
    std::filesystem::create_directories(trash);
    const std::string item = trash + "/item.txt";
    WriteFile(item, "x");

    // A symlink that points into the real trash folder: the recorded location looks harmless, but
    // what it resolves to does not.
    const std::string link = (dir.directory / "link").string();
    REQUIRE(::symlink(locations.front().c_str(), link.c_str()) == 0);
    const std::string recorded = link + "/item.txt";
    REQUIRE(::setxattr(item.c_str(),
                       nc::routedio::detail::kOriginalLocationAttribute,
                       recorded.c_str(),
                       recorded.size(),
                       0,
                       XATTR_NOFOLLOW) == 0);

    const nc::routedio::PutBackResult outcome = nc::routedio::PutBackTrashedItem(item);
    CHECK(outcome.error == EINVAL);
    CHECK(std::filesystem::exists(item));
}

TEST_CASE(PREFIX "put-back refuses a recorded location that isn't a sane absolute path")
{
    TestDir dir;
    const std::string trash = (dir.directory / "trash").string();
    std::filesystem::create_directories(trash);
    const std::string item = trash + "/item.txt";
    WriteFile(item, "x");

    const auto set_location = [&](std::string_view _value) {
        REQUIRE(::setxattr(item.c_str(),
                           nc::routedio::detail::kOriginalLocationAttribute,
                           _value.data(),
                           _value.size(),
                           0,
                           XATTR_NOFOLLOW) == 0);
    };

    SECTION("a relative path")
    {
        set_location("relative/dir/item.txt");
        CHECK(nc::routedio::PutBackTrashedItem(item).error == EINVAL);
        CHECK(std::filesystem::exists(item));
    }
    SECTION("a path inside the trash")
    {
        // The check compares against the real trash folders - the test's own folder is just a
        // folder, not a trash location.
        const std::vector<std::string> locations = nc::routedio::TrashLocations();
        if( locations.empty() )
            SKIP("no trash folder is available");
        set_location(locations.front() + "/nested/item.txt");
        CHECK(nc::routedio::PutBackTrashedItem(item).error == EINVAL);
        CHECK(std::filesystem::exists(item));
    }
    SECTION("a path reaching into the trash via a dot-dot")
    {
        const std::vector<std::string> locations = nc::routedio::TrashLocations();
        if( locations.empty() )
            SKIP("no trash folder is available");
        const std::string name = std::filesystem::path(locations.front()).filename().string();
        set_location(locations.front() + "/../" + name + "/nested/item.txt");
        CHECK(nc::routedio::PutBackTrashedItem(item).error == EINVAL);
        CHECK(std::filesystem::exists(item));
    }
    SECTION("a normal absolute path still works")
    {
        const std::string target = (dir.directory / "restored.txt").string();
        set_location(target);
        const nc::routedio::PutBackResult outcome = nc::routedio::PutBackTrashedItem(item);
        REQUIRE(outcome.error == 0);
        CHECK(outcome.restored);
        CHECK(outcome.resulting_path == target);
        CHECK(ReadFile(target) == "x");
    }
}

TEST_CASE(PREFIX "emptying a trash folder behind a symlinked .Trashes is refused")
{
    TestDir dir;
    // The documented layout is '<volume>/.Trashes/<uid>', but here '.Trashes' is a symlink to an
    // ordinary directory that happens to contain a folder named like the uid. lstat() on the final
    // component alone resolves the link and accepts it - the same-device redirection that must be
    // refused before anything is deleted.
    const std::string drive = (dir.directory / "drive").string();
    std::filesystem::create_directories(drive);
    const std::string unrelated = (dir.directory / "unrelated").string();
    const std::string uid_dir = unrelated + "/" + std::to_string(getuid());
    WriteFile(uid_dir + "/keep.txt", "keep");
    REQUIRE(::symlink(unrelated.c_str(), (drive + "/.Trashes").c_str()) == 0);

    const nc::routedio::EmptyTrashResult result =
        nc::routedio::EmptyTrashDirectory(drive + "/.Trashes/" + std::to_string(getuid()));
    CHECK(result.error != 0);
    CHECK(result.deleted == 0);
    CHECK(ReadFile(uid_dir + "/keep.txt") == "keep");
}

TEST_CASE(PREFIX "emptying a trash folder only needs search access to its parent")
{
    TestDir dir;
    const auto parent = dir.directory / ".Trashes";
    const auto trash = parent / std::to_string(getuid());
    WriteFile((trash / "item.txt").string(), "trash");
    REQUIRE(::chmod(parent.c_str(), 01333) == 0);
    const auto restore_mode = at_scope_end([&] { std::ignore = ::chmod(parent.c_str(), 0700); });

    const auto result = nc::routedio::EmptyTrashDirectory(trash.string());
    CHECK(result.error == 0);
    CHECK(result.deleted == 1);
    CHECK(result.failed == 0);
    CHECK(!std::filesystem::exists(trash / "item.txt"));
}

TEST_CASE(PREFIX "an opened trash stays bound when its parent name is replaced")
{
    TestDir dir;
    const auto drive = dir.directory / "drive";
    const auto parent = drive / ".Trashes";
    const auto uid = std::to_string(getuid());
    const auto trash = parent / uid;
    const auto unrelated = dir.directory / "unrelated";
    WriteFile((trash / "keep.txt").string(), "original");
    WriteFile((unrelated / uid / "keep.txt").string(), "external");

    const int fd = nc::routedio::detail::OpenTrashDirectory(trash.string());
    REQUIRE(fd >= 0);
    const auto close_fd = at_scope_end([fd] { ::close(fd); });
    std::filesystem::rename(parent, drive / "saved");
    REQUIRE(::symlink(unrelated.c_str(), parent.c_str()) == 0);

    // Relative operations stay on the opened original; reopening the full pathname is refused.
    struct stat actual;
    struct stat expected;
    REQUIRE(::fstatat(fd, "keep.txt", &actual, AT_SYMLINK_NOFOLLOW) == 0);
    REQUIRE(::lstat((drive / "saved" / uid / "keep.txt").c_str(), &expected) == 0);
    CHECK(actual.st_ino == expected.st_ino);
    CHECK(actual.st_dev == expected.st_dev);
    CHECK(nc::routedio::EmptyTrashDirectory(trash.string()).error != 0);
    CHECK(ReadFile((unrelated / uid / "keep.txt").string()) == "external");
    CHECK(ReadFile((drive / "saved" / uid / "keep.txt").string()) == "original");
}

TEST_CASE(PREFIX "trash discovery does not require permission to read its contents")
{
    TestDir dir;
    const auto trash = dir.directory / "trash";
    WriteFile((trash / "item.txt").string(), "trash");
    REQUIRE(::chmod(trash.c_str(), 0100) == 0);
    const auto restore_mode = at_scope_end([&] { std::ignore = ::chmod(trash.c_str(), 0700); });
    const int fd = nc::routedio::detail::OpenTrashDirectory(trash.string(), false);
    REQUIRE(fd >= 0);
    ::close(fd);

    // It is still a known trash location, but an attempt to enumerate/delete it must report denial.
    CHECK(nc::routedio::EmptyTrashDirectory(trash.string()).error == EACCES);
}

#undef PREFIX
