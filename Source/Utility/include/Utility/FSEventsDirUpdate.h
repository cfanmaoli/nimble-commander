// Copyright (C) 2013-2024 Michael Kazakov. Subject to GNU General Public License version 3.
#pragma once

#include <stdint.h>
#include <string>
#include <string_view>
#include <functional>
#include <span>

namespace nc::utility {

class NativeFSManagerImpl;

class FSEventsDirUpdate
{
public:
    virtual ~FSEventsDirUpdate() = default;

    // Registers _handler as a watch callback for any changes of the directory '_path' (but not its children)
    // Zero will be returned to indicate an error.
    // Any other values represent observation tickets.
    virtual uint64_t AddWatchPath(std::string_view _path, std::function<void()> _handler) = 0;

    // Same as AddWatchPath(), but the handler also receives the names of the entries that changed
    // directly inside the watched directory. An empty span means "something changed, but the exact
    // entries are unknown" - the client then has to do a full reload.
    using EventPathsHandler = std::function<void(std::span<const std::string>)>;
    virtual uint64_t AddWatchPath(std::string_view _path, EventPathsHandler _handler);

    // Deregisters the watcher identified by _ticket.
    virtual void RemoveWatchPathWithTicket(uint64_t _ticket) = 0;

    static FSEventsDirUpdate &Instance() noexcept;

    static inline const uint64_t no_ticket = 0;

private:
    friend class nc::utility::NativeFSManagerImpl;

    // called exclusively by NativeFSManager
    virtual void OnVolumeDidUnmount(const std::string &_on_path) = 0;
};

} // namespace nc::utility
