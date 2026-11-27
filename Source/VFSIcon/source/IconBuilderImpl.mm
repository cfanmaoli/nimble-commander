// Copyright (C) 2018-2022 Michael Kazakov. Subject to GNU General Public License version 3.
#include <VFSIcon/IconBuilderImpl.h>
#include <algorithm>
#include <ImageIO/ImageIO.h>
#include <cctype>
#include <string_view>
#include <VFSIcon/Log.h>
#include <Utility/ObjCpp.h>

namespace nc::vfsicon {

static bool IsDirectImageExtension(std::string_view _extension);
static NSImage *ProduceImageThumbnailDirectly(const std::string &_path, int _px_size);

IconBuilderImpl::IconBuilderImpl(const std::shared_ptr<QLThumbnailsCache> &_ql_cache,
                                 const std::shared_ptr<WorkspaceIconsCache> &_workspace_icons_cache,
                                 const std::shared_ptr<WorkspaceExtensionIconsCache> &_extension_icons_cache,
                                 const std::shared_ptr<QLVFSThumbnailsCache> &_vfs_thumbnails_cache,
                                 const std::shared_ptr<VFSBundleIconsCache> &_vfs_bundle_icons_cache,
                                 const std::shared_ptr<ExtensionsWhitelist> &_extensions_whitelist,
                                 long _max_filesize_for_thumbnails_on_native_fs,
                                 long _max_filesize_for_thumbnails_on_vfs)
    : m_QLThumbnailsCache(_ql_cache), m_WorkspaceIconsCache(_workspace_icons_cache),
      m_ExtensionIconsCache(_extension_icons_cache), m_VFSThumbnailsCache(_vfs_thumbnails_cache),
      m_VFSBundleIconsCache(_vfs_bundle_icons_cache), m_ExtensionsWhitelist(_extensions_whitelist),
      m_MaxFilesizeForThumbnailsOnNativeFS(_max_filesize_for_thumbnails_on_native_fs),
      m_MaxFilesizeForThumbnailsOnVFS(_max_filesize_for_thumbnails_on_vfs)
{
}

IconBuilderImpl::~IconBuilderImpl() = default;

IconBuilder::LookupResult IconBuilderImpl::LookupExistingIcon(const VFSListingItem &_item, int _icon_px_size)
{
    if( !_item || _icon_px_size <= 0 ) {
        Log::Warn("LookupExistingIcon(): invalid lookup request");
        return {};
    }

    Log::Trace("LookupExistingIcon(): looking up at '{}' for '{}', vfs: '{}'",
               _item.Directory(),
               _item.Filename(),
               _item.Host()->JunctionPath());

    LookupResult result;

    if( _item.Host()->IsNativeFS() ) {
        const auto path = _item.Path();

        result.thumbnail = m_QLThumbnailsCache->ThumbnailIfHas(path, _icon_px_size);
        if( result.thumbnail ) {
            Log::Debug("got a thumbnail for '{}'", path);
            return result;
        }

        result.filetype = m_WorkspaceIconsCache->IconIfHas(path);
        if( result.filetype ) {
            Log::Debug("got a workspace icon for '{}'", path);
            return result;
        }
    }
    else {
        if( _item.Host()->ShouldProduceThumbnails() ) {
            if( ShouldTryProducingBundleIconOnVFS(_item) ) {
                result.thumbnail = m_VFSBundleIconsCache->IconIfHas(_item.Path(), *_item.Host());
                if( result.thumbnail )
                    return result;
            }
            if( ShouldTryProducingQLThumbnailOnNativeFS(_item) ) {
                result.thumbnail = m_VFSThumbnailsCache->ThumbnailIfHas(_item.Path(), *_item.Host(), _icon_px_size);
                if( result.thumbnail )
                    return result;
            }
        }
    }

    if( _item.HasExtension() ) {
        result.filetype = m_ExtensionIconsCache->IconForExtension(_item.Extension());
        if( result.filetype ) {
            Log::Debug("got a filetype icon for '{}'", _item.Filename());
            return result;
        }
    }

    Log::Debug("have only a generic icon for '{}'", _item.Filename());
    result.generic = GetGenericIcon(_item);
    return result;
}

void IconBuilderImpl::BuildRealIconAsync(const VFSListingItem &_item,
                                         int _icon_px_size,
                                         BuildCallback _callback,
                                         const CancelChecker &_cancel_checker)
{
    if( !_callback )
        return;
    if( !_item || _icon_px_size <= 0 ) {
        _callback({});
        return;
    }
    if( _cancel_checker && _cancel_checker() ) {
        _callback({});
        return;
    }

    const auto path = _item.Path();
    if( _item.Host()->IsNativeFS() ) {
        if( !ShouldTryProducingQLThumbnailOnNativeFS(_item) ) {
            BuildResult result;
            result.filetype = m_WorkspaceIconsCache->ProduceIcon(path);
            _callback(result);
            return;
        }

        auto hint = QLThumbnailsCache::FileStateHint{};
        hint.size = _item.Size();
        hint.mtime = _item.MTime();
        if( _item.Size() <= 64ull * 1024 * 1024 && IsDirectImageExtension(_item.Extension()) ) {
            if( NSImage *const image = ProduceImageThumbnailDirectly(path, _icon_px_size) ) {
                BuildResult result;
                result.thumbnail = image;
                _callback(result);
                return;
            }
        }

        m_QLThumbnailsCache->ProduceThumbnailAsync(
            path, _icon_px_size, hint, [this, path, _callback, _cancel_checker](NSImage *thumbnail) {
                if( _cancel_checker && _cancel_checker() ) {
                    _callback({});
                    return;
                }
                if( thumbnail != nil ) {
                    BuildResult result;
                    result.thumbnail = thumbnail;
                    _callback(result);
                    return;
                }
                BuildResult result;
                result.filetype = m_WorkspaceIconsCache->ProduceIcon(path);
                _callback(result);
            });
        return;
    }

    if( !_item.Host()->ShouldProduceThumbnails() ) {
        _callback({});
        return;
    }

    BuildResult result;
    if( ShouldTryProducingBundleIconOnVFS(_item) )
        result.thumbnail = m_VFSBundleIconsCache->ProduceIcon(path, *_item.Host());
    if( result.thumbnail != nil ) {
        _callback(result);
        return;
    }
    if( _cancel_checker && _cancel_checker() ) {
        _callback({});
        return;
    }

    if( !ShouldTryProducingQLThumbnailOnVFS(_item) ) {
        _callback({});
        return;
    }

    m_VFSThumbnailsCache->ProduceThumbnailAsync(
        path, *_item.Host(), _icon_px_size, [item = _item, _callback, _cancel_checker](NSImage *thumbnail) {
            if( _cancel_checker && _cancel_checker() ) {
                _callback({});
                return;
            }
            BuildResult result;
            result.thumbnail = thumbnail;
            _callback(result);
        });
}

static bool IsDirectImageExtension(std::string_view _extension)
{
    static constexpr std::string_view extensions[] = {
        "jpg", "jpeg", "png", "gif", "heic", "heif", "tif", "tiff", "bmp", "webp", "raw",
        "cr2", "nef",  "dng", "arw", "orf",  "raf",  "rw2", "pef",  "srw", "ico",
    };
    if( _extension.size() > 5 )
        return false;

    char lower[6] = {};
    for( size_t i = 0; i != _extension.size(); ++i )
        lower[i] = static_cast<char>(std::tolower(static_cast<unsigned char>(_extension[i])));

    for( const auto extension : extensions )
        if( std::string_view{lower, _extension.size()} == extension )
            return true;
    return false;
}

static NSImage *ProduceImageThumbnailDirectly(const std::string &_path, int _px_size)
{
    NSString *const path = [NSString stringWithUTF8String:_path.c_str()];
    if( path == nil )
        return nil;
    NSURL *const url = [NSURL fileURLWithPath:path];
    const CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, nullptr);
    if( source == nullptr )
        return nil;

    NSDictionary *const options = @{
        (__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform: @YES,
        (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize: @(_px_size),
        (__bridge NSString *)kCGImageSourceShouldCacheImmediately: @YES,
    };
    const CGImageRef thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
    CFRelease(source);
    if( thumbnail == nullptr )
        return nil;

    const CGFloat source_width = static_cast<CGFloat>(CGImageGetWidth(thumbnail));
    const CGFloat source_height = static_cast<CGFloat>(CGImageGetHeight(thumbnail));
    const CGFloat scale = _px_size / std::max(source_width, source_height);
    NSImage *const image = [[NSImage alloc] initWithCGImage:thumbnail
                                                       size:NSMakeSize(source_width * scale, source_height * scale)];
    CGImageRelease(thumbnail);
    return image;
}

NSImage *IconBuilderImpl::GetGenericIcon(const VFSListingItem &_item) const
{
    return _item.IsDir() ? m_ExtensionIconsCache->GenericFolderIcon() : m_ExtensionIconsCache->GenericFileIcon();
}

bool IconBuilderImpl::ShouldTryProducingQLThumbnailOnNativeFS(const VFSListingItem &_item) const
{
    return !_item.IsDir() && _item.Size() > 0 && long(_item.Size()) < m_MaxFilesizeForThumbnailsOnNativeFS &&
           _item.HasExtension() && m_ExtensionsWhitelist->AllowExtension(_item.Extension());
}

bool IconBuilderImpl::ShouldTryProducingQLThumbnailOnVFS(const VFSListingItem &_item) const
{
    return !_item.IsDir() && _item.Size() > 0 && long(_item.Size()) < m_MaxFilesizeForThumbnailsOnVFS &&
           _item.HasExtension() && m_ExtensionsWhitelist->AllowExtension(_item.Extension());
}

static bool MightBeBundle(const VFSListingItem &_item)
{
    if( !_item.HasExtension() )
        return false;

    const auto extension = _item.Extension();
    using namespace std::string_view_literals;
    return "app"sv == extension;
}

bool IconBuilderImpl::ShouldTryProducingBundleIconOnVFS(const VFSListingItem &_item)
{
    return MightBeBundle(_item);
}

} // namespace nc::vfsicon
