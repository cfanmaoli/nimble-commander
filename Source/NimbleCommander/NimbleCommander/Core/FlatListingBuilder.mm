// Copyright (C) 2026 Michael Kazakov. Subject to GNU General Public License version 3.
#include "FlatListingBuilder.h"

#include <VFS/ColumnarListing.h>

#include <VFS/Native.h>
#include <VFS/VFSListing.h>
#include <VFS/VFSListingInput.h>
#include <Base/variable_container.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <limits>
#include <mutex>
#include <thread>
#include <unordered_map>
#include <string_view>
#include <vector>

namespace nc::core {

FlatListingResult BuildFlatListingComposed(const VFSHostPtr &_host,
                                           const std::string &_root,
                                           unsigned long _fetch_flags,
                                           const VFSCancelChecker &_cancel_checker,
                                           const size_t _max_items,
                                           const size_t _max_directories,
                                           const size_t _threads,
                                           const double _max_seconds,
                                           const std::vector<std::string> &_skip_prefixes)
{
    FlatListingResult result;
    const size_t max_directories = _max_directories;
    const size_t max_items = _max_items;

    const auto flat_begin = std::chrono::steady_clock::now();
    try {
        std::vector<VFSListingPtr> listings;
        std::vector<std::vector<unsigned>> indices;
        size_t total_items = 0;

        // The scan is level-synchronous: every directory of the current level is fetched in
        // parallel (that's where the time goes - 200k directories on a big tree, one syscall
        // stream each), and the entries are then folded in sequentially so that the budget
        // accounting and the resulting listing stay deterministic.
        std::vector<std::string> frontier;
        frontier.emplace_back(_root);
        size_t directories_seen = 1;

        // The flat view never shows "." or "..", so don't ask the host to fetch the dot-dot
        // entry - for a directory tree of a few hundred thousand directories that is one extra
        // per-entry attribute pass each.
        const unsigned long scan_flags = _fetch_flags | VFSFlags::F_NoDotDot;

        const size_t threads = std::max<size_t>(1, _threads);
        bool truncated = false;

        const auto started = std::chrono::steady_clock::now();
        const auto out_of_time = [&] {
            if( _max_seconds <= 0 )
                return false;
            return std::chrono::duration<double>(std::chrono::steady_clock::now() - started).count() > _max_seconds;
        };
        while( !frontier.empty() && !truncated ) {
            if( _cancel_checker && _cancel_checker() )
                return {}; // cancelled - the caller discards the result anyway
            if( out_of_time() ) {
                result.timed_out = true;
                break;
            }

            const auto fetch_begin = std::chrono::steady_clock::now();
            std::vector<VFSListingPtr> fetched(frontier.size());
            if( threads == 1 || frontier.size() == 1 ) {
                for( size_t i = 0; i != frontier.size(); ++i ) {
                    if( _cancel_checker && _cancel_checker() )
                        return {};
                    if( auto listing = _host->FetchDirectoryListing(frontier[i], scan_flags, _cancel_checker) )
                        fetched[i] = *listing;
                }
            }
            else {
                std::atomic<size_t> next{0};
                std::atomic<bool> cancelled{false};
                const auto worker = [&] {
                    for( size_t i = next.fetch_add(1); i < frontier.size(); i = next.fetch_add(1) ) {
                        if( cancelled.load(std::memory_order_relaxed) )
                            return;
                        if( _cancel_checker && _cancel_checker() ) {
                            cancelled.store(true, std::memory_order_relaxed);
                            return;
                        }
                        if( auto listing = _host->FetchDirectoryListing(frontier[i], scan_flags, _cancel_checker) )
                            fetched[i] = *listing;
                    }
                };
                std::vector<std::thread> pool;
                pool.reserve(std::min(threads, frontier.size()));
                for( size_t t = 0; t != std::min(threads, frontier.size()); ++t )
                    pool.emplace_back(worker);
                for( auto &t : pool )
                    t.join();
                if( cancelled.load(std::memory_order_relaxed) )
                    return {};
            }

            result.fetch_ms +=
                std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - fetch_begin)
                    .count();
            const auto fold_begin = std::chrono::steady_clock::now();
            std::vector<std::string> next_frontier;
            for( size_t i = 0; i != frontier.size(); ++i ) {
                const VFSListingPtr &listing = fetched[i];
                if( !listing )
                    continue;

                std::vector<unsigned> wanted;
                for( unsigned item_index = 0, items = listing->Count(); item_index != items; ++item_index ) {
                    const VFSListingItem item{listing, item_index};
                    const std::string &filename = item.Filename();
                    // '.' and '..' have no place in a flat view - the latter would also make the
                    // traversal walk towards the filesystem root endlessly.
                    if( filename == "." || filename == ".." )
                        continue;
                    wanted.emplace_back(item_index);
                    if( item.IsDir() && !item.IsSymlink() ) {
                        std::string subdir = item.Directory() + filename + "/";
                        bool skipped = false;
                        for( const std::string &prefix : _skip_prefixes )
                            if( subdir.starts_with(prefix) ) {
                                skipped = true;
                                break;
                            }
                        if( skipped )
                            ++result.skipped_cloud_directories;
                        else {
                            next_frontier.emplace_back(std::move(subdir));
                            ++directories_seen;
                        }
                    }
                }

                // An empty directory (or one with nothing but the dot entries) is perfectly
                // normal - skip it and keep walking. Stopping here would silently cut the
                // traversal short at the first empty subdirectory of the tree.
                if( wanted.empty() )
                    continue;

                // take as many entries as the budget allows - dropping the *whole* directory
                // just because it alone is bigger than the limit would leave the user with an
                // empty panel
                size_t take = wanted.size();
                if( total_items + take > max_items ) {
                    take = max_items > total_items ? max_items - total_items : 0;
                    truncated = true;
                }
                if( take == 0 )
                    break; // the budget is gone
                total_items += take;
                wanted.resize(take);
                listings.emplace_back(listing);
                indices.emplace_back(std::move(wanted));
            }

            result.fold_ms +=
                std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - fold_begin)
                    .count();
            if( listings.size() >= max_directories ) {
                truncated = true;
                break;
            }
            frontier = std::move(next_frontier);
        }

        result.scanned_items = total_items;
        result.scanned_directories = directories_seen;
        result.truncated = truncated;

        if( listings.empty() )
            return result; // nothing underneath - keep the regular directory listing
        const auto compose_begin = std::chrono::steady_clock::now();
        result.listing = vfs::Listing::Build(VFSListing::Compose(listings, indices));
        result.scan_ms = std::chrono::duration_cast<std::chrono::milliseconds>(compose_begin - flat_begin).count();
        result.compose_ms =
            std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - compose_begin)
                .count();
        return result;
    } catch( ... ) {
        return result;
    }
}

FlatListingResult BuildFlatListingColumnar(const VFSHostPtr &_host,
                                           const std::string &_root,
                                           const unsigned long _fetch_flags,
                                           const VFSCancelChecker &_cancel_checker,
                                           const size_t _max_items,
                                           const size_t _max_directories,
                                           const size_t _threads,
                                           const double _max_seconds,
                                           const std::vector<std::string> &_skip_prefixes)
{
    FlatListingResult result;
    if( _host == nullptr || _root.empty() || _root.front() != '/' )
        return result;

    // The columnar enumeration is native-only; everything else (archives, network hosts) has to
    // go through the composed path.
    if( dynamic_cast<vfs::NativeHost *>(_host.get()) == nullptr )
        return BuildFlatListingComposed(_host,
                                        _root,
                                        _fetch_flags,
                                        _cancel_checker,
                                        _max_items,
                                        _max_directories,
                                        _threads,
                                        _max_seconds,
                                        _skip_prefixes);

    const auto begin = std::chrono::steady_clock::now();
    const vfs::ColumnarListingResult enumerated = vfs::BuildColumnarListing(_host,
                                                                            _root,
                                                                            _fetch_flags,
                                                                            _cancel_checker,
                                                                            _max_items,
                                                                            _max_directories,
                                                                            _threads,
                                                                            _max_seconds,
                                                                            _skip_prefixes);
    result.scan_ms =
        std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - begin).count();
    result.scanned_items = enumerated.items;
    result.scanned_directories = enumerated.directories;
    result.truncated = enumerated.truncated;
    result.timed_out = enumerated.timed_out;
    result.skipped_cloud_directories = enumerated.skipped_directories;
    result.listing = enumerated.listing;
    return result;
}

} // namespace nc::core
