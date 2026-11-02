// Copyright (C) 2021-2026 Michael Kazakov. Subject to GNU General Public License version 3.
#include <RoutedIO/Trash.h>
#include <Foundation/Foundation.h>
#include <CoreFoundation/CoreFoundation.h>
#include <Base/CFPtr.h>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <dirent.h>
#include <filesystem>
#include <string_view>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <unistd.h>
#include <unordered_map>

namespace nc::routedio {

namespace {

constexpr std::string_view g_OriginalPathAttr = "info.filesmanager.trash.originalPath";

std::string Utf16BeToUtf8(const uint8_t *_data, size_t _chars)
{
    if( _chars == 0 )
        return {};
    nc::base::CFPtr<CFStringRef> str = nc::base::CFPtr<CFStringRef>::adopt(
        CFStringCreateWithBytes(nullptr, _data, static_cast<CFIndex>(_chars) * 2, kCFStringEncodingUTF16BE, false));
    if( !str )
        return {};
    const CFIndex len = CFStringGetLength(str.get());
    const CFIndex max_size = CFStringGetMaximumSizeForEncoding(len, kCFStringEncodingUTF8) + 1;
    std::string result(static_cast<size_t>(max_size), '\0');
    if( !CFStringGetCString(str.get(), result.data(), max_size, kCFStringEncodingUTF8) )
        return {};
    result.resize(std::strlen(result.c_str()));
    return result;
}

struct PutBackLocation {
    std::string parent;
    std::string name;
};

// A minimal reader for the .DS_Store files that the Finder keeps in folders. Only the put-back
// locations are of interest: they are stored as 'ptbL' (the original parent folder) and 'ptbN'
// (the original file name) string records.
class DsStoreParser
{
public:
    DsStoreParser(const std::string &_path) { Load(_path); }

    std::unordered_map<std::string, PutBackLocation> PutBackLocations() const;

private:
    bool Load(const std::string &_path);
    bool ParseBlock(uint32_t _block);
    bool ReadRecord(size_t &_pos, std::string &_name, std::string &_code, std::string &_ustr) const;

    bool Bounds(size_t _pos, size_t _len) const { return _pos <= m_Data.size() && _len <= m_Data.size() - _pos; }
    uint32_t U32(size_t _pos) const;

    std::vector<uint8_t> m_Data;
    std::vector<uint32_t> m_BlockAddresses;
    std::unordered_map<std::string, PutBackLocation> m_Locations;
};

static constexpr uint32_t Align256(uint32_t _value)
{
    return (_value + 255) & ~255u;
}

uint32_t DsStoreParser::U32(size_t _pos) const
{
    if( !Bounds(_pos, 4) )
        return 0;
    return (static_cast<uint32_t>(m_Data[_pos]) << 24) | (static_cast<uint32_t>(m_Data[_pos + 1]) << 16) |
           (static_cast<uint32_t>(m_Data[_pos + 2]) << 8) | static_cast<uint32_t>(m_Data[_pos + 3]);
}

bool DsStoreParser::Load(const std::string &_path)
{
    FILE *const file = std::fopen(_path.c_str(), "rb");
    if( file == nullptr )
        return false;
    std::fseek(file, 0, SEEK_END);
    const long size = std::ftell(file);
    std::fseek(file, 0, SEEK_SET);
    if( size <= 0 || size > 64 * 1024 * 1024 ) {
        std::fclose(file);
        return false;
    }
    m_Data.resize(static_cast<size_t>(size));
    const size_t read = std::fread(m_Data.data(), 1, m_Data.size(), file);
    std::fclose(file);
    if( read != m_Data.size() )
        return false;

    // Header: magic, 'Bud1', root block offset, root block size, mirrored offset.
    if( m_Data.size() < 32 || U32(0) != 1 )
        return false;
    if( std::memcmp(m_Data.data() + 4, "Bud1", 4) != 0 )
        return false;
    const uint32_t root_offset = U32(8);
    const uint32_t root_size = U32(12);
    if( U32(16) != root_offset || !Bounds(root_offset, root_size) )
        return false;

    // The payload of a buddy block starts four bytes past its address, which is why the root
    // block's fields are read with a '+4' - and the offsets array starts at '+12'.
    const uint32_t block_count = U32(root_offset + 4);
    if( block_count == 0 || block_count > 1'000'000 )
        return false;
    const uint32_t padded_count = Align256(block_count);
    const size_t addresses_pos = static_cast<size_t>(root_offset) + 12;
    if( !Bounds(addresses_pos, static_cast<size_t>(padded_count) * 4) )
        return false;
    m_BlockAddresses.resize(block_count);
    for( uint32_t i = 0; i < block_count; ++i )
        m_BlockAddresses[i] = U32(addresses_pos + static_cast<size_t>(i) * 4);

    // Every block is inspected on its own: leaf blocks parse as a plain list of records, while
    // internal ones simply fail to parse and get skipped. This keeps the code independent of
    // the B-tree metadata, which is not always consistent between writers.
    for( uint32_t i = 0; i < block_count; ++i )
        ParseBlock(i);
    return true;
}

bool DsStoreParser::ParseBlock(uint32_t _block)
{
    if( _block >= m_BlockAddresses.size() )
        return false;
    const uint32_t address = m_BlockAddresses[_block];
    const uint32_t offset = (address & ~0x1Fu) + 4;
    if( !Bounds(offset, 8) )
        return false;
    const uint32_t count = U32(offset + 4);
    if( count == 0 || count > 1'000'000 )
        return false;
    size_t pos = static_cast<size_t>(offset) + 8;

    struct Record {
        std::string name;
        std::string code;
        std::string value;
    };
    std::vector<Record> records;
    records.reserve(count);
    for( uint32_t i = 0; i < count; ++i ) {
        Record record;
        if( !ReadRecord(pos, record.name, record.code, record.value) )
            return false;
        records.push_back(std::move(record));
    }

    for( const Record &record : records ) {
        if( (record.code == "ptbL" || record.code == "ptbN") && !record.value.empty() ) {
            PutBackLocation &location = m_Locations[record.name];
            if( record.code == "ptbL" )
                location.parent = record.value;
            else
                location.name = record.value;
        }
    }
    return true;
}

bool DsStoreParser::ReadRecord(size_t &_pos, std::string &_name, std::string &_code, std::string &_ustr) const
{
    if( !Bounds(_pos, 4) )
        return false;
    const uint32_t name_len = U32(_pos);
    _pos += 4;
    if( name_len > 1'000'000 || !Bounds(_pos, static_cast<size_t>(name_len) * 2 + 8) )
        return false;
    _name = Utf16BeToUtf8(m_Data.data() + _pos, name_len);
    _pos += static_cast<size_t>(name_len) * 2;
    _code.assign(reinterpret_cast<const char *>(m_Data.data() + _pos), 4);
    _pos += 4;
    const std::string type(reinterpret_cast<const char *>(m_Data.data() + _pos), 4);
    _pos += 4;
    _ustr.clear();

    if( type == "ustr" ) {
        if( !Bounds(_pos, 4) )
            return false;
        const uint32_t len = U32(_pos);
        _pos += 4;
        if( !Bounds(_pos, static_cast<size_t>(len) * 2) )
            return false;
        _ustr = Utf16BeToUtf8(m_Data.data() + _pos, len);
        _pos += static_cast<size_t>(len) * 2;
    }
    else if( type == "blob" ) {
        if( !Bounds(_pos, 4) )
            return false;
        const uint32_t len = U32(_pos);
        _pos += 4;
        if( !Bounds(_pos, len) )
            return false;
        _pos += len;
    }
    else if( type == "bool" ) {
        if( !Bounds(_pos, 1) )
            return false;
        _pos += 1;
    }
    else if( type == "long" || type == "shor" ) {
        if( !Bounds(_pos, 4) )
            return false;
        _pos += 4;
    }
    else if( type == "type" ) {
        if( !Bounds(_pos, 4) )
            return false;
        _pos += 4;
    }
    else if( type == "comp" || type == "dutc" ) {
        if( !Bounds(_pos, 8) )
            return false;
        _pos += 8;
    }
    else {
        return false;
    }
    return true;
}

std::unordered_map<std::string, PutBackLocation> DsStoreParser::PutBackLocations() const
{
    return m_Locations;
}

std::string JoinPath(const std::string &_parent, const std::string &_name)
{
    if( _parent.empty() )
        return _name;
    if( _parent.back() == '/' )
        return _parent + _name;
    return _parent + "/" + _name;
}

bool IsDirectory(const std::string &_path)
{
    struct stat st;
    return stat(_path.c_str(), &st) == 0 && S_ISDIR(st.st_mode);
}

bool ReadAttribute(const std::string &_path, const char *_name, std::string &_value)
{
    const ssize_t size = getxattr(_path.c_str(), _name, nullptr, 0, 0, 0);
    if( size <= 0 || size > 1024 * 1024 )
        return false;
    _value.assign(static_cast<size_t>(size), '\0');
    const ssize_t result = getxattr(_path.c_str(), _name, _value.data(), _value.size(), 0, 0);
    if( result != size ) {
        _value.clear();
        return false;
    }
    return true;
}

std::string UniqueTarget(const std::string &_target)
{
    std::error_code ec;
    if( !std::filesystem::exists(_target, ec) )
        return _target;
    const std::filesystem::path path(_target);
    const std::string stem = path.stem().string();
    const std::string extension = path.extension().string();
    for( int i = 2; i < 10'000; ++i ) {
        const std::string candidate = (path.parent_path() / (stem + " " + std::to_string(i) + extension)).string();
        if( !std::filesystem::exists(candidate, ec) )
            return candidate;
    }
    return _target;
}

} // namespace

std::string TrashDirectory()
{
    NSString *const home = NSHomeDirectory();
    return home == nil ? std::string{} : std::string{home.UTF8String} + "/.Trash";
}

std::vector<std::string> TrashLocations()
{
    std::vector<std::string> locations;
    const std::string home_trash = TrashDirectory();
    if( IsDirectory(home_trash) )
        locations.push_back(home_trash);

    // Every mounted local volume has its own per-user trash folder.
    const std::string uid = std::to_string(getuid());
    struct statfs *mounts = nullptr;
    const int count = getmntinfo(&mounts, MNT_NOWAIT);
    for( int i = 0; i < count; ++i ) {
        const std::string mount = mounts[i].f_mntonname;
        if( mount == "/" || !(mounts[i].f_flags & MNT_LOCAL) )
            continue;
        const std::string trash = mount + "/.Trashes/" + uid;
        if( IsDirectory(trash) )
            locations.push_back(trash);
    }
    return locations;
}

std::string TrashContaining(const std::string &_path)
{
    std::string result;
    for( const std::string &location : TrashLocations() ) {
        if( _path == location || _path.starts_with(location + "/") ) {
            if( location.size() > result.size() )
                result = location;
        }
    }
    return result;
}

std::string TrashForVolumeOf(const std::string &_path)
{
    if( _path.empty() || _path.front() != '/' )
        return TrashDirectory();

    struct statfs *mounts = nullptr;
    const int count = getmntinfo(&mounts, MNT_NOWAIT);
    std::string best_mount;
    for( int i = 0; i < count; ++i ) {
        const std::string mount = mounts[i].f_mntonname;
        if( _path == mount || _path.starts_with(mount == "/" ? mount : mount + "/") ) {
            if( mount.size() > best_mount.size() )
                best_mount = mount;
        }
    }
    if( best_mount.empty() || best_mount == "/" )
        return TrashDirectory();

    const std::string trash = best_mount + "/.Trashes/" + std::to_string(getuid());
    return IsDirectory(trash) ? trash : std::string{};
}

bool IsTrashDirectory(const std::string &_path)
{
    for( const std::string &location : TrashLocations() )
        if( _path == location )
            return true;
    return false;
}

bool IsInsideTrash(const std::string &_path)
{
    return !TrashContaining(_path).empty();
}

std::vector<std::string> ListTrashDirectory(const std::string &_directory, int &_error)
{
    _error = 0;
    std::vector<std::string> result;
    DIR *const dir = opendir(_directory.c_str());
    if( dir == nullptr ) {
        _error = errno;
        return result;
    }
    while( const dirent *const entry = readdir(dir) ) {
        const std::string name = entry->d_name;
        if( name == "." || name == ".." || name == ".DS_Store" )
            continue;
        result.push_back(_directory + "/" + name);
    }
    closedir(dir);
    return result;
}

std::optional<std::string> OriginalLocationFromDsStore(const std::string &_ds_store_path, const std::string &_filename)
{
    DsStoreParser parser(_ds_store_path);
    const auto locations = parser.PutBackLocations();
    const auto it = locations.find(_filename);
    if( it == locations.end() || it->second.parent.empty() || it->second.name.empty() )
        return std::nullopt;
    return JoinPath(it->second.parent, it->second.name);
}

std::optional<std::string> OriginalLocationOfTrashedItem(const std::string &_trash_item_path)
{
    std::string recorded;
    if( ReadAttribute(_trash_item_path, g_OriginalPathAttr.data(), recorded) && !recorded.empty() )
        return recorded;

    const std::filesystem::path item(_trash_item_path);
    const std::string filename = item.filename().string();
    if( filename.empty() )
        return std::nullopt;
    const std::string trash = TrashContaining(_trash_item_path);
    return OriginalLocationFromDsStore((trash.empty() ? TrashDirectory() : trash) + "/.DS_Store", filename);
}

void RememberOriginalLocation(const std::string &_path)
{
    if( _path.empty() || _path.front() != '/' )
        return;
    if( IsInsideTrash(_path) )
        return;
    setxattr(_path.c_str(), g_OriginalPathAttr.data(), _path.data(), _path.size(), 0, 0);
}

int PutBackTrashedItem(const std::string &_trash_item_path, std::string &_resulting_path)
{
    _resulting_path.clear();
    const std::optional<std::string> original = OriginalLocationOfTrashedItem(_trash_item_path);
    if( !original )
        return ENOENT;

    const std::filesystem::path target_path(*original);
    std::error_code ec;
    if( target_path.has_parent_path() ) {
        std::filesystem::create_directories(target_path.parent_path(), ec);
        if( ec )
            return ec.value();
    }

    const std::string target = UniqueTarget(target_path.string());
    std::filesystem::rename(_trash_item_path, target, ec);
    if( ec && ec.value() == EXDEV ) {
        // The trash and the original location can sit on different volumes, in which case the
        // item has to be copied over and then removed from the trash.
        ec.clear();
        std::filesystem::copy(_trash_item_path,
                              target,
                              std::filesystem::copy_options::recursive | std::filesystem::copy_options::copy_symlinks,
                              ec);
        if( !ec ) {
            std::error_code remove_ec;
            std::filesystem::remove_all(_trash_item_path, remove_ec);
        }
    }
    if( ec )
        return ec.value();

    removexattr(target.c_str(), g_OriginalPathAttr.data(), 0);
    _resulting_path = target;
    return 0;
}

int TrashItemAtPath(const char *_path) noexcept
{
    if( _path == nullptr ) {
        errno = EINVAL;
        return -1;
    }
    RememberOriginalLocation(_path);

    const auto url = nc::base::CFPtr<CFURLRef>::adopt(CFURLCreateFromFileSystemRepresentation(
        nullptr, reinterpret_cast<const UInt8 *>(_path), std::string_view{_path}.length(), false));

    if( !url ) {
        errno = ENOENT;
        return -1;
    }

    NSError *error;
    const auto result = [NSFileManager.defaultManager trashItemAtURL:(__bridge NSURL *)url.get()
                                                    resultingItemURL:nil
                                                               error:&error];

    if( result ) {
        return 0;
    }
    else {
        if( error != nil && [error.domain isEqualToString:NSPOSIXErrorDomain] ) {
            errno = static_cast<int>(error.code);
        }
        else {
            errno = EPERM;
        }
        return -1;
    }
}

} // namespace nc::routedio
