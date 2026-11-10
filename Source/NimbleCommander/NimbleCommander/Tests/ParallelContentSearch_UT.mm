// Copyright (C) 2026 Michael Kazakov. Subject to GNU General Public License version 3.
#include "Tests.h"
#include <NimbleCommander/Core/ParallelContentSearch.h>
#include <VFS/SearchForFiles.h>
#include <VFS/Native.h>
#include <Utility/FSEventsFileUpdateImpl.h>
#include <Utility/NativeFSManagerImpl.h>

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <fmt/core.h>
#include <filesystem>
#include <fstream>
#include <memory>
#include <string>
#include <vector>

#define PREFIX "ParallelContentSearch "

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
    const auto root = std::filesystem::temp_directory_path() / ("nc_content_" + std::to_string(::getpid()));
    std::filesystem::remove_all(root);
    std::filesystem::create_directories(root / "sub");
    std::ofstream(root / "a.txt") << "the needle is here";
    std::ofstream(root / "b.txt") << "nothing to see";
    std::ofstream(root / "sub" / "c.txt") << "another NEEDLE";
    std::ofstream(root / "sub" / "d.bin") << "xxxxxxxx";
    return root;
}

std::vector<std::pair<std::string, uint64_t>>
RunCpp(const std::string &_root, const std::string &_text, const bool _case_sensitive)
{
    std::vector<std::pair<std::string, uint64_t>> found;
    nc::vfs::SearchForFiles search;
    nc::vfs::SearchForFiles::FilterContent filter;
    filter.text = _text;
    filter.encoding = nc::utility::Encoding::ENCODING_UTF8;
    filter.case_sensitive = _case_sensitive;
    search.SetFilterContent(filter);
    const bool started = search.Go(
        _root,
        Env().host,
        nc::vfs::SearchForFiles::Options::SearchForFiles | nc::vfs::SearchForFiles::Options::GoIntoSubDirs,
        [&](std::string_view _filename, const char *_in_path, nc::vfs::Host &, CFRange _range) {
            std::string dir = _in_path;
            if( !dir.empty() && dir.back() != '/' )
                dir += '/';
            found.emplace_back(dir + std::string(_filename),
                               _range.location >= 0 ? static_cast<uint64_t>(_range.location) : 0);
        },
        nullptr);
    REQUIRE(started);
    search.Wait();
    std::ranges::sort(found);
    return found;
}

std::vector<std::pair<std::string, uint64_t>>
RunParallel(const std::string &_root, const std::string &_text, const bool _case_sensitive)
{
    std::vector<std::pair<std::string, uint64_t>> found;
    nc::core::ParallelContentSearch search;
    nc::core::ParallelContentSearch::Filter filter;
    filter.text = _text;
    filter.case_sensitive = _case_sensitive;
    bool finished = false;
    const bool started = search.Go(
        _root,
        filter,
        [&](const nc::core::ParallelContentSearch::Hit &_hit) {
            found.emplace_back(_hit.dir_path + _hit.name, _hit.offset);
        },
        [&] { finished = true; });
    REQUIRE(started);
    search.Wait();
    REQUIRE(finished);
    std::ranges::sort(found);
    return found;
}

} // namespace

TEST_CASE(PREFIX "finds the same files as the C++ content search")
{
    const auto root = MakeTree();
    const std::string root_str = root.string();

    for( const bool case_sensitive : {false, true} ) {
        const auto cpp = RunCpp(root_str, "needle", case_sensitive);
        const auto par = RunParallel(root_str, "needle", case_sensitive);
        if( cpp != par ) {
            for( const auto &e : cpp )
                fmt::println(stderr, "  cpp: {} @ {}", e.first, e.second);
            for( const auto &e : par )
                fmt::println(stderr, "  par: {} @ {}", e.first, e.second);
        }
        CHECK(cpp == par);
    }

    std::filesystem::remove_all(root);
}

TEST_CASE(PREFIX "honours the maximum file size")
{
    const auto root = MakeTree();
    nc::core::ParallelContentSearch search;
    nc::core::ParallelContentSearch::Filter filter;
    filter.text = "needle";
    filter.max_file_size = 8; // "the needle is here" is longer than that
    std::vector<std::string> found;
    REQUIRE(search.Go(root.string(), filter, [&](const auto &_hit) { found.emplace_back(_hit.name); }, nullptr));
    search.Wait();
    CHECK(found.empty());
    CHECK(search.FilesSkipped() >= 1);
    std::filesystem::remove_all(root);
}

TEST_CASE(PREFIX "benchmark against the C++ content search")
{
    const auto root = std::filesystem::temp_directory_path() / ("nc_content_bench_" + std::to_string(::getpid()));
    std::filesystem::remove_all(root);
    std::filesystem::create_directories(root);
    std::string payload(4096, 'x');
    for( int i = 0; i != 2000; ++i ) {
        if( i % 10 == 0 )
            payload.replace(2000, 6, "needle");
        std::ofstream(root / ("f" + std::to_string(i) + ".txt")) << payload;
        payload = std::string(4096, 'x');
    }
    const std::string root_str = root.string();

    const auto time = [](auto &&_fn) {
        const auto begin = std::chrono::steady_clock::now();
        const size_t n = _fn();
        const auto us =
            std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - begin).count();
        return std::pair<size_t, long long>{n, us};
    };

    const auto [cpp_n, cpp_us] = time([&] { return RunCpp(root_str, "needle", false).size(); });
    const auto [rust_n, rust_us] = time([&] { return RunParallel(root_str, "needle", false).size(); });
    CHECK(cpp_n == rust_n);
    CHECK(cpp_n == 200);
    fmt::println(stderr,
                 "[perf] parallel_content cpp={}us rust={}us ratio={:.2f}",
                 cpp_us,
                 rust_us,
                 rust_us ? static_cast<double>(cpp_us) / static_cast<double>(rust_us) : 0.0);

    std::filesystem::remove_all(root);
}
