// Copyright (C) 2013-2024 Michael Kazakov. Subject to GNU General Public License version 3.
#include "FSEventsDirUpdateImpl.h"
#include <sys/param.h>
#include <vector>
#include <unordered_map>
#include <Utility/StringExtras.h>
#include <Utility/Log.h>
#include <Base/dispatch_cpp.h>
#include <Base/spinlock.h>
#include <Base/StackAllocator.h>
#include <fmt/ranges.h>
#include <span>

namespace nc::utility {

static const CFAbsoluteTime g_FSEventsLatency = 0.05; // 50ms

// ask FS about real file path - case sensitive etc
// also we're getting rid of symlinks - it will be a real file
// return path with trailing slash
static std::string GetRealPath(std::string_view _path_in)
{
    StackAllocator alloc;
    const std::pmr::string path_in(_path_in, &alloc);

    const int tfd = open(path_in.c_str(), O_RDONLY);
    if( tfd == -1 ) {
        Log::Warn("GetRealPath() failed to open '{}'", _path_in);
        return {};
    }
    char path_buf[MAXPATHLEN];
    const int ret = fcntl(tfd, F_GETPATH, path_buf);
    close(tfd);
    if( ret == -1 ) {
        Log::Warn("GetRealPath() failed to F_GETPATH of '{}', errno: {}", _path_in, errno);
        return {};
    }

    std::string path_out(path_buf);
    if( !path_out.empty() && path_out.back() != '/' )
        path_out += '/';

    return path_out;
}

bool FSEventsDirUpdateImpl::ShouldFire(const std::string_view _watched_path,
                                       const size_t _num_events,
                                       const char *_event_paths[],
                                       const FSEventStreamEventFlags _event_flags[]) noexcept
{
    assert(!_watched_path.empty() && _watched_path.back() == '/');

    for( size_t i = 0; i < _num_events; i++ ) {
        const auto flags = _event_flags[i];
        if( flags & kFSEventStreamEventFlagRootChanged ) {
            return true;
        }
        else {
            // this checking should be blazing fast, since we can get A LOT of events here
            // (from all sub-dirs) and we need only events from current-level directory
            const auto path = std::string_view{_event_paths[i]};
            if( path.empty() ) {
                continue;
            }

            // the input paths may or may not contain trailing slashes, that likely depends on an fs driver(?)
            if( path.back() == '/' ) {
                // regular comparison
                if( path == _watched_path )
                    return true;
            }
            else {
                // compare discarding the trailing slash of the watcher's path
                if( path == _watched_path.substr(0, _watched_path.length() - 1) )
                    return true;
            }
        }
    }
    return false;
}

void FSEventsDirUpdateImpl::FSEventsDirUpdateCallback([[maybe_unused]] ConstFSEventStreamRef _stream_ref,
                                                      void *_user_data,
                                                      size_t _num,
                                                      void *_paths,
                                                      const FSEventStreamEventFlags _flags[],
                                                      [[maybe_unused]] const FSEventStreamEventId _ids[])
{
    // WTF this data access is not locked????

    Log::Trace("FSEventsDirUpdate::Impl::FSEventsDirUpdateCallback for {} path(s): {}",
               _num,
               fmt::join(std::span<const char *>{reinterpret_cast<const char **>(_paths), _num}, ", "));

    const WatchData &watch = *static_cast<const WatchData *>(_user_data);
    const char **const paths = reinterpret_cast<const char **>(_paths);
    const bool dir_itself_changed = ShouldFire(watch.path, _num, paths, _flags);

    // Collect the names of the entries that changed directly inside the watched directory - the
    // clients can then patch their listings instead of reloading them from scratch.
    std::vector<std::string> changed_names;
    {
        const std::string_view watched = watch.path;
        assert(!watched.empty() && watched.back() == '/');
        const std::string_view watched_without_slash = watched.substr(0, watched.length() - 1);
        for( size_t i = 0; i < _num; ++i ) {
            std::string_view path = paths[i];
            if( path.empty() )
                continue;
            if( path.back() == '/' )
                path.remove_suffix(1);
            if( path == watched_without_slash )
                continue; // the directory itself, not one of its children
            const auto slash_pos = path.rfind('/');
            if( slash_pos == std::string_view::npos )
                continue;
            if( path.substr(0, slash_pos) != watched_without_slash )
                continue; // a change somewhere deeper in the hierarchy
            const std::string_view name = path.substr(slash_pos + 1);
            if( name.empty() || name == "." || name == ".." )
                continue;
            if( std::ranges::find(changed_names, name) == changed_names.end() )
                changed_names.emplace_back(name);
        }
    }

    if( !dir_itself_changed && changed_names.empty() )
        return;

    if( !watch.handlers.empty() ) {
        const auto handlers = watch.handlers; // the handlers may mutate the container
        for( auto &h : handlers )
            h.second();
    }
    if( !watch.path_handlers.empty() ) {
        const auto handlers = watch.path_handlers;
        for( auto &h : handlers )
            h.second(changed_names);
    }
}

FSEventStreamRef FSEventsDirUpdateImpl::CreateEventStream(const std::string &path, void *context_ptr)
{
    Log::Debug("CreateEventStream called for '{}'", path);
    auto cf_path = base::CFStringCreateWithUTF8StdString(path);
    if( !cf_path ) {
        Log::Warn("CreateEventStream failed to create a CFStringRef for '{}'", path);
        return nullptr;
    }

    CFArrayRef pathsToWatch = CFArrayCreate(nullptr, reinterpret_cast<const void **>(&cf_path), 1, nullptr);
    FSEventStreamRef stream = nullptr;
    const auto create_stream = [&] {
        // FileEvents is what gives us the names of the entries that changed - without it FSEvents
        // only reports directory-level events and every change would require a full reload.
        const auto flags =
            kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagFileEvents;
        auto context = FSEventStreamContext{
            .version = 0, .info = context_ptr, .retain = nullptr, .release = nullptr, .copyDescription = nullptr};
        stream = FSEventStreamCreate(nullptr,
                                     &FSEventsDirUpdateImpl::FSEventsDirUpdateCallback,
                                     &context,
                                     pathsToWatch,
                                     kFSEventStreamEventIdSinceNow,
                                     g_FSEventsLatency,
                                     flags);
        if( stream == nullptr ) {
            Log::Warn("FSEventStreamCreate failed to create a stream for '{}'", path);
        }
    };

    if( dispatch_is_main_queue() )
        create_stream();
    else
        dispatch_sync(dispatch_get_main_queue(), create_stream);

    CFRelease(pathsToWatch);
    CFRelease(cf_path);

    return stream;
}

static void StartStream(FSEventStreamRef _stream)
{
    assert(_stream != nullptr);

    const auto schedule_and_run = [=] {
        FSEventStreamScheduleWithRunLoop(_stream, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
        const bool started = FSEventStreamStart(_stream);
        if( !started ) {
            Log::Error("FSEventStreamStart failed to start");
        }
    };

    if( dispatch_is_main_queue() )
        schedule_and_run();
    else
        dispatch_to_main_queue(schedule_and_run);
}

// Stops and deletes the _stream
static void StopStream(FSEventStreamRef _stream)
{
    assert(_stream != nullptr);
    dispatch_assert_main_queue();
    FSEventStreamStop(_stream);
    FSEventStreamUnscheduleFromRunLoop(_stream, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);

    // FSEventStreamInvalidate can be blocking, so let's do that in a background thread
    dispatch_to_background([_stream] {
        FSEventStreamInvalidate(_stream);
        FSEventStreamRelease(_stream);
    });
}

uint64_t FSEventsDirUpdateImpl::AddWatchPathImpl(std::string_view _path,
                                                 const std::function<void(WatchData &, uint64_t)> &_attach)
{
    if( _path.empty() || !_attach )
        return no_ticket;

    Log::Debug("FSEventsDirUpdate::Impl::AddWatchPath called for '{}'", _path);

    // convert _path into canonical path of OS
    const auto dir_path = GetRealPath(_path);
    if( dir_path.empty() ) {
        Log::Debug("Failed to get a real path of '{}'", _path);
        return no_ticket;
    }

    // monotonically increase current ticket to get a next unique one
    const auto ticket = m_LastTicket++;

    const auto lock = std::lock_guard{m_Lock};

    // check if this path already presents in watched paths
    if( const auto it = m_Watches.find(dir_path); it != m_Watches.end() ) {
        Log::Trace("Using an already existing watcher for '{}'", _path);
        _attach(*it->second, ticket);
        return ticket;
    }

    // create a new watch stream
    Log::Trace("Creating a new watcher for '{}'", _path);
    const auto ep = m_Watches.emplace(dir_path, std::make_unique<WatchData>());
    assert(ep.second == true);
    WatchData &w = *ep.first->second;
    w.stream = CreateEventStream(dir_path, &w);
    if( w.stream == nullptr ) {
        // failed to creat the event stream, roll back the changes and return a failure indication
        m_Watches.erase(ep.first);
        return no_ticket;
    }
    w.path = ep.first->first;
    _attach(w, ticket);
    StartStream(w.stream);

    return ticket;
}

uint64_t FSEventsDirUpdateImpl::AddWatchPath(std::string_view _path, std::function<void()> _handler)
{
    if( !_handler )
        return no_ticket;
    return AddWatchPathImpl(_path, [handler = std::move(_handler)](WatchData &_w, uint64_t _ticket) {
        _w.handlers.emplace_back(_ticket, handler);
    });
}

uint64_t FSEventsDirUpdateImpl::AddWatchPath(std::string_view _path, EventPathsHandler _handler)
{
    if( !_handler )
        return no_ticket;
    return AddWatchPathImpl(_path, [handler = std::move(_handler)](WatchData &_w, uint64_t _ticket) {
        _w.path_handlers.emplace_back(_ticket, handler);
    });
}

// Erases an element at '_i' from containers '_c' by swapping it with the last element and then removing the last
// element. That's to cause less data movements
template <class Container, class Iterator>
static inline void unordered_erase(Container &_c, Iterator _i)
{
    // can do this since erase() requires a valid iterator => thus c is not empty.
    const auto last = std::prev(std::end(_c));

    if( last != _i )
        std::iter_swap(_i, last);

    _c.erase(last);
}

void FSEventsDirUpdateImpl::RemoveWatchPathWithTicket(uint64_t _ticket)
{
    if( _ticket == no_ticket )
        return;

    if( !dispatch_is_main_queue() ) {
        dispatch_to_main_queue([=, this] { RemoveWatchPathWithTicket(_ticket); });
        return;
    }

    const auto lock = std::lock_guard{m_Lock};

    for( auto i = m_Watches.begin(), e = m_Watches.end(); i != e; ++i ) {
        auto &watch = *i->second;
        for( auto h = watch.handlers.begin(), he = watch.handlers.end(); h != he; ++h )
            if( h->first == _ticket ) {
                unordered_erase(watch.handlers, h);
                if( watch.handlers.empty() ) {
                    StopStream(watch.stream);
                    m_Watches.erase(i);
                }
                return;
            }
    }
}

void FSEventsDirUpdateImpl::OnVolumeDidUnmount(const std::string &_on_path)
{
    // when a volume is removed from the system we force every relevant panel to reload its data
    dispatch_assert_main_queue();
    // locking??
    for( auto &i : m_Watches ) {
        if( i.second->path.starts_with(_on_path) ) {
            for( const auto &h : i.second->handlers )
                h.second();
        }
    }
}

} // namespace nc::utility
