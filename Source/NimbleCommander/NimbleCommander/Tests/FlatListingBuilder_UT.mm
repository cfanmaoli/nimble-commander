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

TEST_CASE(PREFIX "the Rust scan matches the VFS scan")
{
    const auto root = MakeTree();
    const auto &host = Env().host;
    const VFSCancelChecker no_cancel = nullptr;

    const auto vfs = nc::core::BuildFlatListingVFS(host, root.string() + "/", 0, no_cancel, 1'000'000, 1'000'000, 4);
    const auto rust = nc::core::BuildFlatListingRust(host, root.string() + "/", 0, no_cancel, 1'000'000, 1'000'000, 4);

    REQUIRE(vfs.listing);
    REQUIRE(rust.listing);
    const auto vfs_snapshot = Snapshot(vfs.listing);
    const auto rust_snapshot = Snapshot(rust.listing);
    if( vfs_snapshot != rust_snapshot ) {
        for( size_t i = 0; i != std::max(vfs_snapshot.size(), rust_snapshot.size()); ++i ) {
            const bool same =
                i < vfs_snapshot.size() && i < rust_snapshot.size() && vfs_snapshot[i] == rust_snapshot[i];
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
                         "  [%zu] vfs: %s\n        rust: %s\n",
                         i,
                         dump(vfs_snapshot, i).c_str(),
                         dump(rust_snapshot, i).c_str());
        }
    }
    CHECK(vfs_snapshot == rust_snapshot);
    CHECK(vfs.scanned_items == rust.scanned_items);
    CHECK(vfs.scanned_directories == rust.scanned_directories);

    // seven files (a.txt, b.txt, c.md, notes.txt, sub/d.txt, sub/e.md, sub/deep/f.txt) plus four
    // directories (sub, sub/deep, empty, sub/empty2)
    CHECK(vfs.scanned_items == 11);
    CHECK(rust.scanned_items == 11);

    std::filesystem::remove_all(root);
}

TEST_CASE(PREFIX "the Rust scan honours the item budget")
{
    const auto root = MakeTree();
    const auto &host = Env().host;
    const VFSCancelChecker no_cancel = nullptr;

    const auto rust = nc::core::BuildFlatListingRust(host, root.string() + "/", 0, no_cancel, 3, 1'000'000, 4);
    REQUIRE(rust.listing);
    CHECK(rust.truncated);
    CHECK(rust.scanned_items == 3);

    std::filesystem::remove_all(root);
}

TEST_CASE(PREFIX "the Rust scan falls back for non-native hosts")
{
    // BuildFlatListingRust forwards anything that is not a NativeHost to the VFS implementation;
    // with a null host it simply reports nothing.
    const VFSCancelChecker no_cancel = nullptr;
    const auto result = nc::core::BuildFlatListingRust(nullptr, "/tmp/", 0, no_cancel, 10, 10, 1);
    CHECK(!result.listing);
    CHECK(result.scanned_items == 0);
}
