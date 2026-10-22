// Copyright (C) 2013-2025 Michael Kazakov. Subject to GNU General Public License version 3.
#include "Internal.h"
#include <cassert>
#include <CoreFoundation/CoreFoundation.h>
#include <chrono>
#include <ctime>
#include <filesystem>
#include <condition_variable>
#include <cstring>
#include <mutex>
#include <thread>
#include <vector>

// The UnRAR headers expect this to be defined on POSIX systems, it's how their own build does it.
// It's undefined right afterwards to not leak into the unity build.
#define _UNIX
#include <dll.hpp>
#undef _UNIX

namespace nc::vfs::arc {

namespace {
// Defined further down, forward declared here as UnrarStream's worker needs it.
int CALLBACK NextVolume(char *_arc_name, int _mode);
} // namespace

ssize_t Mediator::myread([[maybe_unused]] struct archive *a, void *client_data, const void **buff)
{
    Mediator *_this = static_cast<Mediator *>(client_data);
    *buff = &_this->buf[0];

    if( _this->cancel_checker && _this->cancel_checker() ) {
        _this->cancelled = true;
        return ARCHIVE_FATAL;
    }

    const std::expected<size_t, Error> result = _this->file->Read(&_this->buf[0], bufsz);
    if( !result )
        return ARCHIVE_FATAL; // handle somehow
    return *result;
}

off_t Mediator::myseek([[maybe_unused]] struct archive *a, void *client_data, off_t offset, int whence)
{
    const Mediator *_this = static_cast<Mediator *>(client_data);
    const std::expected<uint64_t, Error> result = _this->file->Seek(offset, whence);
    if( !result )
        return ARCHIVE_FATAL; // handle somehow
    return *result;
}

void Mediator::setup(struct archive *a)
{
    assert(file.get() != nullptr);
    assert(file->GetReadParadigm() >= VFSFile::ReadParadigm::Seek);
    archive_read_set_callback_data(a, this);
    archive_read_set_read_callback(a, myread);
    archive_read_set_seek_callback(a, myseek);
}

State::State(const VFSFilePtr &_file, struct archive *_arc) : m_File(_file), m_Archive(_arc)
{
    assert(m_Archive);
    assert(m_File);
    assert(m_File->IsOpened());
    assert(m_File->GetReadParadigm() >= VFSFile::ReadParadigm::Seek);
    Setup();
}

State::~State()
{
    archive_read_free(m_Archive);
}

void State::Setup()
{
    archive_read_set_callback_data(m_Archive, this);
    archive_read_set_read_callback(m_Archive, myread);
    archive_read_set_seek_callback(m_Archive, myseek);
}

ssize_t State::myread([[maybe_unused]] struct archive *a, void *client_data, const void **buff)
{
    auto _this = static_cast<State *>(client_data);
    *buff = &_this->m_Buf;

    const std::expected<size_t, Error> result = _this->m_File->Read(&_this->m_Buf[0], BufferSize);
    if( !result )
        return ARCHIVE_FATAL; // handle somehow
    return *result;
}

off_t State::myseek([[maybe_unused]] struct archive *a, void *client_data, off_t offset, int whence)
{
    auto _this = static_cast<State *>(client_data);
    const std::expected<uint64_t, Error> result = _this->m_File->Seek(offset, whence);
    if( !result )
        return ARCHIVE_FATAL; // handle somehow
    return *result;
}

void State::SetEntry(struct archive_entry *_e, uint32_t _uid)
{
    assert(_uid >= m_UID);
    assert(_e);
    m_Entry = _e;
    m_UID = _uid;
    m_Consumed = false;
}

int State::Open()
{
    return archive_read_open1(m_Archive);
}

int State::Errno()
{
    return archive_errno(m_Archive);
}

namespace {

constexpr size_t g_BufferLimit = 1024 * 1024;

// The archive index is built by libarchive, which decodes RAR's Unicode file names into a
// decomposed form, while UnRAR reports them precomposed. Compare the two canonically.
bool AreCanonicallyEquivalent(const std::string &_lhs, const std::string &_rhs)
{
    if( _lhs == _rhs )
        return true;

    const auto make_cf_string = [](const std::string &_str) -> CFStringRef {
        return CFStringCreateWithBytes(kCFAllocatorDefault,
                                       reinterpret_cast<const UInt8 *>(_str.data()),
                                       static_cast<CFIndex>(_str.size()),
                                       kCFStringEncodingUTF8,
                                       false);
    };

    CFStringRef lhs = make_cf_string(_lhs);
    CFStringRef rhs = make_cf_string(_rhs);
    const bool equal =
        lhs != nullptr && rhs != nullptr && CFStringCompare(lhs, rhs, kCFCompareNonliteral) == kCFCompareEqualTo;
    if( lhs != nullptr )
        CFRelease(lhs);
    if( rhs != nullptr )
        CFRelease(rhs);
    return equal;
}

// UnRAR hands out wide characters, on POSIX they are UTF-32.
std::string WideToUTF8(const wchar_t *_str)
{
    std::string out;
    for( ; _str != nullptr && *_str != 0; ++_str ) {
        const auto cp = static_cast<uint32_t>(*_str);
        if( cp < 0x80 ) {
            out += static_cast<char>(cp);
        }
        else if( cp < 0x800 ) {
            out += static_cast<char>(0xC0 | (cp >> 6));
            out += static_cast<char>(0x80 | (cp & 0x3F));
        }
        else if( cp < 0x10000 ) {
            out += static_cast<char>(0xE0 | (cp >> 12));
            out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
            out += static_cast<char>(0x80 | (cp & 0x3F));
        }
        else {
            out += static_cast<char>(0xF0 | (cp >> 18));
            out += static_cast<char>(0x80 | ((cp >> 12) & 0x3F));
            out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
            out += static_cast<char>(0x80 | (cp & 0x3F));
        }
    }
    return out;
}

} // namespace

std::string NormalizeUTF8ToNFD(std::string_view _str)
{
    const CFStringRef str = CFStringCreateWithBytes(kCFAllocatorDefault,
                                                    reinterpret_cast<const UInt8 *>(_str.data()),
                                                    static_cast<CFIndex>(_str.size()),
                                                    kCFStringEncodingUTF8,
                                                    false);
    if( str == nullptr )
        return std::string{_str};

    const CFMutableStringRef mutable_str = CFStringCreateMutableCopy(kCFAllocatorDefault, 0, str);
    CFRelease(str);
    if( mutable_str == nullptr )
        return std::string{_str};

    CFStringNormalize(mutable_str, kCFStringNormalizationFormD);

    const CFIndex length = CFStringGetLength(mutable_str);
    const CFIndex capacity = CFStringGetMaximumSizeForEncoding(length, kCFStringEncodingUTF8) + 1;
    std::string out(static_cast<size_t>(capacity), '\0');
    CFIndex used = 0;
    CFStringGetBytes(mutable_str,
                     CFRangeMake(0, length),
                     kCFStringEncodingUTF8,
                     0,
                     false,
                     reinterpret_cast<UInt8 *>(out.data()),
                     capacity,
                     &used);
    CFRelease(mutable_str);
    out.resize(static_cast<size_t>(used));
    return out;
}

class UnrarStream::Impl
{
public:
    Impl(std::string _archive_path, std::string _entry_path, std::string _password, VFSCancelChecker _cancel_checker)
        : archive_path(std::move(_archive_path)), entry_path(std::move(_entry_path)), password(std::move(_password)),
          cancel_checker(std::move(_cancel_checker))
    {
    }

    ~Impl()
    {
        {
            const std::lock_guard<std::mutex> lock(mutex);
            cancelled = true;
        }
        data_available.notify_all();
        space_available.notify_all();
        if( worker.joinable() )
            worker.join();
    }

    void Produce();
    bool Push(const void *_data, size_t _size);
    void Finish(bool _failed);
    long Read(void *_buffer, size_t _size);

    static int RawCallback(unsigned int _msg, LPARAM _user_data, LPARAM _p1, LPARAM _p2);

    std::string archive_path;
    std::string entry_path;
    std::string password;
    VFSCancelChecker cancel_checker;

    std::thread worker;
    std::mutex mutex;
    std::condition_variable data_available;
    std::condition_variable space_available;
    std::vector<char> pending;
    size_t head = 0;
    bool finished = false;
    bool failed = false;
    bool cancelled = false;
};

void UnrarStream::Impl::Produce()
{
    RAROpenArchiveDataEx data{};
    data.ArcName = archive_path.data();
    data.OpenMode = RAR_OM_EXTRACT;
    HANDLE arc = RAROpenArchiveEx(&data);
    if( arc == nullptr ) {
        Finish(true);
        return;
    }
    if( !password.empty() )
        RARSetPassword(arc, password.data());
    RARSetChangeVolProc(arc, &NextVolume);
    RARSetCallback(arc, &Impl::RawCallback, reinterpret_cast<LPARAM>(this));

    bool extracted = false;
    RARHeaderDataEx header{};
    while( RARReadHeaderEx(arc, &header) == ERAR_SUCCESS ) {
        const std::string name = WideToUTF8(header.FileNameW);
        if( AreCanonicallyEquivalent(name, entry_path) ) {
            extracted = RARProcessFileW(arc, RAR_TEST, nullptr, nullptr) == ERAR_SUCCESS;
            break;
        }
        if( RARProcessFileW(arc, RAR_SKIP, nullptr, nullptr) != ERAR_SUCCESS )
            break;
    }

    RARCloseArchive(arc);
    Finish(!extracted);
}

bool UnrarStream::Impl::Push(const void *_data, size_t _size)
{
    const char *bytes = static_cast<const char *>(_data);
    std::unique_lock<std::mutex> lock(mutex);
    while( !cancelled && pending.size() - head > g_BufferLimit ) {
        if( cancel_checker && cancel_checker() ) {
            cancelled = true;
            break;
        }
        space_available.wait_for(lock, std::chrono::milliseconds(50));
    }
    if( cancelled )
        return false;

    pending.insert(pending.end(), bytes, bytes + _size);
    data_available.notify_one();
    return true;
}

void UnrarStream::Impl::Finish(bool _failed)
{
    {
        const std::lock_guard<std::mutex> lock(mutex);
        finished = true;
        failed = failed || _failed;
    }
    data_available.notify_all();
    space_available.notify_all();
}

long UnrarStream::Impl::Read(void *_buffer, size_t _size)
{
    std::unique_lock<std::mutex> lock(mutex);
    data_available.wait(lock, [this] { return pending.size() != head || finished; });

    if( pending.size() == head ) {
        if( cancelled )
            return 0;
        return failed ? -1 : 0;
    }

    const size_t available = pending.size() - head;
    const size_t to_read = _size < available ? _size : available;
    std::memcpy(_buffer, pending.data() + head, to_read);
    head += to_read;
    if( head == pending.size() ) {
        pending.clear();
        head = 0;
    }
    else if( head > g_BufferLimit / 2 ) {
        pending.erase(pending.begin(), pending.begin() + static_cast<std::ptrdiff_t>(head));
        head = 0;
    }
    space_available.notify_one();
    return static_cast<long>(to_read);
}

int UnrarStream::Impl::RawCallback(unsigned int _msg, LPARAM _user_data, LPARAM _p1, LPARAM _p2)
{
    if( _msg != UCM_PROCESSDATA )
        return 1;

    auto *self = reinterpret_cast<Impl *>(_user_data);
    return self->Push(reinterpret_cast<const void *>(_p1), static_cast<size_t>(_p2)) ? 1 : 0;
}

UnrarStream::UnrarStream(std::string _archive_path,
                         std::string _entry_path,
                         std::string _password,
                         const VFSCancelChecker &_cancel_checker)
    : I(std::make_unique<Impl>(std::move(_archive_path), std::move(_entry_path), std::move(_password), _cancel_checker))
{
    // UnRAR reports the entry names without the leading slash that the archive VFS uses.
    if( !I->entry_path.empty() && I->entry_path.front() == '/' )
        I->entry_path.erase(I->entry_path.begin());
}

UnrarStream::~UnrarStream() = default;

std::unique_ptr<UnrarStream> UnrarStream::Open(const std::string &_archive_path,
                                               const std::string &_entry_path,
                                               std::string_view _password,
                                               const VFSCancelChecker &_cancel_checker)
{
    std::string password{_password};

    // Cheap sanity check that this is really a RAR archive that UnRAR can open, so that the
    // caller gets a chance to fall back before any decompression has been started.
    {
        RAROpenArchiveDataEx probe{};
        probe.ArcName = const_cast<char *>(_archive_path.c_str()); // UnRAR's API isn't const-correct
        probe.OpenMode = RAR_OM_LIST;
        HANDLE arc = RAROpenArchiveEx(&probe);
        if( arc == nullptr )
            return nullptr;

        if( !password.empty() )
            RARSetPassword(arc, password.data());

        // Reading the first header validates the password for archives with encrypted headers,
        // let the caller fall back when UnRAR can't get past it.
        RARHeaderDataEx header{};
        const int header_rc = RARReadHeaderEx(arc, &header);
        RARCloseArchive(arc);

        if( header_rc == ERAR_BAD_PASSWORD || header_rc == ERAR_MISSING_PASSWORD )
            return nullptr;
    }

    std::unique_ptr<UnrarStream> stream{new UnrarStream(_archive_path, _entry_path, password, _cancel_checker)};
    stream->I->worker = std::thread([impl = stream->I.get()] { impl->Produce(); });
    return stream;
}

long UnrarStream::Read(void *_buffer, size_t _size)
{
    return I->Read(_buffer, _size);
}

namespace {

constexpr unsigned int kFileAttributeDirectory = 0x10;
constexpr unsigned int kFileAttributeUnixExtension = 0x8000;
constexpr unsigned int kHeaderFlagEncrypted = 0x04;

time_t DosTimeToUnix(uint32_t _dos_time)
{
    struct tm tm{};
    tm.tm_sec = static_cast<int>(_dos_time & 0x1F) * 2;
    tm.tm_min = static_cast<int>((_dos_time >> 5) & 0x3F);
    tm.tm_hour = static_cast<int>((_dos_time >> 11) & 0x1F);
    tm.tm_mday = static_cast<int>((_dos_time >> 16) & 0x1F);
    tm.tm_mon = static_cast<int>((_dos_time >> 21) & 0x0F) - 1;
    tm.tm_year = static_cast<int>((_dos_time >> 25) & 0x7F) + 80;
    tm.tm_isdst = -1;
    return mktime(&tm);
}

// UnRAR asks for the next volume of a multi-volume archive through this callback. All the volumes
// are expected to sit next to the first one, which is where UnRAR computes their names anyway.
int CALLBACK NextVolume(char *_arc_name, int _mode)
{
    if( _mode == RAR_VOL_NOTIFY )
        return 1;

    std::error_code ec;
    return std::filesystem::exists(std::filesystem::path{_arc_name}, ec) ? 1 : 0;
}

int PosixCodeForUnrarError(int _error)
{
    switch( _error ) {
        case ERAR_MISSING_PASSWORD:
        case ERAR_BAD_PASSWORD:
            return ENEEDAUTH;
        case ERAR_BAD_ARCHIVE:
        case ERAR_UNKNOWN_FORMAT:
            return EFTYPE;
        default:
            return EIO;
    }
}

} // namespace

class UnrarArchive::Impl
{
public:
    ~Impl()
    {
        if( arc != nullptr )
            RARCloseArchive(arc);
    }

    HANDLE arc = nullptr;
    int error = 0;
    uint32_t uid = 0;
};

UnrarArchive::UnrarArchive() : I(std::make_unique<Impl>())
{
}

UnrarArchive::~UnrarArchive() = default;

std::unique_ptr<UnrarArchive>
UnrarArchive::Open(std::string_view _archive_path, std::string_view _password, int &_error)
{
    _error = 0;

    auto archive = std::unique_ptr<UnrarArchive>{new UnrarArchive};

    std::string arc_name{_archive_path};
    RAROpenArchiveDataEx data{};
    data.ArcName = arc_name.data(); // UnRAR's API isn't const-correct
    data.OpenMode = RAR_OM_LIST;

    archive->I->arc = RAROpenArchiveEx(&data);
    if( archive->I->arc == nullptr ) {
        _error = PosixCodeForUnrarError(data.OpenResult);
        return nullptr;
    }

    if( !_password.empty() ) {
        std::string password{_password};
        RARSetPassword(archive->I->arc, password.data());
    }

    RARSetChangeVolProc(archive->I->arc, &NextVolume);
    return archive;
}

bool UnrarArchive::Next(Entry &_entry)
{
    if( I->arc == nullptr || I->error != 0 )
        return false;

    RARHeaderDataEx header{};
    const int rc = RARReadHeaderEx(I->arc, &header);
    if( rc != ERAR_SUCCESS ) {
        if( rc != ERAR_END_ARCHIVE )
            I->error = PosixCodeForUnrarError(rc);
        return false;
    }

    _entry = Entry{};
    _entry.uid = ++I->uid;
    _entry.name = WideToUTF8(header.FileNameW);
    // Directory entries may come with a trailing slash, the host expects them without one.
    while( !_entry.name.empty() && _entry.name.back() == '/' )
        _entry.name.pop_back();
    _entry.is_encrypted = (header.Flags & kHeaderFlagEncrypted) != 0;

    mode_t mode = 0;
    if( (header.FileAttr & kFileAttributeUnixExtension) != 0 )
        mode = static_cast<mode_t>(header.FileAttr >> 16);

    const bool is_dir = (mode & S_IFMT) == S_IFDIR || (header.FileAttr & kFileAttributeDirectory) != 0 ||
                        (!_entry.name.empty() && _entry.name.back() == '/');

    if( mode == 0 )
        mode = is_dir ? (S_IFDIR | 0755) : (S_IFREG | 0644);
    else if( is_dir )
        mode = static_cast<mode_t>((mode & ~S_IFMT) | S_IFDIR);

    _entry.is_dir = is_dir;
    _entry.is_symlink = (mode & S_IFMT) == S_IFLNK;

    struct stat st{};
    st.st_mode = mode;
    st.st_size =
        static_cast<off_t>(static_cast<uint64_t>(header.UnpSize) | (static_cast<uint64_t>(header.UnpSizeHigh) << 32));

    const auto mtime = static_cast<int64_t>((static_cast<uint64_t>(header.MtimeHigh) << 32) | header.MtimeLow);
    const auto ctime = static_cast<int64_t>((static_cast<uint64_t>(header.CtimeHigh) << 32) | header.CtimeLow);
    const auto atime = static_cast<int64_t>((static_cast<uint64_t>(header.AtimeHigh) << 32) | header.AtimeLow);
    const time_t fallback_time = header.FileTime != 0 ? DosTimeToUnix(header.FileTime) : 0;

    st.st_mtimespec.tv_sec = mtime > 0 ? static_cast<time_t>(mtime) : fallback_time;
    st.st_ctimespec.tv_sec = ctime > 0 ? static_cast<time_t>(ctime) : st.st_mtimespec.tv_sec;
    st.st_atimespec.tv_sec = atime > 0 ? static_cast<time_t>(atime) : st.st_mtimespec.tv_sec;
    st.st_birthtimespec.tv_sec = st.st_ctimespec.tv_sec;

    _entry.st = st;

    // Advance past the payload. In the RAR_OM_LIST mode UnRAR just seeks over the data blocks
    // instead of decompressing them, which is what makes the listing of solid archives cheap.
    if( const int skip_rc = RARProcessFileW(I->arc, RAR_SKIP, nullptr, nullptr); skip_rc != ERAR_SUCCESS )
        I->error = PosixCodeForUnrarError(skip_rc);

    return true;
}

int UnrarArchive::Error() const
{
    return I->error;
}

} // namespace nc::vfs::arc
