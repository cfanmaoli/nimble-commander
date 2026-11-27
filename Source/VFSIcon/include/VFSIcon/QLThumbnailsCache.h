// Copyright (C) 2018 Michael Kazakov. Subject to GNU General Public License version 3.
#pragma once

#include <functional>
#include <optional>
#include <string>

@class NSImage;

namespace nc::vfsicon {

/**
 * All methods are thread-safe.
 */
class QLThumbnailsCache
{
public:
    virtual ~QLThumbnailsCache() = default;

    /**
     * Returns cached QLThunmbnail for specified filename without any checking if it is outdated.
     * Callers should use ProduceThumbnailAsync() if they need a fresh thumbnail.
     * May return nil.
     */
    virtual NSImage *ThumbnailIfHas(const std::string &_file_path, int _px_size) = 0;

    struct FileStateHint {
        uint64_t size = 0;
        uint64_t mtime = 0;
    };

    using ThumbnailCallback = std::function<void(NSImage *)>;
    /**
     * Returns a cached thumbnail only if its recorded file state matches _hint.
     * May return nil.
     */
    virtual NSImage *
    ThumbnailIfFresh(const std::string & /*_file_path*/, int /*_px_size*/, const FileStateHint & /*_hint*/)
    {
        return nullptr;
    }

    /**
     * Stores an externally produced thumbnail (for instance decoded directly via ImageIO) into
     * the cache under the given file state.
     */
    virtual void StoreThumbnail(const std::string & /*_file_path*/,
                                int /*_px_size*/,
                                const FileStateHint & /*_hint*/,
                                NSImage * /*_image*/)
    {
    }

    /** Starts an asynchronous thumbnail request; the callback is invoked on a background queue. */
    virtual void ProduceThumbnailAsync(const std::string &_file_path,
                                       int _px_size,
                                       const std::optional<FileStateHint> &_hint,
                                       ThumbnailCallback _callback) = 0;
};

} // namespace nc::vfsicon
