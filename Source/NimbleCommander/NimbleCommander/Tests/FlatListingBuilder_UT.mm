// Copyright (C) 2026 Michael Kazakov. Subject to GNU General Public License version 3.
#include "Tests.h"
#include <NimbleCommander/Core/FlatListingBuilder.h>
#include <VFS/Native.h>
#include <Utility/FSEventsFileUpdateImpl.h>
#include <Utility/NativeFSManagerImpl.h>

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <memory>
#include <string>
#include <tuple>
#include <vector>

#define PREFIX "FlatListingBuilder "

namespace {

struct NativeEnv {
    std::shared_ptr<nc::utility::FSEventsFileUpdate> fsevents;
    std::shared_ptr<nc::utility::NativeFSManager> fs_man;
    std::shared_ptr<nc::vfs::NativeHost> host;
};

const NativeEnv &Env()
{
    [[clang::no_destroy]] static const auto env = [] {
        auto e = std::make_unique<NativeEnv>();
        e->fsevents = std::make_shared<nc::utility::FSEventsFileUpdateImpl>();
        e->fs_man = std::make_shared<nc::utility::NativeFSManagerImpl>();
        e->host = std::make_shared<nc::vfs::NativeHost>(*e->fs_man, *e->fsevents);
        return e;
    }();
    return *env;
}

std::filesystem::path MakeTree()
{
    const auto root = std::filesystem::temp_directory_path() / ("nc_flat_builder_" + std::to_string(::getpid()));
    std::filesystem::remove_all(root);
    std::filesystem::create_directories(root / "sub" / "deep");
    std::filesystem::create_directories(root / "empty");
    std::filesystem::create_directories(root / "sub" / "empty2");
    for( const char *name : {"a.txt", "b.txt", "c.md", "notes.txt"} )
        std::ofstream(root / name) << "hello";
    std::ofstream(root / "sub" / "d.txt") << "x";
    std::ofstream(root / "sub" / "e.md") << "xy";
    std::ofstream(root / "sub" / "deep" / "f.txt") << "xyz";
    return root;
}

// A comparable, implementation-independent view of a flat listing.
using Entry = std::tuple<std::string, uint8_t, bool, uint64_t, int64_t>;

std::vector<Entry> Snapshot(const VFSListingPtr &_listing)
{
    std::vector<Entry> result;
    if( !_listing )
        return result;
    result.reserve(_listing->Count());
    for( unsigned i = 0; i != _listing->Count(); ++i ) {
        const VFSListingItem item{_listing, i};
        result.emplace_back(item.Directory() + item.Filename(),
                            item.UnixType(),
                            item.IsDir(),
                            item.HasSize() ? item.Size() : 0,
                            item.HasMTime() ? item.MTime() : 0);
    }
    std::ranges::sort(result);
    return result;
}

} // namespace

TEST_CASE(PREFIX "the columnar scan matches the composed one")
{
    const auto root = MakeTree();
    const auto &host = Env().host;
    const VFSCancelChecker no_cancel = nullptr;

    const auto composed =
        nc::core::BuildFlatListingComposed(host, root.string() + "/", 0, no_cancel, 1'000'000, 1'000'000, 4, 0.0, {});
    const auto columnar =
        nc::core::BuildFlatListingColumnar(host, root.string() + "/", 0, no_cancel, 1'000'000, 1'000'000, 4, 0.0, {});

    REQUIRE(composed.listing);
    REQUIRE(columnar.listing);
    const auto composed_snapshot = Snapshot(composed.listing);
    const auto columnar_snapshot = Snapshot(columnar.listing);
    if( composed_snapshot != columnar_snapshot ) {
        for( size_t i = 0; i != std::max(composed_snapshot.size(), columnar_snapshot.size()); ++i ) {
            const bool same = i < composed_snapshot.size() && i < columnar_snapshot.size() &&
                              composed_snapshot[i] == columnar_snapshot[i];
            if( same )
                continue;
            const auto dump = [](const std::vector<Entry> &_e, size_t _i) {
                if( _i >= _e.size() )
                    return std::string{"<missing>"};
                const auto &[path, type, is_dir, size, mtime] = _e[_i];
                return path + " type=" + std::to_string(type) + " dir=" + std::to_string(is_dir) +
                       " size=" + std::to_string(size) + " mtime=" + std::to_string(mtime);
            };
            std::fprintf(stderr,
                         "  [%zu] composed: %s\n        columnar: %s\n",
                         i,
                         dump(composed_snapshot, i).c_str(),
                         dump(columnar_snapshot, i).c_str());
        }
    }
    CHECK(composed_snapshot == columnar_snapshot);
    CHECK(composed.scanned_items == columnar.scanned_items);
    CHECK(composed.scanned_directories == columnar.scanned_directories);

    // seven files (a.txt, b.txt, c.md, notes.txt, sub/d.txt, sub/e.md, sub/deep/f.txt) plus four
    // directories (sub, sub/deep, empty, sub/empty2)
    CHECK(composed.scanned_items == 11);
    CHECK(columnar.scanned_items == 11);

    std::filesystem::remove_all(root);
}

TEST_CASE(PREFIX "the columnar scan honours the item budget")
{
    const auto root = MakeTree();
    const auto &host = Env().host;
    const VFSCancelChecker no_cancel = nullptr;

    const auto columnar =
        nc::core::BuildFlatListingColumnar(host, root.string() + "/", 0, no_cancel, 3, 1'000'000, 4, 0.0, {});
    REQUIRE(columnar.listing);
    CHECK(columnar.truncated);
    CHECK(columnar.scanned_items == 3);

    std::filesystem::remove_all(root);
}

TEST_CASE(PREFIX "the columnar scan falls back for non-native hosts")
{
    // BuildFlatListingColumnar forwards anything that is not a NativeHost to the composed implementation;
    // with a null host it simply reports nothing.
    const VFSCancelChecker no_cancel = nullptr;
    const auto result = nc::core::BuildFlatListingColumnar(nullptr, "/tmp/", 0, no_cancel, 10, 10, 1, 0.0, {});
    CHECK(!result.listing);
    CHECK(result.scanned_items == 0);
}

TEST_CASE(PREFIX "skips the requested cloud directories")
{
    const auto root = std::filesystem::temp_directory_path() / ("nc_flat_skip_" + std::to_string(::getpid()));
    std::filesystem::remove_all(root);
    std::filesystem::create_directories(root / "Library" / "CloudStorage" / "provider");
    std::filesystem::create_directories(root / "Library" / "Regular");
    std::ofstream(root / "Library" / "CloudStorage" / "provider" / "cloud.txt") << "x";
    std::ofstream(root / "Library" / "Regular" / "local.txt") << "x";

    const auto &host = Env().host;
    const VFSCancelChecker no_cancel = nullptr;
    const std::vector<std::string> prefixes{root.string() + "/Library/CloudStorage/"};
    const auto composed = nc::core::BuildFlatListingComposed(
        host, root.string() + "/", 0, no_cancel, 1'000'000, 1'000'000, 4, 0.0, prefixes);
    const auto columnar = nc::core::BuildFlatListingColumnar(
        host, root.string() + "/", 0, no_cancel, 1'000'000, 1'000'000, 4, 0.0, prefixes);

    REQUIRE(composed.listing);
    REQUIRE(columnar.listing);
    const auto composed_snapshot = Snapshot(composed.listing);
    const auto columnar_snapshot = Snapshot(columnar.listing);
    CHECK(composed_snapshot == columnar_snapshot);
    CHECK(composed.skipped_cloud_directories >= 1);
    CHECK(columnar.skipped_cloud_directories >= 1);

    for( const auto &entry : columnar_snapshot )
        CHECK(std::get<0>(entry).find("/CloudStorage/") == std::string::npos);
    bool saw_local = false;
    for( const auto &entry : columnar_snapshot )
        saw_local = saw_local || std::get<0>(entry).find("local.txt") != std::string::npos;
    CHECK(saw_local);

    std::filesystem::remove_all(root);
}
