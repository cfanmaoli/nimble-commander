// Copyright (C) 2026 Michael Kazakov. Subject to GNU General Public License version 3.
#include "Tests.h"
#include <NimbleCommander/Core/RustFileSearch.h>
#include <VFS/SearchForFiles.h>
#include <VFS/Native.h>
#include <Utility/FSEventsFileUpdateImpl.h>
#include <Utility/NativeFSManagerImpl.h>
#include <Utility/FileMask.h>

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <memory>
#include <string>
#include <vector>

#define PREFIX "RustFileSearch "

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

// A small tree with a known set of names:
//   a.txt  b.txt  c.md  notes.txt  sub/d.txt  sub/e.md  sub/deep/f.txt  empty/
std::filesystem::path MakeTree()
{
    const auto root = std::filesystem::temp_directory_path() / ("nc_rust_search_" + std::to_string(::getpid()));
    std::filesystem::remove_all(root);
    std::filesystem::create_directories(root / "sub" / "deep");
    std::filesystem::create_directories(root / "empty");
    for( const char *name : {"a.txt", "b.txt", "c.md", "notes.txt"} )
        std::ofstream(root / name) << "hello";
    std::ofstream(root / "sub" / "d.txt") << "x";
    std::ofstream(root / "sub" / "e.md") << "xy";
    std::ofstream(root / "sub" / "deep" / "f.txt") << "xyz";
    return root;
}

std::vector<std::string> RunCppSearch(const std::string &_root, const std::string &_mask)
{
    std::vector<std::string> found;
    nc::vfs::SearchForFiles search;
    if( !_mask.empty() )
        search.SetFilterName(nc::utility::FileMask{_mask, nc::utility::FileMask::Type::Mask});
    const bool started = search.Go(
        _root,
        Env().host,
        nc::vfs::SearchForFiles::Options::SearchForFiles | nc::vfs::SearchForFiles::Options::GoIntoSubDirs,
        [&](std::string_view _filename, const char *_in_path, VFSHost &, CFRange) {
            std::string path = _in_path;
            if( !path.empty() && path.back() != '/' )
                path += '/';
            found.emplace_back(path + std::string(_filename));
        },
        nullptr);
    REQUIRE(started);
    search.Wait();
    std::ranges::sort(found);
    return found;
}

std::vector<std::string> RunRustSearch(const std::string &_root, const std::string &_mask)
{
    std::vector<std::string> found;
    nc::core::RustFileSearch search;
    nc::core::RustFileSearch::Filter filter;
    filter.mask = _mask;
    filter.search_files = true;
    filter.search_dirs = false;
    filter.go_into_subdirs = true;
    bool finished = false;
    const bool started = search.Go(
        _root,
        filter,
        [&](const nc::core::RustFileSearch::Hit &_hit) { found.emplace_back(_hit.dir_path + _hit.name); },
        [&] { finished = true; });
    REQUIRE(started);
    search.Wait();
    REQUIRE(finished);
    std::ranges::sort(found);
    return found;
}

std::vector<std::string> Expected(const std::vector<std::string> &_all, const std::string &_mask)
{
    std::vector<std::string> result;
    const nc::utility::FileMask mask{_mask, nc::utility::FileMask::Type::Mask};
    for( const auto &path : _all ) {
        const auto name = std::filesystem::path(path).filename().string();
        if( mask.MatchName(name) )
            result.emplace_back(path);
    }
    return result;
}

} // namespace

TEST_CASE(PREFIX "finds the same files as the C++ search")
{
    const auto root = MakeTree();
    const std::string root_str = root.string();

    for( const std::string &mask : {std::string{}, std::string("*.txt"), std::string("*.md"), std::string("f*")} ) {
        const auto cpp = RunCppSearch(root_str, mask);
        const auto rust = RunRustSearch(root_str, mask);
        CHECK(cpp == rust);
        // and both agree with the expected set, computed from the mask directly
        if( !mask.empty() )
            CHECK(cpp == Expected(cpp, mask));
    }

    std::filesystem::remove_all(root);
}

TEST_CASE(PREFIX "respects the size filter")
{
    const auto root = MakeTree();
    nc::core::RustFileSearch search;
    nc::core::RustFileSearch::Filter filter;
    filter.mask = "*.txt";
    filter.min_size = 2;
    std::vector<std::string> found;
    REQUIRE(search.Go(root.string(), filter, [&](const auto &_hit) { found.emplace_back(_hit.name); }, nullptr));
    search.Wait();
    std::ranges::sort(found);
    // b.txt has 5 bytes, d.txt has 1, f.txt has 3, a.txt has 5, notes.txt has 5
    CHECK(found == std::vector<std::string>{"a.txt", "b.txt", "f.txt", "notes.txt"});
    std::filesystem::remove_all(root);
}

TEST_CASE(PREFIX "benchmark against the C++ walker")
{
    // Not an assertion on timing - it prints a comparable pair of numbers. Kept small so that
    // the unit-test run doesn't take long; the real numbers come from Scripts/perf.
    const auto root = std::filesystem::temp_directory_path() / ("nc_rust_search_bench_" + std::to_string(::getpid()));
    std::filesystem::remove_all(root);
    for( int d = 0; d != 20; ++d ) {
        std::filesystem::create_directories(root / ("d" + std::to_string(d)));
        for( int i = 0; i != 250; ++i )
            std::ofstream(root / ("d" + std::to_string(d)) / ("f" + std::to_string(i) + ".txt")) << "x";
    }
    const std::string root_str = root.string();

    const auto time = [](auto &&_fn) {
        const auto begin = std::chrono::steady_clock::now();
        _fn();
        return std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - begin).count();
    };

    size_t cpp_count = 0, rust_count = 0;
    const auto cpp_us = time([&] { cpp_count = RunCppSearch(root_str, "*.txt").size(); });
    const auto rust_us = time([&] { rust_count = RunRustSearch(root_str, "*.txt").size(); });
    CHECK(cpp_count == rust_count);
    CHECK(cpp_count == 5000);
    std::fprintf(stderr,
                 "[perf] rust_search cpp=%lldus rust=%lldus ratio=%.2f\n",
                 static_cast<long long>(cpp_us),
                 static_cast<long long>(rust_us),
                 rust_us ? static_cast<double>(cpp_us) / static_cast<double>(rust_us) : 0.0);
    std::filesystem::remove_all(root);
}
TEST_CASE(PREFIX "rejects masks it cannot handle")
{
    CHECK(nc::core::RustFileSearch::CanHandleMask("*.txt"));
    CHECK(nc::core::RustFileSearch::CanHandleMask(""));
    CHECK(!nc::core::RustFileSearch::CanHandleMask("*.txt,*.md"));
    CHECK(!nc::core::RustFileSearch::CanHandleMask("文件*"));

    nc::core::RustFileSearch search;
    nc::core::RustFileSearch::Filter filter;
    filter.mask = "*.txt,*.md";
    CHECK(!search.Go("/tmp", filter, nullptr, nullptr));
    filter.mask = "";
    CHECK(!search.Go("relative", filter, nullptr, nullptr));
}

TEST_CASE(PREFIX "cancellation stops the walk")
{
    const auto root = MakeTree();
    nc::core::RustFileSearch search;
    nc::core::RustFileSearch::Filter filter;
    filter.mask = "*.txt";
    std::atomic<int> found{0};
    REQUIRE(search.Go(root.string(), filter, [&](const auto &) { ++found; }, nullptr));
    search.Stop();
    search.Wait();
    // the exact count is a race, but the search must return and must not hang
    CHECK(search.IsRunning() == false);
    std::filesystem::remove_all(root);
}
