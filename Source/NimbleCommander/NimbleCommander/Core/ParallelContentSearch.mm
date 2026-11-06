// Copyright (C) 2026 Michael Kazakov. Subject to GNU General Public License version 3.
#include "ParallelContentSearch.h"

#include <algorithm>
#include <atomic>
#include <cstring>
#include <mutex>
#include <thread>
#include <vector>

#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

namespace nc::core {

struct ParallelContentSearch::Impl {
    std::thread worker;
    std::atomic<int32_t> cancel{0};
    std::atomic<bool> running{false};
    std::atomic<uint64_t> files_scanned{0};
    std::atomic<uint64_t> files_skipped{0};
    std::atomic<uint64_t> matches{0};
};

namespace {

inline unsigned char Fold(const unsigned char _c)
{
    return _c >= 'A' && _c <= 'Z' ? static_cast<unsigned char>(_c + ('a' - 'A')) : _c;
}

inline bool IsWordByte(const unsigned char _c)
{
    return (_c >= '0' && _c <= '9') || (_c >= 'a' && _c <= 'z') || (_c >= 'A' && _c <= 'Z') || _c == '_';
}

// Finds the first occurrence of _needle in _hay. Returns the byte offset or npos.
size_t FindBytes(const char *_hay, size_t _hay_len, const char *_needle, size_t _needle_len, bool _ci, bool _whole)
{
    if( _needle_len == 0 || _hay_len < _needle_len )
        return std::string_view::npos;
    const size_t last = _hay_len - _needle_len;
    for( size_t i = 0; i <= last; ++i ) {
        if( _ci ) {
            // the first byte has to be folded as well, so memchr can't be used directly
            while( i <= last &&
                   Fold(static_cast<unsigned char>(_hay[i])) != Fold(static_cast<unsigned char>(_needle[0])) )
                ++i;
            if( i > last )
                return std::string_view::npos;
        }
        else {
            // memchr is the fastest way to skip to a candidate first byte
            const void *const found = std::memchr(_hay + i, _needle[0], last - i + 1);
            if( found == nullptr )
                return std::string_view::npos;
            i = static_cast<size_t>(static_cast<const char *>(found) - _hay);
        }
        if( _ci ) {
            if( i + _needle_len > _hay_len )
                return std::string_view::npos;
            bool equal = true;
            for( size_t k = 0; k != _needle_len; ++k ) {
                if( Fold(static_cast<unsigned char>(_hay[i + k])) != Fold(static_cast<unsigned char>(_needle[k])) ) {
                    equal = false;
                    break;
                }
            }
            if( !equal )
                continue;
        }
        else if( std::memcmp(_hay + i, _needle, _needle_len) != 0 ) {
            continue;
        }
        if( _whole ) {
            const bool before_ok = i == 0 || !IsWordByte(static_cast<unsigned char>(_hay[i - 1]));
            const bool after_ok =
                i + _needle_len == _hay_len || !IsWordByte(static_cast<unsigned char>(_hay[i + _needle_len]));
            if( !before_ok || !after_ok )
                continue;
        }
        return i;
    }
    return std::string_view::npos;
}

struct SearchContext {
    ParallelContentSearch::Impl *impl = nullptr;
    std::string root;
    std::string text;
    bool case_sensitive = false;
    bool whole_phrase = false;
    uint64_t max_file_size = 0;
    bool go_into_subdirs = true;
    ParallelContentSearch::FoundCallback found;
    std::function<void()> finish;
    ParallelContentSearch::LookInCallback looking_in;
    std::mutex look_in_mutex;
    std::mutex mutex; // the callbacks must stay serial
};

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

void ReportFound(SearchContext &_ctx, std::string_view _relative, uint64_t _offset, uint64_t _len)
{
    std::lock_guard lock{_ctx.mutex};
    if( !_ctx.found )
        return;
    ParallelContentSearch::Hit hit;
    std::string relative_dir;
    SplitRelativePath(_relative, hit.name, relative_dir);
    hit.dir_path = _ctx.root;
    if( hit.dir_path.empty() || hit.dir_path.back() != '/' )
        hit.dir_path += '/';
    hit.dir_path += relative_dir;
    hit.offset = _offset;
    hit.bytes_len = _len;
    _ctx.found(hit);
}

// Searches one file; returns true when it was scanned (even without a match).
bool SearchFile(SearchContext &_ctx, const std::string &_path, std::string_view _relative)
{
    struct stat st{};
    if( ::stat(_path.c_str(), &st) != 0 || !S_ISREG(st.st_mode) )
        return false;
    if( _ctx.max_file_size != 0 && static_cast<uint64_t>(st.st_size) > _ctx.max_file_size ) {
        _ctx.impl->files_skipped.fetch_add(1, std::memory_order_relaxed);
        return false;
    }
    const int fd = ::open(_path.c_str(), O_RDONLY | O_CLOEXEC);
    if( fd < 0 )
        return false;
    std::string content;
    content.resize(static_cast<size_t>(st.st_size));
    size_t total = 0;
    while( total < content.size() ) {
        const ssize_t r = ::read(fd, content.data() + total, content.size() - total);
        if( r <= 0 )
            break;
        total += static_cast<size_t>(r);
    }
    ::close(fd);
    content.resize(total);

    _ctx.impl->files_scanned.fetch_add(1, std::memory_order_relaxed);
    const size_t offset = FindBytes(
        content.data(), content.size(), _ctx.text.data(), _ctx.text.size(), !_ctx.case_sensitive, _ctx.whole_phrase);
    if( offset != std::string_view::npos ) {
        _ctx.impl->matches.fetch_add(1, std::memory_order_relaxed);
        ReportFound(_ctx, _relative, offset, _ctx.text.size());
        return true;
    }
    return true;
}

void RunSearch(SearchContext &_ctx)
{
    const size_t threads = std::min<size_t>(std::max(1u, std::thread::hardware_concurrency()), 16);
    std::mutex queue_mutex;
    std::vector<std::string> queue{_ctx.root};
    std::atomic<size_t> working{0};
    auto cancelled = [&] { return _ctx.impl->cancel.load(std::memory_order_relaxed) != 0; };

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
                    continue; // another worker is still producing subdirectories
                }
                dir = std::move(queue.back());
                queue.pop_back();
            }
            working.fetch_add(1, std::memory_order_seq_cst);
            if( _ctx.looking_in ) {
                std::lock_guard lock{_ctx.look_in_mutex};
                _ctx.looking_in(dir);
            }

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
                        if( _ctx.go_into_subdirs )
                            subdirs.emplace_back(path);
                        continue;
                    }
                    const std::string_view rel = std::string_view{path}.substr(_ctx.root.size());
                    SearchFile(_ctx, path, rel);
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

ParallelContentSearch::ParallelContentSearch() : m_Impl(std::make_unique<Impl>())
{
}

ParallelContentSearch::~ParallelContentSearch()
{
    Stop();
    Wait();
}

bool ParallelContentSearch::Go(const std::string &_root,
                               const Filter &_filter,
                               FoundCallback _found,
                               std::function<void()> _finish,
                               LookInCallback _looking_in)
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
                                        .go_into_subdirs = _filter.go_into_subdirs,
                                        .found = std::move(_found),
                                        .finish = std::move(_finish),
                                        .looking_in = std::move(_looking_in)};

    m_Impl->running = true;
    m_Impl->worker = std::thread([ctx] {
        RunSearch(*ctx);
        ParallelContentSearch::Impl *const impl = ctx->impl;
        impl->running = false;
        auto finish = std::move(ctx->finish);
        delete ctx;
        if( finish )
            finish();
    });
    return true;
}

void ParallelContentSearch::Stop()
{
    m_Impl->cancel = 1;
}

void ParallelContentSearch::Wait()
{
    if( m_Impl->worker.joinable() )
        m_Impl->worker.join();
}

bool ParallelContentSearch::IsRunning() const
{
    return m_Impl->running;
}

uint64_t ParallelContentSearch::FilesScanned() const
{
    return m_Impl->files_scanned;
}

uint64_t ParallelContentSearch::FilesSkipped() const
{
    return m_Impl->files_skipped;
}

uint64_t ParallelContentSearch::Matches() const
{
    return m_Impl->matches;
}

} // namespace nc::core
