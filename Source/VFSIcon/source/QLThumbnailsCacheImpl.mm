// Copyright (C) 2014-2025 Michael Kazakov. Subject to GNU General Public License version 3.
#include <VFSIcon/QLThumbnailsCacheImpl.h>
#include <VFSIcon/Log.h>
#include <QuickLookThumbnailing/QuickLookThumbnailing.h>
#include <sys/stat.h>
#include <Base/algo.h>

namespace nc::vfsicon {

static void hash_combine(size_t & /*unused*/)
{
}

template <typename T, typename... Rest>
static void hash_combine(size_t &seed, const T &v, Rest... rest)
{
    const std::hash<T> hasher;
    seed ^= hasher(v) + 0x9e3779b9 + (seed << 6) + (seed >> 2);
    hash_combine(seed, rest...);
}

size_t QLThumbnailsCacheImpl::KeyHash::operator()(const Key &c) const noexcept
{
    return c.hash;
}

QLThumbnailsCacheImpl::Key::Key()
{
    static_assert(sizeof(Key) == 56);
    path = path_storage;
    hash_combine(hash, path, px_size);
}

QLThumbnailsCacheImpl::Key::Key(const Key &_key)
{
    if( _key.path.data() == _key.path_storage.data() ) {
        path_storage = _key.path_storage;
        path = path_storage;
    }
    else {
        assert(_key.path_storage.empty());
        path = _key.path;
    }
    px_size = _key.px_size;
    hash = _key.hash;
}

QLThumbnailsCacheImpl::Key::Key(Key &&_key) noexcept
{
    if( _key.path.data() == _key.path_storage.data() ) {
        path_storage = std::move(_key.path_storage);
        path = path_storage;
    }
    else {
        assert(_key.path_storage.empty());
        path = _key.path;
    }
    px_size = _key.px_size;
    hash = _key.hash;
}

QLThumbnailsCacheImpl::Key::Key(std::string_view _path, int _px_size, no_ownership_tag /*unused*/)
{
    px_size = _px_size;
    path = _path;
    hash_combine(hash, path, px_size);
}

QLThumbnailsCacheImpl::Key::Key(const std::string &_path, int _px_size)
{
    path_storage = _path;
    px_size = _px_size;
    path = path_storage;
    hash_combine(hash, path, px_size);
}

QLThumbnailsCacheImpl::Key &QLThumbnailsCacheImpl::Key::operator=(const Key &_rhs)
{
    if( _rhs.path.data() == _rhs.path_storage.data() ) {
        path_storage = _rhs.path_storage;
        path = path_storage;
    }
    else {
        assert(_rhs.path_storage.empty());
        path = _rhs.path;
        path_storage.clear();
    }
    px_size = _rhs.px_size;
    hash = _rhs.hash;
    return *this;
}

bool QLThumbnailsCacheImpl::Key::operator==(const Key &_rhs) const noexcept
{
    return hash == _rhs.hash && px_size == _rhs.px_size && path == _rhs.path;
}

bool QLThumbnailsCacheImpl::Key::operator!=(const Key &_rhs) const noexcept
{
    return !(*this == _rhs);
}

static void GenerateQuickLookThumbnailAsync(NSURL *_url, CGSize _size, void (^_callback)(NSImage *))
{
    QLThumbnailGenerationRequest *const request = [[QLThumbnailGenerationRequest alloc]
          initWithFileAtURL:_url
                       size:_size
                      scale:1.0
        representationTypes:QLThumbnailGenerationRequestRepresentationTypeThumbnail];
    request.iconMode = YES;
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
                             _callback(image);
                           }];
}

static std::optional<QLThumbnailsCache::FileStateHint> ReadFileState(const std::string &_file_path)
{
    Log::Trace("ReadFileState(): requested a state for '{}'", _file_path);
    struct stat st;
    if( stat(_file_path.c_str(), &st) != 0 ) {
        Log::Warn("ReadFileState(): failed to stat() at '{}'", _file_path);
        return std::nullopt; // for some reason the file is not accessible - can't do anything
    }
    QLThumbnailsCache::FileStateHint hint;
    hint.size = static_cast<uint64_t>(st.st_size);
    hint.mtime = static_cast<uint64_t>(st.st_mtime);
    return hint;
}

NSImage *QLThumbnailsCacheImpl::ThumbnailIfHas(const std::string &_filename, int _px_size)
{
    Log::Trace("ThumbnailIfHas(): called for '{}' ({}px)", _filename, _px_size);
    const auto temp_key = Key{std::string_view{_filename}, _px_size, Key::no_ownership};
    const auto lock = std::lock_guard{m_ItemsLock};
    if( m_Items.count(temp_key) != 0 ) { // O(1)
        Log::Trace("ThumbnailIfHas(): found a cached entry for '{}' ({}px)", _filename, _px_size);
        const auto &info = m_Items[temp_key]; // O(1)
        assert(info != nullptr);
        return info->image;
    }
    else {
        Log::Trace("ThumbnailIfHas(): doesn't have a cached entry for '{}' ({}px)", _filename, _px_size);
        return nil;
    }
}

QLThumbnailsCacheImpl::QLThumbnailsCacheImpl() = default;

QLThumbnailsCacheImpl::~QLThumbnailsCacheImpl() = default;

void QLThumbnailsCacheImpl::ProduceThumbnailAsync(const std::string &_filename,
                                                  int _px_size,
                                                  const std::optional<FileStateHint> &_hint,
                                                  ThumbnailCallback _callback)
{
    if( !_callback )
        return;

    const auto file_state = _hint ? _hint : ReadFileState(_filename);
    if( !file_state.has_value() ) {
        _callback(nil);
        return;
    }

    const auto temp_key = Key{std::string_view{_filename}, _px_size, Key::no_ownership};
    std::unique_lock lock{m_ItemsLock};
    base::intrusive_ptr<Info> info;
    if( m_Items.count(temp_key) ) {
        info = m_Items[temp_key];
    }
    else {
        auto key = Key{_filename, _px_size};
        info = base::intrusive_ptr{new Info};
        m_Items.insert(std::move(key), info);
    }
    assert(info != nullptr);

    if( info->file_size == file_state->size && info->mtime == file_state->mtime ) {
        NSImage *const image = info->image;
        lock.unlock();
        _callback(image);
        return;
    }

    if( info->is_in_work.test_and_set() ) {
        info->waiters.emplace_back(std::move(_callback));
        return;
    }

    info->file_size = file_state->size;
    info->mtime = file_state->mtime;
    info->waiters.emplace_back(std::move(_callback));
    lock.unlock();

    NSURL *const url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:_filename.c_str()]];
    if( url == nil ) {
        std::vector<ThumbnailCallback> waiters;
        {
            const std::lock_guard guard{m_ItemsLock};
            waiters = std::move(info->waiters);
            info->is_in_work.clear();
        }
        for( auto &waiter : waiters )
            waiter(nil);
        return;
    }

    const CGSize size = NSMakeSize(_px_size, _px_size);
    GenerateQuickLookThumbnailAsync(url, size, ^(NSImage *image) {
      std::vector<ThumbnailCallback> waiters;
      {
          const std::lock_guard guard{m_ItemsLock};
          if( image != nil )
              info->image = image;
          waiters = std::move(info->waiters);
          info->is_in_work.clear();
      }
      for( auto &waiter : waiters )
          waiter(image);
    });
}

} // namespace nc::vfsicon
