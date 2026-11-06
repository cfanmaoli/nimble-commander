// Copyright (C) 2026 Michael Kazakov. Subject to GNU General Public License version 3.
#include "ParallelFileSearch.h"

#include <Utility/FileMask.h>

#include <algorithm>
#include <atomic>
#include <mutex>
#include <thread>
#include <utility>
#include <vector>

#include <dirent.h>
#include <sys/stat.h>

namespace nc::core {

struct ParallelFileSearch::Impl {
    std::thread worker;
    std::atomic<int32_t> cancel{0};
    std::atomic<bool> running{false};
    std::atomic<uint64_t> files_seen{0};
    std::atomic<uint64_t> dirs_seen{0};
    std::atomic<uint64_t> matches{0};
};

namespace {

void SplitRelativePath(std::string_view _relative, std::string &_name, std::string &_dir)
{
    // the paths come relative to the root, so they start with a slash which the directory part
    // must not repeat
    if( !_relative.empty() && _relative.front() == '/' )
        _relative.remove_prefix(1);
    const size_t slash = _relative.find_last_of('/');
    if( slash == std::string_view::npos ) {
        _name.assign(_relative);
        _dir.clear();
        return;
    }
    _name.assign(_relative.substr(slash + 1));
    _dir.assign(_relative.substr(0, slash + 1));
}

struct SearchContext {
    ParallelFileSearch::Impl *impl = nullptr;
    std::string root;
    utility::FileMask mask;
    bool search_files = true;
    bool search_dirs = false;
    bool go_into_subdirs = true;
    std::optional<uint64_t> min_size;
    std::optional<uint64_t> max_size;
    ParallelFileSearch::FoundCallback found;
    std::function<void()> finish;
    std::mutex mutex; // the callbacks must stay serial
};

void RunSearch(SearchContext &_ctx)
{
    const size_t threads = std::min<size_t>(std::max(1u, std::thread::hardware_concurrency()), 16);
    std::mutex queue_mutex;
    std::vector<std::string> queue{_ctx.root};
    std::atomic<size_t> working{0};
    auto cancelled = [&] { return _ctx.impl->cancel.load(std::memory_order_relaxed) != 0; };
    const bool size_filter = _ctx.min_size.has_value() || _ctx.max_size.has_value();

    const auto worker = [&] {
        for( ;; ) {
            if( cancelled() )
                return;
            std::string dir;
            {
                std::lock_guard lock{queue_mutex};
                if( queue.empty() ) {
                    if( working.load(std::memory_order_seq_cst) == 0 )
                        return;
                    continue;
                }
                dir = std::move(queue.back());
                queue.pop_back();
            }
            working.fetch_add(1, std::memory_order_seq_cst);

            if( DIR *const d = ::opendir(dir.c_str()) ) {
                std::vector<std::string> subdirs;
                while( dirent *const e = ::readdir(d) ) {
                    if( cancelled() )
                        break;
                    const std::string_view name{e->d_name};
                    if( name == "." || name == ".." )
                        continue;
                    std::string path = dir;
                    if( path.empty() || path.back() != '/' )
                        path += '/';
                    path += name;
                    const bool is_dir = e->d_type == DT_DIR;
                    if( is_dir ) {
                        _ctx.impl->dirs_seen.fetch_add(1, std::memory_order_relaxed);
                        if( _ctx.go_into_subdirs )
                            subdirs.emplace_back(path);
                    }
                    else {
                        _ctx.impl->files_seen.fetch_add(1, std::memory_order_relaxed);
                    }
                    if( is_dir ? !_ctx.search_dirs : !_ctx.search_files )
                        continue;
                    if( !_ctx.mask.IsEmpty() && !_ctx.mask.MatchName(name) )
                        continue;
                    uint64_t size = 0;
                    if( size_filter && !is_dir ) {
                        struct stat st{};
                        if( ::stat(path.c_str(), &st) != 0 )
                            continue;
                        size = static_cast<uint64_t>(st.st_size);
                        if( _ctx.min_size && size < *_ctx.min_size )
                            continue;
                        if( _ctx.max_size && size > *_ctx.max_size )
                            continue;
                    }
                    _ctx.impl->matches.fetch_add(1, std::memory_order_relaxed);
                    if( _ctx.found ) {
                        ParallelFileSearch::Hit hit;
                        std::string relative_dir;
                        SplitRelativePath(std::string_view{path}.substr(_ctx.root.size()), hit.name, relative_dir);
                        hit.dir_path = _ctx.root;
                        if( hit.dir_path.empty() || hit.dir_path.back() != '/' )
                            hit.dir_path += '/';
                        hit.dir_path += relative_dir;
                        hit.size = size;
                        hit.is_dir = is_dir;
                        std::lock_guard lock{_ctx.mutex};
                        _ctx.found(hit);
                    }
                }
                ::closedir(d);
                if( !subdirs.empty() ) {
                    std::lock_guard lock{queue_mutex};
                    for( auto &s : subdirs )
                        queue.emplace_back(std::move(s));
                }
            }
            working.fetch_sub(1, std::memory_order_seq_cst);
        }
    };

    std::vector<std::thread> pool;
    pool.reserve(threads);
    for( size_t i = 0; i != threads; ++i )
        pool.emplace_back(worker);
    for( auto &t : pool )
        t.join();
}

} // namespace

ParallelFileSearch::ParallelFileSearch() : m_Impl(std::make_unique<Impl>())
{
}

ParallelFileSearch::~ParallelFileSearch()
{
    Stop();
    Wait();
}

bool ParallelFileSearch::Go(const std::string &_root,
                            const Filter &_filter,
                            FoundCallback _found,
                            std::function<void()> _finish)
{
    if( IsRunning() )
        return false;
    if( _root.empty() || _root.front() != '/' )
        return false;
    if( _filter.min_size && _filter.max_size && *_filter.min_size > *_filter.max_size )
        return false;

    m_Impl->cancel = 0;
    m_Impl->files_seen = 0;
    m_Impl->dirs_seen = 0;
    m_Impl->matches = 0;

    auto *const ctx = new SearchContext{.impl = m_Impl.get(),
                                        .root = _root,
                                        .mask = utility::FileMask{_filter.mask},
                                        .search_files = _filter.search_files,
                                        .search_dirs = _filter.search_dirs,
                                        .go_into_subdirs = _filter.go_into_subdirs,
                                        .min_size = _filter.min_size,
                                        .max_size = _filter.max_size,
                                        .found = std::move(_found),
                                        .finish = std::move(_finish)};

    m_Impl->running = true;
    m_Impl->worker = std::thread([ctx] {
        RunSearch(*ctx);
        ParallelFileSearch::Impl *const impl = ctx->impl;
        impl->running = false;
        auto finish = std::move(ctx->finish);
        delete ctx;
        if( finish )
            finish();
    });
    return true;
}

void ParallelFileSearch::Stop()
{
    m_Impl->cancel = 1;
}

void ParallelFileSearch::Wait()
{
    if( m_Impl->worker.joinable() )
        m_Impl->worker.join();
}

bool ParallelFileSearch::IsRunning() const
{
    return m_Impl->running;
}

uint64_t ParallelFileSearch::FilesSeen() const
{
    return m_Impl->files_seen;
}

uint64_t ParallelFileSearch::DirsSeen() const
{
    return m_Impl->dirs_seen;
}

uint64_t ParallelFileSearch::Matches() const
{
    return m_Impl->matches;
}

} // namespace nc::core
