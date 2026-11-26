// Copyright (C) 2014-2018 Michael Kazakov. Subject to GNU General Public License version 3.
#pragma once

#include <VFS/VFS.h>
#include <functional>

namespace nc::vfsicon {

class QLVFSThumbnailsCache
{
public:
    virtual ~QLVFSThumbnailsCache() = default;

    virtual NSImage *ThumbnailIfHas(const std::string &_file_path, VFSHost &_host, int _px_size) = 0;

    using ThumbnailCallback = std::function<void(NSImage *)>;
    /** Starts an asynchronous thumbnail request; the callback is invoked on a background queue. */
    virtual void
    ProduceThumbnailAsync(const std::string &_file_path, VFSHost &_host, int _px_size, ThumbnailCallback _callback) = 0;
};

} // namespace nc::vfsicon
