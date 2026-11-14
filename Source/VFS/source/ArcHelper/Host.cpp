// Copyright (C) 2026 Michael Kazakov. Subject to GNU General Public License version 3.
#include "Host.h"
#include "../ListingInput.h"
#include "File.h"
#include "Helper.h"
#include <Base/UnorderedUtil.h>
#include <Base/algo.h>
#include <Utility/PathManip.h>
#include <algorithm>
#include <cassert>
#include <cerrno>
#include <limits>
#include <memory>
#include <mutex>
#include <poll.h>
#include <sys/dirent.h>
#include <sys/param.h>
#include <sys/stat.h>
#include <tuple>
#include <utility>
#include <vector>

namespace nc::vfs {

namespace {

constexpr mode_t g_FileMode = S_IFREG | //
                              S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH;
constexpr mode_t g_DirMode = S_IFDIR | //
                             S_IRUSR | S_IWUSR | S_IXUSR | S_IRGRP | S_IXGRP | S_IROTH | S_IXOTH;
constexpr mode_t g_LinkMode = S_IFLNK | //
                              S_IRUSR | S_IWUSR | S_IXUSR | S_IRGRP | S_IXGRP | S_IROTH | S_IXOTH;

// Drops trailing slashes, so that "/dir/" and "/dir" are looked up the same way.
std::string NormalizeLookupPath(const std::string_view _path)
{
    return std::string{utility::PathManip::WithoutTrailingSlashes(_path)};
}

// The archive paths are '/'-separated and never carry empty components.
std::vector<std::string> SplitArchivePath(const std::string_view _path)
{
    std::vector<std::string> components;
    size_t pos = 0;
    while( pos <= _path.size() ) {
        const size_t slash = _path.find('/', pos);
        const size_t end = slash == std::string_view::npos ? _path.size() : slash;
        if( end > pos )
            components.emplace_back(_path.substr(pos, end - pos));
        if( slash == std::string_view::npos )
            break;
        pos = slash + 1;
    }
    return components;
}

std::string JoinArchivePath(const std::vector<std::string> &_components)
{
    if( _components.empty() )
        return "/";
    std::string path;
    for( const std::string &component : _components ) {
        path += '/';
        path += component;
    }
    return path;
}

// Reads everything the child writes to stdout, checking for cancellation while waiting. Keep the
// buffer off the stack - the VFS code has a tight stack frame budget.
std::expected<std::string, Error> ReadChildOutput(rar::ChildProcess &_process, const VFSCancelChecker &_cancel_checker)
{
    std::string output;
    const std::unique_ptr<char[]> buffer = std::make_unique<char[]>(size_t{64} * 1024);
    while( true ) {
        if( _cancel_checker && _cancel_checker() )
            return std::unexpected(Error{Error::POSIX, ECANCELED});

        pollfd pfd{};
        pfd.fd = _process.StdoutFD();
        pfd.events = POLLIN;
        const int poll_rc = ::poll(&pfd, 1, 100);
        if( poll_rc < 0 ) {
            if( errno == EINTR )
                continue;
            return std::unexpected(Error{Error::POSIX, errno});
        }
        if( poll_rc == 0 )
            continue; // the timeout expired, check for cancellation again

        const std::expected<size_t, Error> read = _process.Read(buffer.get(), size_t{64} * 1024);
        if( !read )
            return std::unexpected(read.error());
        if( *read == 0 )
            break;
        output.append(buffer.get(), *read);
    }
    return output;
}

// The one-shot "link" command, used for RAR4 symlinks whose target isn't in the listing.
std::expected<std::string, Error> FetchLinkTargetOneShot(const std::string &_helper_path,
                                                         const std::string &_archive_path,
                                                         const std::optional<std::string> &_password,
                                                         uint32_t _index,
                                                         const VFSCancelChecker &_cancel_checker)
{
    const std::vector<std::string> args{"link", _archive_path, std::to_string(_index)};
    std::expected<rar::ChildProcess, Error> process = rar::ChildProcess::Spawn(_helper_path, args, _password);
    if( !process )
        return std::unexpected(process.error());
    const auto terminate_process = at_scope_end([&] { process->Terminate(); });

    const std::expected<std::string, Error> output = ReadChildOutput(*process, _cancel_checker);
    if( !output )
        return std::unexpected(output.error());

    const std::expected<int, Error> exit_code = process->Wait();
    if( !exit_code )
        return std::unexpected(exit_code.error());
    if( *exit_code != 0 )
        return std::unexpected(rar::ErrorForHelperExitCode(*exit_code));

    std::optional<std::string> target = rar::ParseLinkResponse(*output);
    if( !target )
        return std::unexpected(Error{Error::POSIX, EFTYPE});
    return std::move(*target);
}

// A synthetic mode is a fallback for entries that don't carry Unix attributes.
mode_t ModeForEntry(const rar::Entry &_entry)
{
    const mode_t permissions = _entry.mode ? static_cast<mode_t>(*_entry.mode & 07777) : 0;
    // Directories and links keep their kind regardless of what the archive header claims.
    if( _entry.dir )
        return _entry.mode ? (permissions | S_IFDIR) : g_DirMode;
    if( _entry.IsLink() )
        return _entry.mode ? (permissions | S_IFLNK) : g_LinkMode;
    if( !_entry.mode )
        return g_FileMode;

    const mode_t type = static_cast<mode_t>(*_entry.mode & S_IFMT);
    if( type == 0 || type == S_IFDIR || type == S_IFLNK )
        return permissions | S_IFREG;
    return permissions | type;
}

} // namespace

const char *const RarHelperHost::UniqueTag = "arc_rar_helper";

struct RarHelperHost::Impl {
    struct EntryRec {
        std::string name; // name in the parent directory
        uint32_t index = 0;
        bool is_dir = false;
        bool is_link = false;
        std::optional<std::string> link_target;
        VFSStat st;
    };

    struct DirRec {
        std::string full_path; // with a trailing slash
        std::vector<EntryRec> entries;
        uint64_t content_size = 0;
    };

    // A segmented map keeps the pointers to the directories stable while new ones are inserted.
    using PathToDirT = ankerl::unordered_dense::
        segmented_map<std::string, DirRec, nc::UnorderedStringHashEqual, nc::UnorderedStringHashEqual>;

    Impl()
    {
        DirRec root;
        root.full_path = "/";
        path_to_dir.emplace("/", std::move(root));
    }

    DirRec *FindDir(const std::string_view _path_with_tr_sl);
    DirRec *FindOrBuildDir(const std::string_view _path_with_tr_sl);
    void InsertDummyDirInto(DirRec *_parent, const std::string_view _dir_name);
    const EntryRec *FindEntry(std::string_view _path) const noexcept;
    EntryRec *FindEntryMutable(std::string_view _path) noexcept;
    EntryRec *FindEntryInDir(std::string_view _parent, std::string_view _name) noexcept;
    uint64_t UpdateDirectorySize(DirRec &_directory, const std::string &_path);
    void ApplyEntry(const rar::Entry &_entry, EntryRec &_rec);

    std::expected<std::string, Error> LinkTarget(EntryRec &_entry, const VFSCancelChecker &_cancel_checker);
    std::expected<std::string, Error>
    ResolvePath(std::string_view _path, bool _follow_last, const VFSCancelChecker &_cancel_checker);

    PathToDirT path_to_dir;
    std::string helper_path;
    std::string archive_path;
    std::optional<std::string> password;
    struct ::stat src_stat;
    bool needs_path_resolving = false;

    mutable std::mutex link_target_mutex;
};

class RarHelperHostConfiguration
{
public:
    std::string path;
    std::optional<std::string> password;

    [[nodiscard]] static const char *Tag() { return RarHelperHost::UniqueTag; }

    [[nodiscard]] const char *Junction() const { return path.c_str(); }

    bool operator==(const RarHelperHostConfiguration &_rhs) const
    {
        return path == _rhs.path && password == _rhs.password;
    }
};

namespace {

VFSConfiguration ComposeRarHelperConfiguration(const std::string_view _path, std::optional<std::string> _passwd)
{
    RarHelperHostConfiguration config;
    config.path = _path;
    config.password = std::move(_passwd);
    return {std::move(config)};
}

} // namespace

RarHelperHost::RarHelperHost(const std::string_view _path,
                             const VFSHostPtr &_parent,
                             std::optional<std::string> _password,
                             VFSCancelChecker _cancel_checker)
    : Host(_path, _parent, UniqueTag), I(std::make_unique<Impl>()),
      m_Configuration(ComposeRarHelperConfiguration(_path, std::move(_password)))
{
    assert(_parent);
    if( const std::expected<void, Error> rc = DoInit(_cancel_checker); !rc )
        throw ErrorException(rc.error());
}

RarHelperHost::RarHelperHost(const VFSHostPtr &_parent,
                             const VFSConfiguration &_config,
                             VFSCancelChecker _cancel_checker)
    : Host(_config.Get<RarHelperHostConfiguration>().path, _parent, UniqueTag), I(std::make_unique<Impl>()),
      m_Configuration(_config)
{
    assert(_parent);
    if( const std::expected<void, Error> rc = DoInit(_cancel_checker); !rc )
        throw ErrorException(rc.error());
}

RarHelperHost::~RarHelperHost() = default;

VFSConfiguration RarHelperHost::Configuration() const
{
    return m_Configuration;
}

const RarHelperHostConfiguration &RarHelperHost::Config() const
{
    return m_Configuration.GetUnchecked<RarHelperHostConfiguration>();
}

VFSMeta RarHelperHost::Meta()
{
    VFSMeta m;
    m.Tag = UniqueTag;
    m.SpawnWithConfig =
        [](const VFSHostPtr &_parent, const VFSConfiguration &_config, VFSCancelChecker _cancel_checker) {
            return std::make_shared<RarHelperHost>(_parent, _config, _cancel_checker);
        };
    return m;
}

bool RarHelperHost::IsImmutableFS() const noexcept
{
    return true;
}

bool RarHelperHost::IsWritable() const
{
    return false;
}

std::shared_ptr<RarHelperHost> RarHelperHost::SharedPtr()
{
    return std::static_pointer_cast<RarHelperHost>(Host::SharedPtr());
}

const std::string &RarHelperHost::HelperPath() const noexcept
{
    return I->helper_path;
}

std::string_view RarHelperHost::Password() const noexcept
{
    return Config().password ? std::string_view{*Config().password} : std::string_view{};
}

bool RarHelperHost::ShouldProduceThumbnails() const
{
    // Same policy as the libarchive-based ArchiveHost: everything inside an archive goes through
    // the regular read path, so thumbnails are worth producing.
    return true;
}

std::expected<std::string, Error> RarHelperHost::ResolvePath(const std::string_view _path,
                                                             const bool _follow_last,
                                                             const VFSCancelChecker &_cancel_checker) const
{
    if( _path.empty() || _path[0] != '/' )
        return std::unexpected(Error{Error::POSIX, EINVAL});

    std::string path = NormalizeLookupPath(_path);
    if( path == "/" || !I->needs_path_resolving )
        return path;

    return I->ResolvePath(path, _follow_last, _cancel_checker);
}

bool RarHelperHost::NeedsPathResolving() const noexcept
{
    return I->needs_path_resolving;
}

std::expected<void, Error> RarHelperHost::DoInit(const VFSCancelChecker &_cancel_checker)
{
    const std::expected<VFSStat, Error> st = Parent()->Stat(JunctionPath(), 0, _cancel_checker);
    if( !st )
        return std::unexpected(st.error());
    VFSStat::ToSysStat(*st, I->src_stat);

    const std::optional<std::string> helper = rar::FindHelper();
    if( !helper )
        return std::unexpected(Error{Error::POSIX, ENOENT});
    I->helper_path = *helper;
    I->archive_path = JunctionPath();
    I->password = Config().password;

    if( const std::expected<void, Error> rc = ReadListing(_cancel_checker); !rc )
        return rc;

    const auto root = I->path_to_dir.find("/");
    assert(root != I->path_to_dir.end());
    I->UpdateDirectorySize(root->second, "/");

    return {};
}

std::expected<void, Error> RarHelperHost::ReadListing(const VFSCancelChecker &_cancel_checker)
{
    const std::vector<std::string> args{"list", I->archive_path};
    std::expected<rar::ChildProcess, Error> process = rar::ChildProcess::Spawn(I->helper_path, args, I->password);
    if( !process )
        return std::unexpected(process.error());
    const auto terminate_process = at_scope_end([&] { process->Terminate(); });

    const std::expected<std::string, Error> output = ReadChildOutput(*process, _cancel_checker);
    if( !output )
        return std::unexpected(output.error());

    const std::expected<int, Error> exit_code = process->Wait();
    if( !exit_code )
        return std::unexpected(exit_code.error());
    if( *exit_code != 0 )
        return std::unexpected(rar::ErrorForHelperExitCode(*exit_code));

    const std::optional<rar::Listing> listing = rar::ParseListing(*output);
    if( !listing )
        return std::unexpected(Error{Error::POSIX, EFTYPE});
    if( !listing->done )
        return std::unexpected(Error{Error::POSIX, EFTYPE});

    // Match the behaviour of the libarchive host: an encrypted archive without a password is
    // reported as "needs authentication" so that the caller has a chance to ask for one.
    if( !I->password ) {
        const auto is_encrypted = [](const rar::Entry &_entry) { return _entry.encrypted; };
        if( std::ranges::any_of(listing->entries, is_encrypted) )
            return std::unexpected(Error{Error::POSIX, ENEEDAUTH});
    }

    BuildTree(*listing);
    return {};
}

void RarHelperHost::BuildTree(const rar::Listing &_listing)
{
    for( const rar::Entry &entry : _listing.entries ) {
        if( entry.components.empty() )
            continue;

        // Reject entries with paths that could escape the archive root - they can't be shown anyway.
        const auto is_special = [](const std::string &_component) { return _component == "." || _component == ".."; };
        if( std::ranges::any_of(entry.components, is_special) )
            continue;

        std::string path{"/"};
        for( const std::string &component : entry.components ) {
            if( path.size() > 1 )
                path += '/';
            path += component;
        }

        const std::string_view parent_path = utility::PathManip::Parent(path);
        const std::string_view name = utility::PathManip::Filename(path);
        if( parent_path.empty() || name.empty() )
            continue;

        Impl::DirRec *const parent_dir = I->FindOrBuildDir(parent_path);
        if( parent_dir == nullptr )
            continue; // skip entries with bogus paths

        Impl::EntryRec *rec = nullptr;
        for( Impl::EntryRec &existing : parent_dir->entries )
            if( existing.name == name ) {
                rec = &existing;
                break;
            }

        if( rec == nullptr ) {
            parent_dir->entries.emplace_back();
            rec = &parent_dir->entries.back();
            rec->name = name;
        }

        I->ApplyEntry(entry, *rec);

        if( entry.IsLink() )
            I->needs_path_resolving = true;

        if( entry.dir ) {
            std::string dir_path = path;
            dir_path += '/';
            if( !I->path_to_dir.contains(dir_path) ) {
                Impl::DirRec dir;
                dir.full_path = dir_path;
                I->path_to_dir.emplace(std::move(dir_path), std::move(dir));
            }
        }
    }
}

RarHelperHost::Impl::DirRec *RarHelperHost::Impl::FindDir(const std::string_view _path_with_tr_sl)
{
    const auto it = path_to_dir.find(_path_with_tr_sl);
    return it == path_to_dir.end() ? nullptr : &it->second;
}

RarHelperHost::Impl::DirRec *RarHelperHost::Impl::FindOrBuildDir(const std::string_view _path_with_tr_sl)
{
    assert(utility::PathManip::HasTrailingSlash(_path_with_tr_sl));
    if( DirRec *const existing = FindDir(_path_with_tr_sl) )
        return existing;

    const std::string_view parent_path = utility::PathManip::Parent(_path_with_tr_sl);
    const std::string_view entry_name = utility::PathManip::Filename(_path_with_tr_sl);
    if( parent_path.empty() || entry_name.empty() )
        return nullptr;

    DirRec *const parent_dir = FindOrBuildDir(parent_path);
    if( parent_dir == nullptr )
        return nullptr;

    InsertDummyDirInto(parent_dir, entry_name);

    DirRec dir;
    dir.full_path = std::string{_path_with_tr_sl};
    const auto it = path_to_dir.emplace(dir.full_path, std::move(dir));
    return &it.first->second;
}

void RarHelperHost::Impl::InsertDummyDirInto(DirRec *_parent, const std::string_view _dir_name)
{
    _parent->entries.emplace_back();
    EntryRec &entry = _parent->entries.back();
    entry.name = _dir_name;
    entry.is_dir = true;
    entry.st.meaning = VFSStat::AllMeaning();
    entry.st.mode = g_DirMode;
    entry.st.uid = src_stat.st_uid;
    entry.st.gid = src_stat.st_gid;
    entry.st.atime = entry.st.mtime = entry.st.ctime = entry.st.btime = src_stat.st_mtimespec;
}

const RarHelperHost::Impl::EntryRec *RarHelperHost::Impl::FindEntry(const std::string_view _path) const noexcept
{
    if( _path.empty() || _path[0] != '/' || _path == "/" )
        return nullptr; // we have no info about the root directory

    const std::string_view parent_path = utility::PathManip::Parent(_path);
    const std::string_view filename = utility::PathManip::Filename(_path);
    if( parent_path.empty() || filename.empty() )
        return nullptr;

    const auto dir = path_to_dir.find(parent_path);
    if( dir == path_to_dir.end() )
        return nullptr;

    for( const EntryRec &entry : dir->second.entries )
        if( entry.name == filename )
            return &entry;
    return nullptr;
}

RarHelperHost::Impl::EntryRec *RarHelperHost::Impl::FindEntryMutable(const std::string_view _path) noexcept
{
    return const_cast<EntryRec *>(std::as_const(*this).FindEntry(_path));
}

RarHelperHost::Impl::EntryRec *RarHelperHost::Impl::FindEntryInDir(const std::string_view _parent,
                                                                   const std::string_view _name) noexcept
{
    if( _parent.empty() || _parent[0] != '/' || _name.empty() )
        return nullptr;

    const std::string key = _parent == "/" ? std::string{"/"} : std::string{_parent} + "/";
    const auto dir = path_to_dir.find(key);
    if( dir == path_to_dir.end() )
        return nullptr;

    for( EntryRec &entry : dir->second.entries )
        if( entry.name == _name )
            return &entry;
    return nullptr;
}

std::expected<std::string, Error> RarHelperHost::Impl::LinkTarget(EntryRec &_entry,
                                                                  const VFSCancelChecker &_cancel_checker)
{
    {
        const std::lock_guard lock(link_target_mutex);
        if( _entry.link_target )
            return *_entry.link_target;
    }

    std::expected<std::string, Error> target =
        FetchLinkTargetOneShot(helper_path, archive_path, password, _entry.index, _cancel_checker);
    if( !target )
        return std::unexpected(target.error());

    {
        const std::lock_guard lock(link_target_mutex);
        _entry.link_target = *target;
    }
    return *target;
}

std::expected<std::string, Error> RarHelperHost::Impl::ResolvePath(const std::string_view _path,
                                                                   const bool _follow_last,
                                                                   const VFSCancelChecker &_cancel_checker)
{
    std::vector<std::string> pending = SplitArchivePath(_path);
    std::vector<std::string> resolved;
    unsigned hops = 0;

    while( !pending.empty() ) {
        std::string component = std::move(pending.front());
        pending.erase(pending.begin());

        if( component == "." )
            continue;
        if( component == ".." ) {
            if( !resolved.empty() )
                resolved.pop_back();
            continue;
        }

        const std::string parent = JoinArchivePath(resolved);
        EntryRec *const entry = FindEntryInDir(parent, component);
        if( entry == nullptr )
            return std::unexpected(Error{Error::POSIX, ENOENT});

        const bool last = pending.empty();
        if( entry->is_link && (!last || _follow_last) ) {
            if( ++hops > 40 )
                return std::unexpected(Error{Error::POSIX, ELOOP}); // a symlink loop

            const std::expected<std::string, Error> target = LinkTarget(*entry, _cancel_checker);
            if( !target )
                return std::unexpected(target.error());

            std::vector<std::string> target_components = SplitArchivePath(*target);
            if( target->starts_with('/') )
                resolved.clear(); // an absolute target is relative to the archive root
            pending.insert(pending.begin(), target_components.begin(), target_components.end());
            continue;
        }

        if( last ) {
            resolved.push_back(std::move(component));
            return JoinArchivePath(resolved);
        }
        if( !entry->is_dir )
            return std::unexpected(Error{Error::POSIX, ENOTDIR});

        resolved.push_back(std::move(component));
    }

    return JoinArchivePath(resolved);
}

uint64_t RarHelperHost::Impl::UpdateDirectorySize(DirRec &_directory, const std::string &_path)
{
    uint64_t size = 0;
    for( EntryRec &entry : _directory.entries )
        if( entry.is_dir ) {
            const std::string subdir_path = _path + entry.name + "/";
            if( const auto it = path_to_dir.find(subdir_path); it != path_to_dir.end() ) {
                const uint64_t subdir_size = UpdateDirectorySize(it->second, subdir_path);
                entry.st.size = subdir_size;
                size += subdir_size;
            }
        }
        else if( S_ISREG(entry.st.mode) )
            size += entry.st.size;

    _directory.content_size = size;
    return size;
}

void RarHelperHost::Impl::ApplyEntry(const rar::Entry &_entry, EntryRec &_rec)
{
    _rec.index = _entry.index;
    _rec.is_dir = _entry.dir;
    _rec.is_link = _entry.IsLink();
    _rec.link_target = _entry.link_target;

    _rec.st.meaning = VFSStat::AllMeaning();
    _rec.st.size = _entry.size;
    _rec.st.mode = ModeForEntry(_entry);

    time_t mtime = _entry.mtime;
    if( mtime == 0 )
        mtime = src_stat.st_mtimespec.tv_sec;
    const timespec time{.tv_sec = mtime, .tv_nsec = 0};
    _rec.st.atime = _rec.st.mtime = _rec.st.ctime = _rec.st.btime = time;
    _rec.st.uid = src_stat.st_uid;
    _rec.st.gid = src_stat.st_gid;
    _rec.st.nlink = 1;
}

std::optional<uint32_t> RarHelperHost::IndexForPath(const std::string_view _path) const noexcept
{
    const std::string path = NormalizeLookupPath(_path);
    if( const Impl::EntryRec *const entry = I->FindEntry(path) )
        return entry->index;
    return std::nullopt;
}

bool RarHelperHost::IsDirectory(std::string_view _path, unsigned long _flags, const VFSCancelChecker &_cancel_checker)
{
    if( _path.empty() || _path[0] != '/' )
        return false;

    std::string path = NormalizeLookupPath(_path);
    if( path == "/" )
        return true;

    if( I->needs_path_resolving && !(_flags & VFSFlags::F_NoFollow) ) {
        std::expected<std::string, Error> resolved = I->ResolvePath(path, true, _cancel_checker);
        if( !resolved )
            return false;
        path = std::move(*resolved);
    }

    std::string dir_path = path;
    dir_path += '/';
    return I->FindDir(dir_path) != nullptr;
}

std::expected<VFSStat, Error>
RarHelperHost::Stat(std::string_view _path, unsigned long _flags, const VFSCancelChecker &_cancel_checker)
{
    if( _path.empty() || _path[0] != '/' )
        return std::unexpected(Error{Error::POSIX, EINVAL});

    std::string path = NormalizeLookupPath(_path);
    if( path != "/" && I->needs_path_resolving && !(_flags & VFSFlags::F_NoFollow) ) {
        std::expected<std::string, Error> resolved = I->ResolvePath(path, true, _cancel_checker);
        if( !resolved )
            return std::unexpected(resolved.error());
        path = std::move(*resolved);
    }

    if( path == "/" ) {
        // We have no info about the root directory - invent a dummy one.
        VFSStat st;
        st.meaning = VFSStat::AllMeaning();
        st.mode = S_IRUSR | S_IXUSR | S_IFDIR;
        st.uid = I->src_stat.st_uid;
        st.gid = I->src_stat.st_gid;
        st.atime = st.mtime = st.ctime = st.btime = I->src_stat.st_mtimespec;
        return st;
    }

    if( const Impl::EntryRec *const entry = I->FindEntry(path) )
        return entry->st;

    return std::unexpected(Error{Error::POSIX, ENOENT});
}

std::expected<std::shared_ptr<VFSFile>, Error> RarHelperHost::CreateFile(std::string_view _path,
                                                                         const VFSCancelChecker &_cancel_checker)
{
    if( _path.empty() || _path[0] != '/' )
        return std::unexpected(Error{Error::POSIX, EINVAL});

    auto file = std::make_shared<rar::File>(_path, SharedPtr());
    if( _cancel_checker && _cancel_checker() )
        return std::unexpected(Error{Error::POSIX, ECANCELED});
    return file;
}

std::expected<VFSListingPtr, Error> RarHelperHost::FetchDirectoryListing(std::string_view _path,
                                                                         unsigned long _flags,
                                                                         const VFSCancelChecker &_cancel_checker)
{
    if( _path.empty() || _path[0] != '/' )
        return std::unexpected(Error{Error::POSIX, EINVAL});

    std::string dir_path = NormalizeLookupPath(_path);
    if( I->needs_path_resolving && dir_path != "/" && !(_flags & VFSFlags::F_NoFollow) ) {
        std::expected<std::string, Error> resolved = I->ResolvePath(dir_path, true, _cancel_checker);
        if( !resolved )
            return std::unexpected(resolved.error());
        dir_path = std::move(*resolved);
    }
    if( !dir_path.ends_with('/') )
        dir_path += '/';

    const Impl::DirRec *const directory = I->FindDir(dir_path);
    if( directory == nullptr )
        return std::unexpected(Error{Error::POSIX, ENOENT});

    using nc::base::variable_container;
    ListingInput listing_source;
    listing_source.hosts[0] = shared_from_this();
    listing_source.directories[0] = EnsureTrailingSlash(std::string(_path));
    listing_source.atimes.reset(variable_container<>::type::dense);
    listing_source.mtimes.reset(variable_container<>::type::dense);
    listing_source.ctimes.reset(variable_container<>::type::dense);
    listing_source.btimes.reset(variable_container<>::type::dense);
    listing_source.unix_flags.reset(variable_container<>::type::dense);
    listing_source.uids.reset(variable_container<>::type::dense);
    listing_source.gids.reset(variable_container<>::type::dense);
    listing_source.sizes.reset(variable_container<>::type::dense);
    listing_source.symlinks.reset(variable_container<>::type::sparse);

    if( !(_flags & VFSFlags::F_NoDotDot) ) {
        listing_source.filenames.emplace_back("..");
        listing_source.unix_types.emplace_back(DT_DIR);
        listing_source.unix_modes.emplace_back(S_IRUSR | S_IXUSR | S_IFDIR);
        const auto curtime = time(nullptr); // it's better to show date of archive itself
        listing_source.atimes.insert(0, curtime);
        listing_source.btimes.insert(0, curtime);
        listing_source.ctimes.insert(0, curtime);
        listing_source.mtimes.insert(0, curtime);
        listing_source.sizes.insert(0, directory->content_size);
        listing_source.uids.insert(0, 0);
        listing_source.gids.insert(0, 0);
        listing_source.unix_flags.insert(0, 0);
    }

    for( const Impl::EntryRec &entry : directory->entries ) {
        listing_source.filenames.emplace_back(entry.name);
        listing_source.unix_types.emplace_back(IFTODT(entry.st.mode));

        const int index = int(listing_source.filenames.size() - 1);
        listing_source.unix_modes.emplace_back(entry.st.mode);
        listing_source.sizes.insert(index, entry.st.size);
        listing_source.atimes.insert(index, entry.st.atime.tv_sec);
        listing_source.ctimes.insert(index, entry.st.ctime.tv_sec);
        listing_source.mtimes.insert(index, entry.st.mtime.tv_sec);
        listing_source.btimes.insert(index, entry.st.btime.tv_sec);
        listing_source.uids.insert(index, entry.st.uid);
        listing_source.gids.insert(index, entry.st.gid);
        listing_source.unix_flags.insert(index, entry.st.flags);
        if( entry.link_target )
            listing_source.symlinks.insert(index, *entry.link_target);
    }

    return VFSListing::Build(std::move(listing_source));
}

std::expected<void, Error>
RarHelperHost::IterateDirectoryListing(std::string_view _path,
                                       const std::function<bool(const VFSDirEnt &_dirent)> &_handler)
{
    if( _path.empty() || _path[0] != '/' || !_handler )
        return std::unexpected(Error{Error::POSIX, EINVAL});

    std::string dir_path = NormalizeLookupPath(_path);
    if( I->needs_path_resolving && dir_path != "/" ) {
        std::expected<std::string, Error> resolved = I->ResolvePath(dir_path, true, {});
        if( !resolved )
            return std::unexpected(resolved.error());
        dir_path = std::move(*resolved);
    }
    if( !dir_path.ends_with('/') )
        dir_path += '/';

    const Impl::DirRec *const directory = I->FindDir(dir_path);
    if( directory == nullptr )
        return std::unexpected(Error{Error::POSIX, ENOENT});

    for( const Impl::EntryRec &entry : directory->entries ) {
        VFSDirEnt dir;
        dir.name = entry.name;

        if( S_ISDIR(entry.st.mode) )
            dir.type = VFSDirEnt::Dir;
        else if( S_ISREG(entry.st.mode) )
            dir.type = VFSDirEnt::Reg;
        else if( S_ISLNK(entry.st.mode) )
            dir.type = VFSDirEnt::Link;
        else
            dir.type = VFSDirEnt::Unknown; // other stuff is not supported currently

        if( !_handler(dir) )
            break;
    }

    return {};
}

std::expected<std::string, Error> RarHelperHost::ReadSymlink(std::string_view _symlink_path,
                                                             const VFSCancelChecker &_cancel_checker)
{
    if( _symlink_path.empty() || _symlink_path[0] != '/' )
        return std::unexpected(Error{Error::POSIX, EINVAL});

    std::string link_path = NormalizeLookupPath(_symlink_path);
    if( I->needs_path_resolving && link_path != "/" ) {
        // Only the parent components are followed: looking up the link itself must yield a link.
        const std::string parent{utility::PathManip::Parent(link_path)};
        const std::string name{utility::PathManip::Filename(link_path)};
        if( parent.empty() || name.empty() )
            return std::unexpected(Error{Error::POSIX, ENOENT});

        std::expected<std::string, Error> resolved_parent = I->ResolvePath(parent, true, _cancel_checker);
        if( !resolved_parent )
            return std::unexpected(resolved_parent.error());
        link_path = *resolved_parent == "/" ? "/" + name : *resolved_parent + "/" + name;
    }

    Impl::EntryRec *const entry = I->FindEntryMutable(link_path);
    if( entry == nullptr )
        return std::unexpected(Error{Error::POSIX, ENOENT});
    if( !entry->is_link )
        return std::unexpected(Error{Error::POSIX, EINVAL});

    // RAR5 stores the target in the header, so the listing already has it. RAR4 keeps it in the
    // entry payload - the helper's "link" command recovers it on demand.
    return I->LinkTarget(*entry, _cancel_checker);
}

} // namespace nc::vfs
