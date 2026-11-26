// Copyright (C) 2018-2025 Michael Kazakov. Subject to GNU General Public License version 3.
#include <VFSIcon/QLVFSThumbnailsCacheImpl.h>
#include <QuickLookThumbnailing/QuickLookThumbnailing.h>
#include <VFSIcon/Log.h>
#include <atomic>
#include <filesystem>
#include <memory>

namespace nc::vfsicon {

static void GenerateVFSQuickLookThumbnailAsync(NSURL *_url, CGSize _size, void (^_callback)(NSImage *))
{
    QLThumbnailGenerationRequest *const request = [[QLThumbnailGenerationRequest alloc]
          initWithFileAtURL:_url
                       size:_size
                      scale:1.0
        representationTypes:QLThumbnailGenerationRequestRepresentationTypeThumbnail];
    request.iconMode = YES;
    const auto completed = std::make_shared<std::atomic_bool>(false);
    [[QLThumbnailGenerator sharedGenerator]
        generateBestRepresentationForRequest:request
                           completionHandler:^(QLThumbnailRepresentation *_Nullable representation,
                                               NSError *_Nullable error) {
                             NSImage *image = nil;
                             if( representation != nil )
                                 image = [[NSImage alloc] initWithCGImage:representation.CGImage size:_size];
                             if( error != nil )
                                 Log::Warn("QuickLook thumbnail generation failed: {}",
                                           error.localizedDescription.UTF8String);
                             if( !completed->exchange(true) )
                                 _callback(image);
                           }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      if( !completed->exchange(true) ) {
          [[QLThumbnailGenerator sharedGenerator] cancelRequest:request];
          _callback(nil);
      }
    });
}

QLVFSThumbnailsCacheImpl::QLVFSThumbnailsCacheImpl(const std::shared_ptr<utility::BriefOnDiskStorage> &_temp_storage)
    : m_TempStorage(_temp_storage)
{
}

QLVFSThumbnailsCacheImpl::~QLVFSThumbnailsCacheImpl() = default;

NSImage *QLVFSThumbnailsCacheImpl::ThumbnailIfHas(const std::string &_file_path, VFSHost &_host, int _px_size)
{
    const auto key = MakeKey(_file_path, _host, _px_size);

    {
        const auto lock = std::lock_guard{m_Lock};
        if( m_Thumbnails.count(key) )
            return m_Thumbnails.at(key);
    }

    return nil;
}

std::string QLVFSThumbnailsCacheImpl::MakeKey(const std::string &_file_path, VFSHost &_host, int _px_size)
{
    auto key = _host.MakePathVerbose(_file_path);
    key += '\001';
    key += std::to_string(_px_size);
    return key;
}

std::expected<std::vector<uint8_t>, Error> QLVFSThumbnailsCacheImpl::ReadEntireFile(const std::string &_path,
                                                                                    VFSHost &_host)
{
    const std::expected<std::shared_ptr<VFSFile>, Error> file = _host.CreateFile(_path);
    if( !file )
        return std::unexpected(file.error());

    if( const std::expected<void, Error> rc = (*file)->Open(VFSFlags::OF_Read) ) {
        return (*file)->ReadFile();
    }
    else {
        return std::unexpected(rc.error());
    }
}

void QLVFSThumbnailsCacheImpl::ProduceThumbnailAsync(const std::string &_file_path,
                                                     VFSHost &_host,
                                                     int _px_size,
                                                     ThumbnailCallback _callback)
{
    if( !_callback )
        return;

    const std::string key = MakeKey(_file_path, _host, _px_size);
    NSImage *cached = nil;
    {
        const auto lock = std::lock_guard{m_Lock};
        if( m_Thumbnails.count(key) )
            cached = m_Thumbnails.at(key);
    }
    if( cached != nil ) {
        _callback(cached);
        return;
    }

    const std::string extension = std::filesystem::path(_file_path).extension();
    auto data = ReadEntireFile(_file_path, _host);
    if( !data.has_value() ) {
        _callback(nil);
        return;
    }

    auto placement = m_TempStorage->PlaceWithExtension(data->data(), data->size(), extension);
    if( !placement.has_value() ) {
        _callback(nil);
        return;
    }

    // QLThumbnailGenerator reads the URL asynchronously. PlacementResult deletes the temporary
    // file in its destructor, so the completion block must keep it alive until QL is done.
    auto placement_result = std::make_shared<nc::utility::BriefOnDiskStorage::PlacementResult>(std::move(*placement));

    NSURL *const url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:placement_result->Path().c_str()]];
    if( url == nil ) {
        _callback(nil);
        return;
    }

    GenerateVFSQuickLookThumbnailAsync(url, CGSizeMake(double(_px_size), double(_px_size)), ^(NSImage *image) {
      // Keep the temporary file alive until QL has finished reading it.
      (void)placement_result;
      if( image != nil ) {
          const auto lock = std::lock_guard{m_Lock};
          m_Thumbnails.insert(key, image);
      }
      _callback(image);
    });
}

} // namespace nc::vfsicon
