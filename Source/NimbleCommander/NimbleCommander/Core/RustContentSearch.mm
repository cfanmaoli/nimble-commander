// Copyright (C) 2026 Michael Kazakov. Subject to GNU General Public License version 3.
#include "RustContentSearch.h"
#include "nc_core.h"

#include <atomic>
#include <mutex>
#include <thread>

namespace nc::core {

struct RustContentSearch::Impl {
    std::thread worker;
    std::atomic<int32_t> cancel{0};
    std::atomic<bool> running{false};
    std::atomic<uint64_t> files_scanned{0};
    std::atomic<uint64_t> files_skipped{0};
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

struct SearchContext {
    RustContentSearch::Impl *impl = nullptr;
    std::string root;
    std::string text;
    bool case_sensitive = false;
    bool whole_phrase = false;
    uint64_t max_file_size = 0;
    RustContentSearch::FoundCallback found;
    std::function<void()> finish;
    nc_content_params params{};
    std::mutex mutex; // serialises the callbacks - the Rust side has many workers
};

void OnFound(void *_ctx, const char *_rel, const uint64_t _offset, const uint64_t _bytes_len)
{
    auto *const ctx = static_cast<SearchContext *>(_ctx);
    const std::lock_guard lock{ctx->mutex};
    if( !ctx->found )
        return;
    RustContentSearch::Hit hit;
    std::string relative_dir;
    SplitRelativePath(_rel, hit.name, relative_dir);
    hit.dir_path = ctx->root;
    if( hit.dir_path.empty() || hit.dir_path.back() != '/' )
        hit.dir_path += '/';
    hit.dir_path += relative_dir;
    hit.offset = _offset;
    hit.bytes_len = _bytes_len;
    ctx->found(hit);
}

} // namespace

RustContentSearch::RustContentSearch() : m_Impl(std::make_unique<Impl>())
{
}

RustContentSearch::~RustContentSearch()
{
    Stop();
    Wait();
}

bool RustContentSearch::Go(const std::string &_root,
                           const Filter &_filter,
                           FoundCallback _found,
                           std::function<void()> _finish)
{
    if( IsRunning() )
        return false;
    if( _root.empty() || _root.front() != '/' )
        return false;
    if( _filter.text.empty() )
        return false;

    m_Impl->cancel = 0;
    m_Impl->files_scanned = 0;
    m_Impl->files_skipped = 0;
    m_Impl->matches = 0;

    auto *const ctx = new SearchContext{.impl = m_Impl.get(),
                                        .root = _root,
                                        .text = _filter.text,
                                        .case_sensitive = _filter.case_sensitive,
                                        .whole_phrase = _filter.whole_phrase,
                                        .max_file_size = _filter.max_file_size,
                                        .found = std::move(_found),
                                        .finish = std::move(_finish)};

    ctx->params.root = ctx->root.c_str();
    ctx->params.needle = ctx->text.data();
    ctx->params.needle_len = static_cast<uint32_t>(ctx->text.size());
    ctx->params.options =
        (ctx->case_sensitive ? 0u : NC_CONTENT_CASE_INSENSITIVE) | (ctx->whole_phrase ? NC_CONTENT_WHOLE_PHRASE : 0u);
    ctx->params.threads = 0;
    ctx->params.max_file_size = ctx->max_file_size;

    m_Impl->running = true;
    m_Impl->worker = std::thread([ctx] {
        nc_content_stats stats{};
        const int32_t rc = nc_core_search_content(
            &ctx->params, &OnFound, ctx, reinterpret_cast<const volatile int32_t *>(&ctx->impl->cancel), &stats);
        (void)rc;
        RustContentSearch::Impl *const impl = ctx->impl;
        impl->files_scanned = stats.files_scanned;
        impl->files_skipped = stats.files_skipped;
        impl->matches = stats.matches;
        impl->running = false;
        auto finish = std::move(ctx->finish);
        delete ctx;
        if( finish )
            finish();
    });

    return true;
}

void RustContentSearch::Stop()
{
    m_Impl->cancel = 1;
}

void RustContentSearch::Wait()
{
    if( m_Impl->worker.joinable() )
        m_Impl->worker.join();
}

bool RustContentSearch::IsRunning() const
{
    return m_Impl->running;
}

uint64_t RustContentSearch::FilesScanned() const
{
    return m_Impl->files_scanned;
}

uint64_t RustContentSearch::FilesSkipped() const
{
    return m_Impl->files_skipped;
}

uint64_t RustContentSearch::Matches() const
{
    return m_Impl->matches;
}

} // namespace nc::core
