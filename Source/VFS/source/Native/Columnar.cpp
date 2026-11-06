// Copyright (C) 2026 Michael Kazakov. Subject to GNU General Public License version 3.
#include <VFS/ColumnarListing.h>

#include "../Listing.h"
#include "../ListingInput.h"
#include "Fetching.h"
#include <RoutedIO/RoutedIO.h>

#include <algorithm>
#include <atomic>
#include <mutex>
#include <string_view>
#include <thread>
#include <tuple>
#include <vector>

#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

namespace nc::vfs {

namespace {

struct SharedState {
    ListingInput input;
    size_t items = 0;
    size_t directories = 1; // the root itself
    std::atomic<bool> truncated{false};
    std::mutex mutex; // guards input, items and directories
};

// Enumerates one directory and appends its entries to the shared input.
void AppendDirectory(SharedState &_state,
                     const std::string &_dir,
                     const unsigned long _fetch_flags,
                     const size_t _max_items,
                     std::vector<std::string> &_subdirs)
{
    std::string dir = _dir;
    if( dir.empty() || dir.back() != '/' )
        dir += '/';

    auto &io = routedio::RoutedIO::InterfaceForAccess(dir.c_str(), R_OK);
    const int fd = io.open(dir.c_str(), O_RDONLY | O_NONBLOCK | O_DIRECTORY | O_CLOEXEC);
    if( fd < 0 )
        return;

    const bool with_times = (_fetch_flags & VFSFlags::F_NoTimes) == 0;
    const bool with_sizes = (_fetch_flags & VFSFlags::F_NoSizes) == 0;

    std::vector<std::string> subdirs;
    const auto on_entry = [&](const native::Fetching::CallbackParams &_params) {
        const std::string_view name{_params.filename};
        if( name == "." || name == ".." )
            return;
        const bool is_dir = S_ISDIR(_params.mode);

        std::lock_guard lock{_state.mutex};
        if( _state.items >= _max_items ) {
            _state.truncated = true;
            return;
        }
        const unsigned index = static_cast<unsigned>(_state.input.filenames.size());
        _state.input.filenames.emplace_back(name);
        _state.input.unix_modes.emplace_back(_params.mode);
        // DT_* values, like readdir() would report them
        uint8_t dtype = DT_UNKNOWN;
        if( is_dir )
            dtype = DT_DIR;
        else if( S_ISLNK(_params.mode) )
            dtype = DT_LNK;
        else if( S_ISREG(_params.mode) )
            dtype = DT_REG;
        else if( S_ISFIFO(_params.mode) )
            dtype = DT_FIFO;
        else if( S_ISSOCK(_params.mode) )
            dtype = DT_SOCK;
        else if( S_ISCHR(_params.mode) )
            dtype = DT_CHR;
        else if( S_ISBLK(_params.mode) )
            dtype = DT_BLK;
        _state.input.unix_types.emplace_back(dtype);
        _state.input.directories.insert(index, dir);
        if( with_sizes )
            _state.input.sizes.insert(
                index, _params.size >= 0 ? static_cast<uint64_t>(_params.size) : std::numeric_limits<uint64_t>::max());
        if( with_times ) {
            _state.input.btimes.insert(index, _params.crt_time);
            _state.input.mtimes.insert(index, _params.mod_time);
            _state.input.ctimes.insert(index, _params.chg_time);
            _state.input.atimes.insert(index, _params.acc_time);
            if( _params.add_time >= 0 )
                _state.input.add_times.insert(index, _params.add_time);
        }
        if( _params.inode != 0 )
            _state.input.inodes.insert(index, _params.inode);
        _state.input.uids.insert(index, _params.uid);
        _state.input.gids.insert(index, _params.gid);
        _state.input.unix_flags.insert(index, _params.flags);
        ++_state.items;
        if( is_dir ) {
            ++_state.directories;
            subdirs.emplace_back(dir + std::string(name));
        }
    };

    std::ignore = native::Fetching::ReadDirAttributesBulk(fd, [](size_t) {}, on_entry, 0, with_times, with_sizes);
    ::close(fd);

    if( !subdirs.empty() )
        _subdirs.insert(_subdirs.end(), subdirs.begin(), subdirs.end());
}

} // namespace

ColumnarListingResult BuildColumnarListing(const VFSHostPtr &_host,
                                           const std::string &_root,
                                           const unsigned long _fetch_flags,
                                           const VFSCancelChecker &_cancel_checker,
                                           const size_t _max_items,
                                           const size_t _max_directories,
                                           const size_t _threads)
{
    ColumnarListingResult result;
    if( _host == nullptr || _root.empty() )
        return result;

    SharedState state;
    state.input.hosts.reset(base::variable_container<>::type::dense);
    state.input.directories.reset(base::variable_container<>::type::dense);
    state.input.sizes.reset(base::variable_container<>::type::sparse);
    state.input.inodes.reset(base::variable_container<>::type::sparse);
    state.input.atimes.reset(base::variable_container<>::type::sparse);
    state.input.mtimes.reset(base::variable_container<>::type::sparse);
    state.input.ctimes.reset(base::variable_container<>::type::sparse);
    state.input.btimes.reset(base::variable_container<>::type::sparse);
    state.input.add_times.reset(base::variable_container<>::type::sparse);
    state.input.uids.reset(base::variable_container<>::type::sparse);
    state.input.gids.reset(base::variable_container<>::type::sparse);
    state.input.unix_flags.reset(base::variable_container<>::type::sparse);

    const size_t workers = std::max<size_t>(1, std::min<size_t>(_threads, 32));
    std::vector<std::string> level{_root};

    while( !level.empty() && !state.truncated ) {
        if( _cancel_checker && _cancel_checker() )
            return {};
        std::mutex next_mutex;
        std::vector<std::string> next;
        std::atomic<size_t> index{0};
        const size_t thread_count = std::min(workers, level.size());

        const auto worker = [&] {
            for( size_t i = index.fetch_add(1); i < level.size(); i = index.fetch_add(1) ) {
                if( _cancel_checker && _cancel_checker() )
                    return;
                std::vector<std::string> subdirs;
                AppendDirectory(state, level[i], _fetch_flags, _max_items, subdirs);
                if( state.truncated )
                    return;
                if( !subdirs.empty() ) {
                    std::lock_guard lock{next_mutex};
                    for( auto &s : subdirs )
                        next.emplace_back(std::move(s));
                }
            }
        };

        if( thread_count <= 1 ) {
            worker();
        }
        else {
            std::vector<std::thread> pool;
            pool.reserve(thread_count);
            for( size_t t = 0; t != thread_count; ++t )
                pool.emplace_back(worker);
            for( auto &t : pool )
                t.join();
        }
        if( state.truncated || next.size() > _max_directories ) {
            state.truncated = true;
            break;
        }
        level = std::move(next);
    }

    result.items = state.items;
    result.directories = state.directories;
    result.truncated = state.truncated;
    if( state.input.filenames.empty() )
        return result;

    try {
        for( unsigned i = 0; i != state.input.filenames.size(); ++i )
            state.input.hosts.insert(i, _host);
        result.listing = Listing::Build(std::move(state.input));
    } catch( ... ) {
        return result;
    }
    return result;
}

} // namespace nc::vfs
