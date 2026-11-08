// Copyright (C) 2013-2024 Michael Kazakov. Subject to GNU General Public License version 3.
#include "FSEventsDirUpdateImpl.h"

namespace nc::utility {

uint64_t FSEventsDirUpdate::AddWatchPath(std::string_view _path, EventPathsHandler _handler)
{
    if( !_handler )
        return no_ticket;
    // By default we can't tell which entries have changed - let the client do a full reload.
    return AddWatchPath(_path, [handler = std::move(_handler)] { handler({}); });
}

FSEventsDirUpdate &FSEventsDirUpdate::Instance() noexcept
{
    [[clang::no_destroy]] static FSEventsDirUpdateImpl inst;
    return inst;
}

} // namespace nc::utility
