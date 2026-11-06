// Copyright (C) 2026 Michael Kazakov. Subject to GNU General Public License version 3.
#include "FlatListingBuilder.h"
#include "nc_core.h"

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
#include <thread>
#include <vector>

namespace nc::core {

FlatListingResult BuildFlatListingVFS(const VFSHostPtr &_host,
                                      const std::string &_root,
                                      unsigned long _fetch_flags,
                                      const VFSCancelChecker &_cancel_checker,
                                      const size_t _max_items,
                                      const size_t _max_directories,
                                      const size_t _threads)
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

        while( !frontier.empty() && !truncated ) {
            if( _cancel_checker && _cancel_checker() )
                return {}; // cancelled - the caller discards the result anyway

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
                        next_frontier.emplace_back(item.Directory() + filename + "/");
                        ++directories_seen;
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

// ---------------------------------------------------------------------------------------------
// The Rust implementation
// ---------------------------------------------------------------------------------------------

namespace {

extern "C" void OnFlatBatch(void *_ctx, const nc_flat_batch *_batch);

// The batch callback fires from the Rust workers; the entries go straight into one ListingInput
// (no intermediate listings at all). A single shared input under a mutex turned out to be
// faster than per-thread inputs plus a merge: the enumeration, not the ingestion, is the
// bottleneck, so the lock is never contended for long enough to matter.
struct RustFlatBuilder {
    VFSHostPtr host;
    size_t max_items = 0;
    size_t items = 0;
    size_t directories = 1; // the root itself
    bool truncated = false;
    std::mutex mutex;
    vfs::ListingInput input;
};

extern "C" {

void OnFlatBatch(void *_ctx, const nc_flat_batch *_batch)
{
    auto *const builder = static_cast<RustFlatBuilder *>(_ctx);
    std::string directory(_batch->dir_path, _batch->dir_path_len);
    if( directory.empty() || directory.back() != '/' )
        directory += '/';

    const std::lock_guard lock{builder->mutex};
    for( uint32_t i = 0; i != _batch->count; ++i ) {
        const std::string_view name{_batch->names[i], _batch->name_lengths[i]};
        if( name == "." || name == ".." )
            continue;
        if( builder->items >= builder->max_items ) {
            builder->truncated = true;
            return;
        }

        const unsigned index = static_cast<unsigned>(builder->input.filenames.size());
        builder->input.filenames.emplace_back(name);
        builder->input.unix_modes.emplace_back(static_cast<mode_t>(_batch->modes[i]));
        builder->input.unix_types.emplace_back(_batch->types[i]);
        builder->input.hosts.insert(index, builder->host);
        builder->input.directories.insert(index, directory);

        // Every entry carries a size, with UINT64_MAX meaning "unknown" - that is what the VFS
        // listings produced by the native host look like for directories, and it keeps the two
        // implementations byte-for-byte comparable.
        builder->input.sizes.insert(index, _batch->sizes[i]);
        if( _batch->inodes[i] != 0 )
            builder->input.inodes.insert(index, _batch->inodes[i]);
        builder->input.btimes.insert(index, static_cast<time_t>(_batch->btimes[i]));
        builder->input.mtimes.insert(index, static_cast<time_t>(_batch->mtimes[i]));
        builder->input.ctimes.insert(index, static_cast<time_t>(_batch->ctimes[i]));
        builder->input.atimes.insert(index, static_cast<time_t>(_batch->atimes[i]));
        if( _batch->add_times[i] >= 0 )
            builder->input.add_times.insert(index, static_cast<time_t>(_batch->add_times[i]));
        builder->input.uids.insert(index, static_cast<uid_t>(_batch->uids[i]));
        builder->input.gids.insert(index, static_cast<gid_t>(_batch->gids[i]));
        builder->input.unix_flags.insert(index, _batch->flags[i]);

        ++builder->items;
        if( _batch->types[i] == NC_DT_DIR )
            ++builder->directories;
    }
}

} // extern "C"

} // namespace

FlatListingResult BuildFlatListingRust(const VFSHostPtr &_host,
                                       const std::string &_root,
                                       const unsigned long _fetch_flags,
                                       const VFSCancelChecker &_cancel_checker,
                                       const size_t _max_items,
                                       const size_t _max_directories,
                                       const size_t _threads)
{
    FlatListingResult result;
    if( _host == nullptr || _root.empty() || _root.front() != '/' )
        return result;

    // The Rust core enumerates the native filesystem only; everything else (archives, network
    // hosts) keeps using the VFS implementation.
    if( dynamic_cast<vfs::NativeHost *>(_host.get()) == nullptr )
        return BuildFlatListingVFS(_host, _root, _fetch_flags, _cancel_checker, _max_items, _max_directories, _threads);

    const auto begin = std::chrono::steady_clock::now();

    RustFlatBuilder builder{.host = _host, .max_items = _max_items};
    builder.input.hosts.reset(base::variable_container<>::type::dense);
    builder.input.directories.reset(base::variable_container<>::type::dense);
    builder.input.sizes.reset(base::variable_container<>::type::sparse);
    builder.input.inodes.reset(base::variable_container<>::type::sparse);
    builder.input.atimes.reset(base::variable_container<>::type::sparse);
    builder.input.mtimes.reset(base::variable_container<>::type::sparse);
    builder.input.ctimes.reset(base::variable_container<>::type::sparse);
    builder.input.btimes.reset(base::variable_container<>::type::sparse);
    builder.input.add_times.reset(base::variable_container<>::type::sparse);
    builder.input.uids.reset(base::variable_container<>::type::sparse);
    builder.input.gids.reset(base::variable_container<>::type::sparse);
    builder.input.unix_flags.reset(base::variable_container<>::type::sparse);

    // nc_core_scan_flat only understands a plain flag, so the panel's cancel checker is polled
    // on a side thread while the scan runs.
    std::atomic<int32_t> cancel{0};
    std::atomic<bool> scanning{true};
    std::thread canceller;
    if( _cancel_checker ) {
        canceller = std::thread([&cancel, &scanning, &_cancel_checker] {
            while( scanning.load(std::memory_order_relaxed) ) {
                if( _cancel_checker() ) {
                    cancel.store(1, std::memory_order_relaxed);
                    return;
                }
                std::this_thread::sleep_for(std::chrono::milliseconds(25));
            }
        });
    }

    nc_flat_stats stats{};
    const int32_t rc = nc_core_scan_flat(_root.c_str(),
                                         static_cast<uint32_t>(std::max<size_t>(1, _threads)),
                                         &OnFlatBatch,
                                         &builder,
                                         reinterpret_cast<const volatile int32_t *>(&cancel),
                                         &stats);
    scanning.store(false, std::memory_order_relaxed);
    if( canceller.joinable() )
        canceller.join();

    result.scan_ms =
        std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - begin).count();

    if( rc != NC_CORE_OK )
        return result;

    result.scanned_items = builder.items;
    result.scanned_directories = builder.directories;
    result.truncated = builder.truncated;
    if( builder.input.filenames.empty() )
        return result;

    const auto compose_begin = std::chrono::steady_clock::now();
    try {
        result.listing = vfs::Listing::Build(std::move(builder.input));
    } catch( ... ) {
        return result;
    }
    result.compose_ms =
        std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - compose_begin).count();
    return result;
}
} // namespace nc::core
