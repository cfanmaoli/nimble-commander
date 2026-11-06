// Copyright (C) 2026 Michael Kazakov. Subject to GNU General Public License version 3.
#include "RustFileSearch.h"
#include "nc_core.h"

#include <atomic>
#include <mutex>
#include <thread>

namespace nc::core {

struct RustFileSearch::Impl {
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
    const size_t slash = _relative.find_last_of('/');
    if( slash == std::string_view::npos ) {
        _name.assign(_relative);
        _dir.clear();
        return;
    }
    _name.assign(_relative.substr(slash + 1));
    _dir.assign(_relative.substr(0, slash + 1));
}

// Everything the worker thread needs; it is deleted by the worker itself once the search is over.
struct SearchContext {
    RustFileSearch::Impl *impl = nullptr;
    std::string root;
    std::string mask;
    bool min_size_set = false;
    bool max_size_set = false;
    uint64_t min_size = 0;
    uint64_t max_size = 0;
    RustFileSearch::FoundCallback found;
    std::function<void()> finish;
    // The Rust side calls back from every worker thread it has; the C++ callers (and the search
    // UI) expect a serial callback stream like the one SearchForFiles produces, so the boundary
    // serialises them here. (The spike report's "坑 3" is exactly this: without it the callers
    // lose counts / corrupt their state.)
    std::mutex found_mutex;
    // lives here (and not on the stack of Go()) because the worker thread needs it; the string
    // pointers below point into root/mask, which are stable for the whole lifetime of the context
    nc_search_params params{};
};

void OnFound(void *_ctx, const char *_rel, const bool _is_dir, const uint64_t _size, int64_t /*_mtime*/)
{
    auto *const ctx = static_cast<SearchContext *>(_ctx);
    // directories have no meaningful size for this filter, same as in the C++ implementation
    if( !_is_dir ) {
        if( ctx->min_size_set && _size < ctx->min_size )
            return;
        if( ctx->max_size_set && _size > ctx->max_size )
            return;
    }
    if( !ctx->found )
        return;
    RustFileSearch::Hit hit;
    std::string relative_dir;
    SplitRelativePath(_rel, hit.name, relative_dir);
    // the ABI hands over a path relative to the root, while the C++ callers (and the search UI)
    // expect the directory the entry lives in, absolute and with a trailing slash
    hit.dir_path = ctx->root;
    if( hit.dir_path.empty() || hit.dir_path.back() != '/' )
        hit.dir_path += '/';
    hit.dir_path += relative_dir;
    hit.size = _size;
    hit.is_dir = _is_dir;
    {
        const std::lock_guard<std::mutex> lock{ctx->found_mutex};
        ctx->found(hit);
    }
}

} // namespace

RustFileSearch::RustFileSearch() : m_Impl(std::make_unique<Impl>())
{
}

RustFileSearch::~RustFileSearch()
{
    Stop();
    Wait();
}

bool RustFileSearch::CanHandleMask(const std::string_view _mask)
{
    // The Rust matcher understands a single classic mask. The C++ FileMask also accepts
    // comma-separated lists and regular expressions, and it normalises the names to lowercase
    // rather than doing a per-character Unicode comparison - so anything non-trivial stays with
    // the C++ implementation.
    if( _mask.find(',') != std::string_view::npos )
        return false;
    for( const char c : _mask )
        if( static_cast<unsigned char>(c) > 0x7F )
            return false;
    return true;
}

bool RustFileSearch::Go(const std::string &_root,
                        const Filter &_filter,
                        FoundCallback _found,
                        std::function<void()> _finish)
{
    if( IsRunning() )
        return false;
    if( _root.empty() || _root.front() != '/' )
        return false;
    if( !CanHandleMask(_filter.mask) )
        return false;
    if( _filter.min_size && _filter.max_size && *_filter.min_size > *_filter.max_size )
        return false;

    m_Impl->cancel = 0;
    m_Impl->files_seen = 0;
    m_Impl->dirs_seen = 0;
    m_Impl->matches = 0;

    auto *const ctx = new SearchContext{.impl = m_Impl.get(),
                                        .root = _root,
                                        .mask = _filter.mask,
                                        .min_size_set = _filter.min_size.has_value(),
                                        .max_size_set = _filter.max_size.has_value(),
                                        .min_size = _filter.min_size.value_or(0),
                                        .max_size = _filter.max_size.value_or(0),
                                        .found = std::move(_found),
                                        .finish = std::move(_finish)};

    ctx->params.root = ctx->root.c_str();
    ctx->params.mask = ctx->mask.empty() ? nullptr : ctx->mask.c_str();
    ctx->params.options = (_filter.search_files ? NC_CORE_SEARCH_FILES : 0u) |
                          (_filter.search_dirs ? NC_CORE_SEARCH_DIRS : 0u) |
                          (_filter.case_sensitive ? 0u : NC_CORE_SEARCH_CASE_INSENSITIVE);
    ctx->params.threads = 0;
    ctx->params.on_found = &OnFound;
    ctx->params.ctx = ctx;
    ctx->params.cancel_flag = reinterpret_cast<const int32_t *>(&m_Impl->cancel);

    m_Impl->running = true;
    m_Impl->worker = std::thread([ctx] {
        nc_search_stats stats{};
        const int32_t rc = nc_core_search_native(&ctx->params, &stats);
        (void)rc;
        RustFileSearch::Impl *const impl = ctx->impl;
        impl->files_seen = stats.files_seen;
        impl->dirs_seen = stats.dirs_seen;
        impl->matches = stats.matches;
        impl->running = false;
        auto finish = std::move(ctx->finish);
        delete ctx;
        if( finish )
            finish();
    });

    return true;
}

void RustFileSearch::Stop()
{
    m_Impl->cancel = 1;
}

void RustFileSearch::Wait()
{
    if( m_Impl->worker.joinable() )
        m_Impl->worker.join();
}

bool RustFileSearch::IsRunning() const
{
    return m_Impl->running;
}

uint64_t RustFileSearch::FilesSeen() const
{
    return m_Impl->files_seen;
}

uint64_t RustFileSearch::DirsSeen() const
{
    return m_Impl->dirs_seen;
}

uint64_t RustFileSearch::Matches() const
{
    return m_Impl->matches;
}

} // namespace nc::core
