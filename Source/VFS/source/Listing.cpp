// Copyright (C) 2015-2025 Michael Kazakov. Subject to GNU General Public License version 3.
#include "Listing.h"
#include "../include/VFS/Host.h"
#include "ListingInput.h"
#include <sys/param.h>
#include <Base/mach_time.h>
#include <cassert>
#include <chrono>
#include <cstdio>

namespace nc::vfs {

using nc::base::variable_container;

// static_assert(sizeof(Listing) <= 824); // became 944 on Xcode15 ???
static_assert(std::is_move_constructible_v<ListingItem>);
static_assert(std::is_move_constructible_v<Listing::iterator>);

static bool BasicDirectoryCheck(std::string_view _str) noexcept
{
    if( _str.empty() )
        return false;
    if( _str.back() != '/' )
        return false;
    return true;
}

static void Validate(const ListingInput &_source)
{
    const size_t items_no = _source.filenames.size();

    if( _source.hosts.mode() == variable_container<>::type::sparse )
        throw std::logic_error("VFSListingInput validation failed: hosts can't be sparse");

    for( auto i = size_t(0), e = _source.hosts.size(); i != e; ++i )
        if( _source.hosts[i] == nullptr )
            throw std::logic_error("VFSListingInput validation failed: host can't be nullptr");

    if( _source.directories.mode() == variable_container<>::type::sparse )
        throw std::logic_error("VFSListingInput validation failed: directories can't be sparse");

    for( auto i = size_t(0), e = _source.directories.size(); i != e; ++i )
        if( !BasicDirectoryCheck(_source.directories[i]) )
            throw std::logic_error("VFSListingInput validation failed: invalid directory");

    for( auto &s : _source.filenames )
        if( s.empty() )
            throw std::logic_error("VFSListingInput validation failed: filename can't be empty");

    if( _source.display_filenames.mode() == variable_container<>::type::common && items_no > 1 )
        throw std::logic_error("VFSListingInput validation failed: dispay_filenames can't be common");

    if( _source.sizes.mode() == variable_container<>::type::common && items_no > 1 )
        throw std::logic_error("VFSListingInput validation failed: sizes can't be common");

    if( _source.inodes.mode() == variable_container<>::type::common && items_no > 1 )
        throw std::logic_error("VFSListingInput validation failed: inodes can't be common");

    if( _source.symlinks.mode() == variable_container<>::type::common && items_no > 1 )
        throw std::logic_error("VFSListingInput validation failed: symlinks can't be common");

    if( _source.hosts.mode() == variable_container<>::type::dense && _source.hosts.size() != items_no )
        throw std::logic_error("VFSListingInput validation failed: hosts amount is inconsistent");

    if( _source.directories.mode() == variable_container<>::type::dense && _source.directories.size() != items_no )
        throw std::logic_error("VFSListingInput validation failed: directories amount is inconsistent");

    if( _source.unix_modes.size() != items_no )
        throw std::logic_error("VFSListingInput validation failed: unix_modes amount is inconsistent");

    if( _source.unix_types.size() != items_no )
        throw std::logic_error("VFSListingInput validation failed: unix_types amount is inconsistent");
}

template <class C>
static void CompressIntoContiguous(C &_cont)
{
    if( _cont.mode() == variable_container<>::type::sparse && _cont.is_contiguous() )
        _cont.compress_contiguous();
}

static void Compress(ListingInput &_input)
{
    CompressIntoContiguous(_input.sizes);
    CompressIntoContiguous(_input.inodes);
    CompressIntoContiguous(_input.atimes);
    CompressIntoContiguous(_input.mtimes);
    CompressIntoContiguous(_input.ctimes);
    CompressIntoContiguous(_input.btimes);
    CompressIntoContiguous(_input.add_times);
    CompressIntoContiguous(_input.uids);
    CompressIntoContiguous(_input.gids);
    CompressIntoContiguous(_input.unix_flags);

    // TODO: generalize and move this into variable_container itself?
    // Compress dense hosts into a common one if all are the same
    if( _input.hosts.mode() == variable_container<>::type::dense && !_input.hosts.empty() ) {
        const auto first = _input.hosts[0];
        bool allsame = true;
        for( size_t i = 1, e = _input.hosts.size(); i < e; ++i ) {
            if( _input.hosts[i] != first ) {
                allsame = false;
                break;
            }
        }
        if( allsame ) {
            _input.hosts = variable_container<VFSHostPtr>{first};
        }
    }
}

Listing::Listing() = default;

Listing::~Listing()
{
    if( !m_FilenamesCF )
        return;
    for( size_t i = 0, e = m_ItemsCount; i != e; ++i )
        if( const CFStringRef s = m_FilenamesCF[i].load(std::memory_order_relaxed); s != nullptr )
            CFRelease(s);
}

// Times are stored as 32-bit epoch seconds inside the listing - clamp whatever doesn't fit.
static int32_t ToCompactTime(const time_t _t) noexcept
{
    return static_cast<int32_t>(
        std::clamp<time_t>(_t, std::numeric_limits<int32_t>::min(), std::numeric_limits<int32_t>::max()));
}

static variable_container<int32_t> CompactTimes(const variable_container<time_t> &_src, const unsigned _count)
{
    const auto clamp = [](time_t _t) { return ToCompactTime(_t); };
    switch( _src.mode() ) {
        case variable_container<>::type::common:
            return variable_container<int32_t>(clamp(_src[0]));
        case variable_container<>::type::dense: {
            const auto src = _src.dense_values();
            // an empty dense container means "no such attribute" (e.g. a names-only listing)
            if( src.size() != _count )
                return variable_container<int32_t>(variable_container<>::type::sparse);
            variable_container<int32_t> dst(variable_container<>::type::dense);
            dst.resize(_count);
            auto values = dst.dense_values();
            for( size_t i = 0; i != values.size(); ++i )
                values[i] = clamp(src[i]);
            return dst;
        }
        case variable_container<>::type::sparse: {
            variable_container<int32_t> dst(variable_container<>::type::sparse);
            for( size_t i = 0; i != _count; ++i )
                if( _src.has(i) )
                    dst.insert(i, clamp(_src[i]));
            return dst;
        }
    }
    return variable_container<int32_t>(variable_container<>::type::sparse);
}

base::intrusive_ptr<const Listing> Listing::Build(ListingInput &&_input)
{
    using clock = std::chrono::steady_clock;
    const auto perf_begin = clock::now();
    Validate(_input); // will throw an exception on error
    const auto perf_validated = clock::now();
    Compress(_input);
    const auto perf_compressed = clock::now();

    auto l = base::intrusive_ptr<Listing>{new Listing};
    l->m_ItemsCount = static_cast<unsigned>(_input.filenames.size());
    l->m_Title = std::move(_input.title);
    l->m_Hosts = std::move(_input.hosts);
    l->m_Directories = std::move(_input.directories);
    l->m_Filenames = std::move(_input.filenames);
    // The enumerator grows its vectors geometrically, so a million-entry listing can carry tens of
    // percent of dead capacity. Trim it now that the final size is known - one copy of the data in
    // exchange for the resident memory.
    const auto trim = [](auto &_v) {
        if( _v.capacity() > _v.size() + _v.size() / 16 )
            _v.shrink_to_fit();
    };
    trim(l->m_Filenames);
    l->m_DisplayFilenames = std::move(_input.display_filenames);
    l->m_Sizes = std::move(_input.sizes);
    l->m_Inodes = std::move(_input.inodes);
    l->m_ATimes = CompactTimes(_input.atimes, l->m_ItemsCount);
    l->m_BTimes = CompactTimes(_input.btimes, l->m_ItemsCount);
    l->m_CTimes = CompactTimes(_input.ctimes, l->m_ItemsCount);
    l->m_MTimes = CompactTimes(_input.mtimes, l->m_ItemsCount);
    l->m_AddTimes = CompactTimes(_input.add_times, l->m_ItemsCount);
    l->m_UnixModes = std::move(_input.unix_modes);
    l->m_UnixTypes = std::move(_input.unix_types);
    trim(l->m_UnixModes);
    trim(l->m_UnixTypes);
    l->m_UIDS = std::move(_input.uids);
    l->m_GIDS = std::move(_input.gids);
    l->m_UnixFlags = std::move(_input.unix_flags);
    l->m_Symlinks = std::move(_input.symlinks);
    l->m_Tags = std::move(_input.tags);
    l->m_CreationTime = time(nullptr);
    l->m_CreationTicks = base::machtime();
    const auto perf_moved = clock::now();
    l->BuildFilenames();

    if( std::getenv("NC_PERF_LOG") != nullptr ) {
        using namespace std::chrono;
        const auto perf_end = clock::now();
        const auto ms = [](auto _from, auto _to) {
            return static_cast<double>(duration_cast<microseconds>(_to - _from).count()) / 1000.0;
        };
        std::fprintf(
            stderr,
            "[perf] build n=%u mem=%.1fMB validate=%.1fms compress=%.1fms move=%.1fms filenames=%.1fms total=%.1fms\n",
            l->m_ItemsCount,
            static_cast<double>(l->ApproximateMemoryFootprint()) / (1024.0 * 1024.0),
            ms(perf_begin, perf_validated),
            ms(perf_validated, perf_compressed),
            ms(perf_compressed, perf_moved),
            ms(perf_moved, perf_end),
            ms(perf_begin, perf_end));
    }

    return l;
}

base::intrusive_ptr<const Listing>
Listing::ProducePatchedListing(const Listing &_base,
                               std::span<const unsigned> _removed,
                               const std::vector<base::intrusive_ptr<const Listing>> &_appended)
{
    using nc::base::variable_container;
    const auto is_plain = [](const Listing &_l) {
        return _l.m_Symlinks.size() == 0 && _l.m_DisplayFilenames.size() == 0 && _l.m_Tags.empty();
    };
    const auto is_dense_or_common = [](const auto &_c) {
        return _c.mode() == variable_container<>::type::dense || _c.mode() == variable_container<>::type::common;
    };
    // An empty container simply means "the listing doesn't carry this attribute" (lazy dates) -
    // that's patchable, the result just stays empty.
    const auto is_patchable = [&](const auto &_c) { return _c.size() == 0 || is_dense_or_common(_c); };

    const auto bail = [](const char *_why) -> base::intrusive_ptr<const Listing> {
        if( std::getenv("NC_PERF_LOG") != nullptr )
            std::fprintf(stderr, "[perf] patch.fallback %s\n", _why);
        return nullptr;
    };
    if( !is_plain(_base) )
        return bail("base has extras");
    for( const auto &l : _appended )
        if( !l || !is_plain(*l) )
            return bail("appended has extras");
    // the uniform shape is the one that is worth patching in bulk
    if( _base.m_Hosts.mode() != variable_container<>::type::common ||
        _base.m_Directories.mode() != variable_container<>::type::common )
        return bail("not uniform");
    if( !is_patchable(_base.m_Sizes) || !is_patchable(_base.m_Inodes) || !is_patchable(_base.m_ATimes) ||
        !is_patchable(_base.m_MTimes) || !is_patchable(_base.m_CTimes) || !is_patchable(_base.m_BTimes) ||
        !is_patchable(_base.m_UIDS) || !is_patchable(_base.m_GIDS) || !is_patchable(_base.m_UnixFlags) )
        return bail("sparse attributes");

    unsigned appended_count = 0;
    for( const auto &l : _appended )
        appended_count += l->m_ItemsCount;
    const unsigned old_count = _base.m_ItemsCount;
    if( _removed.size() > old_count )
        return bail("removed more than there are");
    const unsigned new_count = old_count - static_cast<unsigned>(_removed.size()) + appended_count;
    const unsigned retained_count = new_count - appended_count;

    auto l = base::intrusive_ptr<Listing>{new Listing};
    l->m_ItemsCount = new_count;
    l->m_Title = _base.m_Title;
    l->m_CreationTime = _base.m_CreationTime;
    l->m_CreationTicks = base::machtime();
    l->m_Hosts = _base.m_Hosts;
    l->m_Directories = _base.m_Directories;
    l->m_DisplayFilenamesCF = variable_container<base::CFString>(variable_container<>::type::sparse);
    // the default-constructed containers are in the "common" mode with a single value - mark the
    // ones we don't fill as empty instead, so that the listing reports them as absent
    l->m_DisplayFilenames = variable_container<std::string>(variable_container<>::type::sparse);
    l->m_Symlinks = variable_container<std::string>(variable_container<>::type::sparse);
    if( _base.m_AddTimes.size() == 0 )
        l->m_AddTimes = variable_container<int32_t>(variable_container<>::type::sparse);

    l->m_Filenames = std::vector<std::string>(new_count);
    l->m_FilenamesCF = std::make_unique<std::atomic<CFStringRef>[]>(new_count);
    for( unsigned i = 0; i != new_count; ++i )
        l->m_FilenamesCF[i].store(nullptr, std::memory_order_relaxed);
    l->m_ExtensionOffsets = std::make_unique<uint16_t[]>(new_count);
    l->m_UnixModes = std::vector<mode_t>(new_count);
    l->m_UnixTypes = std::vector<uint8_t>(new_count);

    // the entry arrays that are stored as plain arrays
    unsigned dst = 0;
    size_t removed_pos = 0;
    for( unsigned src = 0; src != old_count; ++src ) {
        if( removed_pos < _removed.size() && _removed[removed_pos] == src ) {
            ++removed_pos;
            continue;
        }
        l->m_Filenames[dst] = _base.m_Filenames[src];
        l->m_ExtensionOffsets[dst] = _base.m_ExtensionOffsets[src];
        l->m_UnixModes[dst] = _base.m_UnixModes[src];
        l->m_UnixTypes[dst] = _base.m_UnixTypes[src];
        ++dst;
    }

    // the attribute containers are dense (or common) - copy them in bulk
    const auto patch_dense = [&](auto &_dst, const auto &_src) {
        using value_type = typename std::decay_t<decltype(_dst)>::value_type;
        if( _src.mode() == variable_container<>::type::common ) {
            _dst.reset(variable_container<>::type::dense);
            _dst.resize(new_count);
            std::ranges::fill(_dst.dense_values(), _src[0]);
            return;
        }
        const auto src_values = _src.dense_values();
        if( src_values.size() != old_count ) {
            // the listing doesn't actually carry this attribute for the entries
            _dst = variable_container<value_type>(variable_container<>::type::sparse);
            return;
        }
        _dst.reset(variable_container<>::type::dense);
        _dst.resize(new_count);
        auto dst_values = _dst.dense_values();
        unsigned d = 0;
        size_t rp = 0;
        for( unsigned s = 0; s != old_count; ++s ) {
            if( rp < _removed.size() && _removed[rp] == s ) {
                ++rp;
                continue;
            }
            dst_values[d++] = src_values[s];
        }
    };
    patch_dense(l->m_Sizes, _base.m_Sizes);
    patch_dense(l->m_Inodes, _base.m_Inodes);
    patch_dense(l->m_ATimes, _base.m_ATimes);
    patch_dense(l->m_MTimes, _base.m_MTimes);
    patch_dense(l->m_CTimes, _base.m_CTimes);
    patch_dense(l->m_BTimes, _base.m_BTimes);
    patch_dense(l->m_UIDS, _base.m_UIDS);
    patch_dense(l->m_GIDS, _base.m_GIDS);
    patch_dense(l->m_UnixFlags, _base.m_UnixFlags);
    if( _base.m_AddTimes.size() != 0 ) {
        if( !is_dense_or_common(_base.m_AddTimes) )
            return bail("sparse add times");
        patch_dense(l->m_AddTimes, _base.m_AddTimes);
    }

    // and now the appended entries - there are only a handful of them
    unsigned appended_dst = retained_count;
    for( const auto &app_listing : _appended ) {
        const Listing &al = *app_listing;
        for( unsigned i = 0; i != al.m_ItemsCount; ++i ) {
            l->m_Filenames[appended_dst] = al.m_Filenames[i];
            l->m_ExtensionOffsets[appended_dst] = al.m_ExtensionOffsets ? al.m_ExtensionOffsets[i] : 0;
            l->m_UnixModes[appended_dst] = al.m_UnixModes[i];
            l->m_UnixTypes[appended_dst] = al.m_UnixTypes[i];
            // only the attributes that the listing actually carries get written, the absent ones
            // stay absent
            if( l->m_Sizes.mode() == variable_container<>::type::dense )
                l->m_Sizes[appended_dst] = al.HasSize(i) ? al.Size(i) : uint64_t(-1);
            if( l->m_Inodes.mode() == variable_container<>::type::dense )
                l->m_Inodes[appended_dst] = al.HasInode(i) ? al.Inode(i) : 0;
            // the times may be absent from the base listing (lazy dates) - then only the ones the
            // appended entry actually carries are stored, sparsely
            const auto put_time = [&](auto &_dst, const bool _has, const auto _value) {
                if( _dst.mode() == variable_container<>::type::dense )
                    _dst[appended_dst] = ToCompactTime(_has ? _value : 0);
                else if( _has && _dst.mode() == variable_container<>::type::sparse )
                    _dst.insert(appended_dst, ToCompactTime(_value));
            };
            put_time(l->m_ATimes, al.HasATime(i), al.ATime(i));
            put_time(l->m_MTimes, al.HasMTime(i), al.MTime(i));
            put_time(l->m_CTimes, al.HasCTime(i), al.CTime(i));
            put_time(l->m_BTimes, al.HasBTime(i), al.BTime(i));
            if( l->m_UIDS.mode() == variable_container<>::type::dense )
                l->m_UIDS[appended_dst] = al.HasUID(i) ? al.UID(i) : 0;
            if( l->m_GIDS.mode() == variable_container<>::type::dense )
                l->m_GIDS[appended_dst] = al.HasGID(i) ? al.GID(i) : 0;
            if( l->m_UnixFlags.mode() == variable_container<>::type::dense )
                l->m_UnixFlags[appended_dst] = al.HasUnixFlags(i) ? al.UnixFlags(i) : 0;
            if( al.HasAddTime(i) ) {
                if( l->m_AddTimes.mode() == variable_container<>::type::dense )
                    l->m_AddTimes[appended_dst] = ToCompactTime(al.AddTime(i));
                else if( l->m_AddTimes.mode() == variable_container<>::type::sparse )
                    l->m_AddTimes.insert(appended_dst, ToCompactTime(al.AddTime(i)));
            }
            ++appended_dst;
        }
    }
    return l;
}

ListingInput Listing::Compose(const std::vector<base::intrusive_ptr<const Listing>> &_listings)
{
    ListingInput result;
    result.hosts.reset(variable_container<>::type::dense);
    result.directories.reset(variable_container<>::type::dense);
    result.display_filenames.reset(variable_container<>::type::sparse);
    result.sizes.reset(variable_container<>::type::sparse);
    result.inodes.reset(variable_container<>::type::sparse);
    result.atimes.reset(variable_container<>::type::sparse);
    result.mtimes.reset(variable_container<>::type::sparse);
    result.ctimes.reset(variable_container<>::type::sparse);
    result.btimes.reset(variable_container<>::type::sparse);
    result.add_times.reset(variable_container<>::type::sparse);
    result.uids.reset(variable_container<>::type::sparse);
    result.gids.reset(variable_container<>::type::sparse);
    result.unix_flags.reset(variable_container<>::type::sparse);
    result.symlinks.reset(variable_container<>::type::sparse);

    unsigned count = 0;
    for( auto &listing_ptr : _listings ) {
        auto &listing = *listing_ptr;
        for( unsigned i = 0, e = listing.Count(); i != e; ++i ) {
            result.filenames.emplace_back(listing.Filename(i));
            result.unix_modes.emplace_back(listing.UnixMode(i));
            result.unix_types.emplace_back(listing.UnixType(i));
            result.hosts.insert(count, listing.Host(i));
            result.directories.insert(count, listing.Directory(i));
            if( listing.HasDisplayFilename(i) )
                result.display_filenames.insert(count, listing.DisplayFilename(i));
            if( listing.HasSize(i) )
                result.sizes.insert(count, listing.Size(i));
            if( listing.HasInode(i) )
                result.inodes.insert(count, listing.Inode(i));
            if( listing.HasATime(i) )
                result.atimes.insert(count, listing.ATime(i));
            if( listing.HasBTime(i) )
                result.btimes.insert(count, listing.BTime(i));
            if( listing.HasCTime(i) )
                result.ctimes.insert(count, listing.CTime(i));
            if( listing.HasMTime(i) )
                result.mtimes.insert(count, listing.MTime(i));
            if( listing.HasAddTime(i) )
                result.add_times.insert(count, listing.AddTime(i));
            if( listing.HasUID(i) )
                result.uids.insert(count, listing.UID(i));
            if( listing.HasGID(i) )
                result.gids.insert(count, listing.GID(i));
            if( listing.HasUnixFlags(i) )
                result.unix_flags.insert(count, listing.UnixFlags(i));
            if( listing.HasSymlink(i) )
                result.symlinks.insert(count, listing.Symlink(i));
            if( listing.HasTags(i) ) {
                const auto tags = listing.Tags(i);
                result.tags.emplace(count, std::vector<utility::Tags::Tag>(tags.begin(), tags.end()));
            }
            count++;
        }
    }

    return result;
}

ListingInput Listing::Compose(const std::vector<base::intrusive_ptr<const Listing>> &_listings,
                              const std::vector<std::vector<unsigned>> &_items_indeces)
{
    if( _listings.size() != _items_indeces.size() )
        throw std::invalid_argument("VFSListing::Compose input containers has different sizes");

    ListingInput result;
    result.hosts.reset(variable_container<>::type::dense);
    result.directories.reset(variable_container<>::type::dense);
    result.display_filenames.reset(variable_container<>::type::sparse);
    result.sizes.reset(variable_container<>::type::sparse);
    result.inodes.reset(variable_container<>::type::sparse);
    result.atimes.reset(variable_container<>::type::sparse);
    result.mtimes.reset(variable_container<>::type::sparse);
    result.ctimes.reset(variable_container<>::type::sparse);
    result.btimes.reset(variable_container<>::type::sparse);
    result.add_times.reset(variable_container<>::type::sparse);
    result.uids.reset(variable_container<>::type::sparse);
    result.gids.reset(variable_container<>::type::sparse);
    result.unix_flags.reset(variable_container<>::type::sparse);
    result.symlinks.reset(variable_container<>::type::sparse);

    unsigned count = 0;
    for( size_t l = 0, e = _listings.size(); l != e; ++l ) {
        auto &listing = *_listings[l];
        auto &indeces = _items_indeces[l];
        for( const auto i : indeces ) {
            if( i >= listing.Count() )
                throw std::invalid_argument("VFSListing::Compose: invalid index");

            result.filenames.emplace_back(listing.Filename(i));
            result.unix_modes.emplace_back(listing.UnixMode(i));
            result.unix_types.emplace_back(listing.UnixType(i));
            result.hosts.insert(count, listing.Host(i));
            result.directories.insert(count, listing.Directory(i));
            if( listing.HasDisplayFilename(i) )
                result.display_filenames.insert(count, listing.DisplayFilename(i));
            if( listing.HasSize(i) )
                result.sizes.insert(count, listing.Size(i));
            if( listing.HasInode(i) )
                result.inodes.insert(count, listing.Inode(i));
            if( listing.HasATime(i) )
                result.atimes.insert(count, listing.ATime(i));
            if( listing.HasBTime(i) )
                result.btimes.insert(count, listing.BTime(i));
            if( listing.HasCTime(i) )
                result.ctimes.insert(count, listing.CTime(i));
            if( listing.HasMTime(i) )
                result.mtimes.insert(count, listing.MTime(i));
            if( listing.HasAddTime(i) )
                result.add_times.insert(count, listing.AddTime(i));
            if( listing.HasUID(i) )
                result.uids.insert(count, listing.UID(i));
            if( listing.HasGID(i) )
                result.gids.insert(count, listing.GID(i));
            if( listing.HasUnixFlags(i) )
                result.unix_flags.insert(count, listing.UnixFlags(i));
            if( listing.HasSymlink(i) )
                result.symlinks.insert(count, listing.Symlink(i));

            count++;
        }
    }

    return result;
}

VFSListingPtr Listing::ProduceUpdatedTemporaryPanelListing(const Listing &_original, VFSCancelChecker _cancel_checker)
{
    ListingInput result;
    unsigned count = 0;
    result.title = _original.Title();
    result.hosts.reset(variable_container<>::type::dense);
    result.directories.reset(variable_container<>::type::dense);
    result.display_filenames.reset(variable_container<>::type::sparse);
    result.sizes.reset(variable_container<>::type::sparse);
    result.inodes.reset(variable_container<>::type::sparse);
    result.atimes.reset(variable_container<>::type::sparse);
    result.mtimes.reset(variable_container<>::type::sparse);
    result.ctimes.reset(variable_container<>::type::sparse);
    result.btimes.reset(variable_container<>::type::sparse);
    result.uids.reset(variable_container<>::type::sparse);
    result.gids.reset(variable_container<>::type::sparse);
    result.unix_flags.reset(variable_container<>::type::sparse);
    result.symlinks.reset(variable_container<>::type::sparse);

    std::string path;
    for( unsigned i = 0, e = _original.Count(); i != e; ++i ) {
        if( _cancel_checker && _cancel_checker() )
            return nullptr;

        path.assign(_original.Directory(i));
        path.append(_original.Filename(i));

        const uint64_t stat_flags = _original.IsSymlink(i) ? VFSFlags::F_NoFollow : 0;
        if( const std::expected<VFSStat, Error> st = _original.Host(i)->Stat(path, stat_flags, _cancel_checker) ) {
            result.filenames.emplace_back(_original.Filename(i));
            result.unix_modes.emplace_back(_original.UnixMode(i));
            result.unix_types.emplace_back(_original.UnixType(i));
            result.hosts.insert(count, _original.Host(i));
            result.directories.insert(count, _original.Directory(i));

            if( st->meaning.size )
                result.sizes.insert(count, st->size);
            if( st->meaning.inode )
                result.inodes.insert(count, st->inode);
            if( st->meaning.atime )
                result.atimes.insert(count, st->atime.tv_sec);
            if( st->meaning.btime )
                result.btimes.insert(count, st->btime.tv_sec);
            if( st->meaning.ctime )
                result.ctimes.insert(count, st->ctime.tv_sec);
            if( st->meaning.mtime )
                result.mtimes.insert(count, st->mtime.tv_sec);
            if( st->meaning.uid )
                result.uids.insert(count, st->uid);
            if( st->meaning.gid )
                result.gids.insert(count, st->gid);
            if( st->meaning.flags )
                result.unix_flags.insert(count, st->flags);

            // mb update symlink too?
            if( _original.HasSymlink(i) )
                result.symlinks.insert(count, _original.Symlink(i));
            if( _original.HasDisplayFilename(i) )
                result.display_filenames.insert(count, _original.DisplayFilename(i));

            count++;
        }
    }

    if( _cancel_checker && _cancel_checker() )
        return nullptr;

    return Build(std::move(result));
}

const base::intrusive_ptr<const Listing> &Listing::EmptyListing() noexcept
{
    [[clang::no_destroy]] static const base::intrusive_ptr<const Listing> empty = [] {
        auto l = base::intrusive_ptr{new Listing};
        l->m_ItemsCount = 0;
        l->m_Hosts.insert(0, Host::DummyHost());
        l->m_Directories.insert(0, "/");
        return l;
    }();
    return empty;
}

static base::CFString UTF8WithFallback(const std::string &_s)
{
    base::CFString s(_s);
    if( !s )
        s = base::CFString(_s, kCFStringEncodingMacRoman);
    return s;
}

void Listing::BuildFilenames()
{
    size_t i = 0;
    const size_t e = m_ItemsCount;

    m_FilenamesCF = std::make_unique<std::atomic<CFStringRef>[]>(e);
    for( size_t n = 0; n != e; ++n )
        m_FilenamesCF[n].store(nullptr, std::memory_order_relaxed);
    m_ExtensionOffsets = std::make_unique<uint16_t[]>(e);
    m_DisplayFilenamesCF = variable_container<base::CFString>(variable_container<>::type::sparse);

    for( ; i != e; ++i ) {
        const auto &current = m_Filenames[i];

        // NB: the filenames are not bridged into CFStrings here - that happens lazily in
        // FilenameCF(), see the comment in the header. Display names are few, so they are built
        // eagerly.
        if( m_DisplayFilenames.has(static_cast<unsigned>(i)) )
            m_DisplayFilenamesCF.insert(static_cast<unsigned>(i),
                                        UTF8WithFallback(m_DisplayFilenames[static_cast<unsigned>(i)]));

        // parse extension if any
        // here we skip possible cases like
        // filename. and .filename
        // in such cases we think there's no extension at all
        uint16_t offset = 0;
        const auto dot_it = current.find_last_of('.');
        if( dot_it != std::string::npos && dot_it != 0 && dot_it != current.size() - 1 )
            offset = uint16_t(dot_it + 1);
        m_ExtensionOffsets[i] = offset;
    }
}

std::chrono::nanoseconds Listing::BuildTicksTimestamp() const noexcept
{
    return m_CreationTicks;
}

#define VFS_LISTING_CHECK_BOUNDS(a)                                                                                    \
    if( (a) >= m_ItemsCount ) [[unlikely]]                                                                             \
        throw std::out_of_range(std::string(__PRETTY_FUNCTION__) + ": index out of range");

bool Listing::HasExtension(unsigned _ind) const
{
    VFS_LISTING_CHECK_BOUNDS(_ind);
    return m_ExtensionOffsets[_ind] != 0;
}

uint16_t Listing::ExtensionOffset(unsigned _ind) const
{
    VFS_LISTING_CHECK_BOUNDS(_ind);
    return m_ExtensionOffsets[_ind];
}

const char *Listing::Extension(unsigned _ind) const
{
    VFS_LISTING_CHECK_BOUNDS(_ind);
    return m_Filenames[_ind].c_str() + m_ExtensionOffsets[_ind];
}

const std::string &Listing::Filename(unsigned _ind) const
{
    VFS_LISTING_CHECK_BOUNDS(_ind);
    return m_Filenames[_ind];
}

CFStringRef Listing::FilenameCF(unsigned _ind) const
{
    VFS_LISTING_CHECK_BOUNDS(_ind);
    if( const CFStringRef cached = m_FilenamesCF[_ind].load(std::memory_order_acquire); cached != nullptr )
        return cached;
    return MaterializeFilenameCF(_ind);
}

CFStringRef Listing::MaterializeFilenameCF(unsigned _ind) const
{
    const std::lock_guard<std::mutex> lock(m_FilenamesCFLock);
    if( const CFStringRef cached = m_FilenamesCF[_ind].load(std::memory_order_relaxed); cached != nullptr )
        return cached;
    // if the filename is badly broken and UTF8 is invalid - treat it like MacRoman encoding
    const base::CFString created = UTF8WithFallback(m_Filenames[_ind]);
    if( !created )
        return nullptr;
    const CFStringRef raw = *created;
    CFRetain(raw); // the array takes its own reference
    m_FilenamesCF[_ind].store(raw, std::memory_order_release);
    return raw;
}

std::string Listing::Path(unsigned _ind) const
{
    VFS_LISTING_CHECK_BOUNDS(_ind);
    if( !IsDotDot(_ind) )
        return m_Directories[_ind] + m_Filenames[_ind];
    else {
        std::string p = m_Directories[_ind];
        if( p.length() > 1 )
            p.pop_back();
        return p;
    }
}

std::string Listing::FilenameWithoutExt(unsigned _ind) const
{
    VFS_LISTING_CHECK_BOUNDS(_ind);
    if( m_ExtensionOffsets[_ind] == 0 )
        return m_Filenames[_ind];
    return m_Filenames[_ind].substr(0, m_ExtensionOffsets[_ind] - 1);
}

const VFSHostPtr &Listing::Host() const
{
    if( HasCommonHost() )
        return m_Hosts[0];
    throw std::logic_error("Listing::Host() called for listing with no common host");
}

const VFSHostPtr &Listing::Host(unsigned _ind) const
{
    if( HasCommonHost() )
        return m_Hosts[0];
    else {
        VFS_LISTING_CHECK_BOUNDS(_ind);
        return m_Hosts[_ind];
    }
}

const std::string &Listing::Directory() const
{
    if( HasCommonDirectory() )
        return m_Directories[0];
    throw std::logic_error("Listing::Directory() called for listing with no common directory");
}

const std::string &Listing::Directory(unsigned _ind) const
{
    if( HasCommonDirectory() ) {
        return m_Directories[0];
    }
    else {
        VFS_LISTING_CHECK_BOUNDS(_ind);
        return m_Directories[_ind];
    }
}

unsigned Listing::Count() const noexcept
{
    return m_ItemsCount;
};

bool Listing::Empty() const noexcept
{
    return m_ItemsCount == 0;
}

bool Listing::IsUniform() const noexcept
{
    return HasCommonHost() && HasCommonDirectory();
}

const std::string &Listing::Title() const noexcept
{
    return m_Title;
}

bool Listing::HasCommonHost() const noexcept
{
    return m_Hosts.mode() == base::variable_container<>::type::common;
}

bool Listing::HasCommonDirectory() const noexcept
{
    return m_Directories.mode() == base::variable_container<>::type::common;
}

bool Listing::HasSize(unsigned _ind) const
{
    VFS_LISTING_CHECK_BOUNDS(_ind);
    return m_Sizes.has(_ind);
}

uint64_t Listing::Size(unsigned _ind) const
{
    VFS_LISTING_CHECK_BOUNDS(_ind);
    return m_Sizes.has(_ind) ? m_Sizes[_ind] : 0;
}

bool Listing::HasInode(unsigned _ind) const
{
    VFS_LISTING_CHECK_BOUNDS(_ind);
    return m_Inodes.has(_ind);
}

uint64_t Listing::Inode(unsigned _ind) const
{
    VFS_LISTING_CHECK_BOUNDS(_ind);
    return m_Inodes.has(_ind) ? m_Inodes[_ind] : 0;
}

bool Listing::HasATime(unsigned _ind) const
{
    VFS_LISTING_CHECK_BOUNDS(_ind);
    return m_ATimes.has(_ind);
}

time_t Listing::ATime(unsigned _ind) const
{
    VFS_LISTING_CHECK_BOUNDS(_ind);
    return m_ATimes.has(_ind) ? static_cast<time_t>(m_ATimes[_ind]) : m_CreationTime;
}

bool Listing::HasMTime(unsigned _ind) const
{
    VFS_LISTING_CHECK_BOUNDS(_ind);
    return m_MTimes.has(_ind);
}

time_t Listing::MTime(unsigned _ind) const
{
    VFS_LISTING_CHECK_BOUNDS(_ind);
    return m_MTimes.has(_ind) ? static_cast<time_t>(m_MTimes[_ind]) : m_CreationTime;
}

bool Listing::HasCTime(unsigned _ind) const
{
    VFS_LISTING_CHECK_BOUNDS(_ind);
    return m_CTimes.has(_ind);
}

time_t Listing::CTime(unsigned _ind) const
{
    VFS_LISTING_CHECK_BOUNDS(_ind);
    return m_CTimes.has(_ind) ? static_cast<time_t>(m_CTimes[_ind]) : m_CreationTime;
}

bool Listing::HasBTime(unsigned _ind) const
{
    VFS_LISTING_CHECK_BOUNDS(_ind);
    return m_BTimes.has(_ind);
}

time_t Listing::BTime(unsigned _ind) const
{
    VFS_LISTING_CHECK_BOUNDS(_ind);
    return m_BTimes.has(_ind) ? static_cast<time_t>(m_BTimes[_ind]) : m_CreationTime;
}

bool Listing::HasAddTime(unsigned _ind) const
{
    VFS_LISTING_CHECK_BOUNDS(_ind);
    return m_AddTimes.has(_ind);
}

time_t Listing::AddTime(unsigned _ind) const
{
    VFS_LISTING_CHECK_BOUNDS(_ind);
    return m_AddTimes.has(_ind) ? static_cast<time_t>(m_AddTimes[_ind]) : BTime(_ind);
}

mode_t Listing::UnixMode(unsigned _ind) const
{
    VFS_LISTING_CHECK_BOUNDS(_ind);
    return m_UnixModes[_ind];
}

uint8_t Listing::UnixType(unsigned _ind) const
{
    VFS_LISTING_CHECK_BOUNDS(_ind);
    return m_UnixTypes[_ind];
}

bool Listing::HasUID(unsigned _ind) const
{
    VFS_LISTING_CHECK_BOUNDS(_ind);
    return m_UIDS.has(_ind);
}

uid_t Listing::UID(unsigned _ind) const
{
    VFS_LISTING_CHECK_BOUNDS(_ind);
    return m_UIDS.has(_ind) ? m_UIDS[_ind] : 0;
}

bool Listing::HasGID(unsigned _ind) const
{
    VFS_LISTING_CHECK_BOUNDS(_ind);
    return m_GIDS.has(_ind);
}

gid_t Listing::GID(unsigned _ind) const
{
    VFS_LISTING_CHECK_BOUNDS(_ind);
    return m_GIDS.has(_ind) ? m_GIDS[_ind] : 0;
}

bool Listing::HasUnixFlags(unsigned _ind) const
{
    VFS_LISTING_CHECK_BOUNDS(_ind);
    return m_UnixFlags.has(_ind);
}

uint32_t Listing::UnixFlags(unsigned _ind) const
{
    VFS_LISTING_CHECK_BOUNDS(_ind);
    return m_UnixFlags.has(_ind) ? m_UnixFlags[_ind] : 0;
}

bool Listing::HasSymlink(unsigned _ind) const
{
    VFS_LISTING_CHECK_BOUNDS(_ind);
    return m_Symlinks.has(_ind);
}

const std::string &Listing::Symlink(unsigned _ind) const
{
    [[clang::no_destroy]] static const std::string st;
    VFS_LISTING_CHECK_BOUNDS(_ind);
    return m_Symlinks.has(_ind) ? m_Symlinks[_ind] : st;
}

bool Listing::HasTags(unsigned _ind) const
{
    VFS_LISTING_CHECK_BOUNDS(_ind);
    return m_Tags.contains(_ind);
}

std::span<const utility::Tags::Tag> Listing::Tags(unsigned _ind) const
{
    VFS_LISTING_CHECK_BOUNDS(_ind);
    if( const auto it = m_Tags.find(_ind); it != m_Tags.end() )
        return it->second;
    return {};
}

bool Listing::HasDisplayFilename(unsigned _ind) const
{
    VFS_LISTING_CHECK_BOUNDS(_ind);
    return m_DisplayFilenames.has(_ind);
}

size_t Listing::ApproximateMemoryFootprint() const noexcept
{
    using nc::base::variable_container;
    const auto container_bytes = [](const auto &_c, const size_t _element_size) -> size_t {
        switch( _c.mode() ) {
            case variable_container<>::type::dense:
                return _c.dense_values().size() * _element_size;
            case variable_container<>::type::sparse:
                return _c.size() * (_element_size + 32); // a rough per-node overhead of the map
            case variable_container<>::type::common:
                return _element_size;
        }
        return 0;
    };

    size_t total = sizeof(Listing);
    total += m_Title.capacity();
    total += m_Filenames.capacity() * sizeof(std::string);
    total += m_FilenamesCF ? static_cast<size_t>(m_ItemsCount) * sizeof(std::atomic<CFStringRef>) : 0;
    total += m_ExtensionOffsets ? static_cast<size_t>(m_ItemsCount) * sizeof(uint16_t) : 0;
    total += m_UnixModes.capacity() * sizeof(mode_t);
    total += m_UnixTypes.capacity() * sizeof(uint8_t);
    total += container_bytes(m_Hosts, sizeof(VFSHostPtr));
    total += container_bytes(m_Directories, sizeof(std::string));
    total += container_bytes(m_Sizes, sizeof(uint64_t));
    total += container_bytes(m_Inodes, sizeof(uint64_t));
    total += container_bytes(m_ATimes, sizeof(int32_t));
    total += container_bytes(m_MTimes, sizeof(int32_t));
    total += container_bytes(m_CTimes, sizeof(int32_t));
    total += container_bytes(m_BTimes, sizeof(int32_t));
    total += container_bytes(m_AddTimes, sizeof(int32_t));
    total += container_bytes(m_UIDS, sizeof(uid_t));
    total += container_bytes(m_GIDS, sizeof(gid_t));
    total += container_bytes(m_UnixFlags, sizeof(uint32_t));
    total += container_bytes(m_Symlinks, sizeof(std::string));
    total += container_bytes(m_DisplayFilenames, sizeof(std::string));
    total += container_bytes(m_DisplayFilenamesCF, sizeof(base::CFString));
    return total;
}

bool Listing::HasAnyTimes() const noexcept
{
    return m_ATimes.size() != 0 || m_MTimes.size() != 0 || m_CTimes.size() != 0 || m_BTimes.size() != 0;
}

bool Listing::HasAnyDisplayFilenames() const noexcept
{
    return m_DisplayFilenames.size() != 0;
}

bool Listing::HasAnyAddTimes() const noexcept
{
    return m_AddTimes.size() != 0;
}

bool Listing::HasAnySymlinks() const noexcept
{
    return m_Symlinks.size() != 0;
}

bool Listing::HasAnyTags() const noexcept
{
    return !m_Tags.empty();
}

const std::string &Listing::DisplayFilename(unsigned _ind) const
{
    VFS_LISTING_CHECK_BOUNDS(_ind);
    return m_DisplayFilenames.has(_ind) ? m_DisplayFilenames[_ind] : Filename(_ind);
}

CFStringRef Listing::DisplayFilenameCF(unsigned _ind) const
{
    VFS_LISTING_CHECK_BOUNDS(_ind);
    return m_DisplayFilenamesCF.has(_ind) ? *m_DisplayFilenamesCF[_ind] : FilenameCF(_ind);
}

bool Listing::IsDotDot(unsigned _ind) const
{
    VFS_LISTING_CHECK_BOUNDS(_ind);
    auto &s = m_Filenames[_ind];
    return s[0] == '.' && s[1] == '.' && s[2] == 0;
}

bool Listing::IsDir(unsigned _ind) const
{
    VFS_LISTING_CHECK_BOUNDS(_ind);
    return (m_UnixModes[_ind] & m_S_IFMT) == m_S_IFDIR;
}

bool Listing::IsReg(unsigned _ind) const
{
    VFS_LISTING_CHECK_BOUNDS(_ind);
    return (m_UnixModes[_ind] & m_S_IFMT) == m_S_IFREG;
}

bool Listing::IsSymlink(unsigned _ind) const
{
    VFS_LISTING_CHECK_BOUNDS(_ind);
    return m_UnixTypes[_ind] == m_DT_LNK;
}

bool Listing::IsHidden(unsigned _ind) const
{
    VFS_LISTING_CHECK_BOUNDS(_ind);
    return (Filename(_ind)[0] == '.' || (UnixFlags(_ind) & m_UF_HIDDEN)) && !IsDotDot(_ind);
}

ListingItem Listing::Item(unsigned _ind) const
{
    VFS_LISTING_CHECK_BOUNDS(_ind);
    return {base::intrusive_ptr{this}, _ind};
}

Listing::iterator Listing::begin() const noexcept
{
    iterator it;
    it.i = ListingItem(base::intrusive_ptr{this}, 0);
    return it;
}

Listing::iterator Listing::end() const noexcept
{
    iterator it;
    it.i = ListingItem(base::intrusive_ptr{this}, m_ItemsCount);
    return it;
}

#undef VFS_LISTING_CHECK_BOUNDS

ListingItem::ListingItem() noexcept : L(nullptr), I(std::numeric_limits<unsigned>::max())
{
}

ListingItem::ListingItem(const base::intrusive_ptr<const class Listing> &_listing, unsigned _ind) noexcept
    : L(_listing), I(_ind)
{
}

ListingItem::operator bool() const noexcept
{
    return static_cast<bool>(L);
}

const base::intrusive_ptr<const Listing> &ListingItem::Listing() const noexcept
{
    return L;
}

unsigned ListingItem::Index() const noexcept
{
    return I;
}

std::string ListingItem::Path() const
{
    return L->Path(I);
}

const VFSHostPtr &ListingItem::Host() const
{
    return L->Host(I);
}

const std::string &ListingItem::Directory() const
{
    return L->Directory(I);
}

const std::string &ListingItem::Filename() const
{
    return L->Filename(I);
}

const char *ListingItem::FilenameC() const
{
    return L->Filename(I).c_str();
}

size_t ListingItem::FilenameLen() const
{
    return L->Filename(I).length();
}

CFStringRef ListingItem::FilenameCF() const
{
    return L->FilenameCF(I);
}

bool ListingItem::HasDisplayName() const
{
    return L->HasDisplayFilename(I);
}

const std::string &ListingItem::DisplayName() const
{
    return L->DisplayFilename(I);
}

CFStringRef ListingItem::DisplayNameCF() const
{
    return L->DisplayFilenameCF(I);
}

bool ListingItem::HasExtension() const
{
    return L->HasExtension(I);
}

uint16_t ListingItem::ExtensionOffset() const
{
    return L->ExtensionOffset(I);
}

const char *ListingItem::Extension() const
{
    return L->Extension(I);
}

const char *ListingItem::ExtensionIfAny() const
{
    return HasExtension() ? Extension() : "";
}

std::string ListingItem::FilenameWithoutExt() const
{
    return L->FilenameWithoutExt(I);
}

mode_t ListingItem::UnixMode() const
{
    return L->UnixMode(I);
}

uint8_t ListingItem::UnixType() const
{
    return L->UnixType(I);
}

bool ListingItem::HasSize() const
{
    return L->HasSize(I);
}

uint64_t ListingItem::Size() const
{
    return L->Size(I);
}

bool ListingItem::HasInode() const
{
    return L->HasInode(I);
}

uint64_t ListingItem::Inode() const
{
    return L->Inode(I);
}

bool ListingItem::HasATime() const
{
    return L->HasATime(I);
}

time_t ListingItem::ATime() const
{
    return L->ATime(I);
}

bool ListingItem::HasMTime() const
{
    return L->HasMTime(I);
}

time_t ListingItem::MTime() const
{
    return L->MTime(I);
}

bool ListingItem::HasCTime() const
{
    return L->HasCTime(I);
}

time_t ListingItem::CTime() const
{
    return L->CTime(I);
}

bool ListingItem::HasBTime() const
{
    return L->HasBTime(I);
}

time_t ListingItem::BTime() const
{
    return L->BTime(I);
}

bool ListingItem::HasAddTime() const
{
    return L->HasAddTime(I);
}

time_t ListingItem::AddTime() const
{
    return L->AddTime(I);
}

bool ListingItem::HasUnixFlags() const
{
    return L->HasUnixFlags(I);
}

uint32_t ListingItem::UnixFlags() const
{
    return L->UnixFlags(I);
}

bool ListingItem::HasUnixUID() const
{
    return L->HasUID(I);
}

uid_t ListingItem::UnixUID() const
{
    return L->UID(I);
}

bool ListingItem::HasUnixGID() const
{
    return L->HasGID(I);
}

gid_t ListingItem::UnixGID() const
{
    return L->GID(I);
}

bool ListingItem::HasSymlink() const
{
    return L->HasSymlink(I);
}

const std::string &ListingItem::Symlink() const
{
    return L->Symlink(I);
}

bool ListingItem::HasTags() const
{
    return L->HasTags(I);
}

std::span<const utility::Tags::Tag> ListingItem::Tags() const
{
    return L->Tags(I);
}

bool ListingItem::IsDir() const
{
    return L->IsDir(I);
}

bool ListingItem::IsReg() const
{
    return L->IsReg(I);
}

bool ListingItem::IsSymlink() const
{
    return L->IsSymlink(I);
}

bool ListingItem::IsDotDot() const
{
    return L->IsDotDot(I);
}

bool ListingItem::IsHidden() const
{
    return L->IsHidden(I);
}

bool ListingItem::operator==(const ListingItem &_) const noexcept
{
    return I == _.I && L == _.L;
}

bool ListingItem::operator!=(const ListingItem &_) const noexcept
{
    return I != _.I || L != _.L;
}

Listing::iterator &Listing::iterator::operator--() noexcept // prefix decrement
{
    i.I--;
    return *this;
}

Listing::iterator &Listing::iterator::operator++() noexcept // prefix increment
{
    i.I++;
    return *this;
}

Listing::iterator Listing::iterator::operator--(int) noexcept // posfix decrement
{
    auto p = *this;
    i.I--;
    return p;
}

Listing::iterator Listing::iterator::operator++(int) noexcept // posfix increment
{
    auto p = *this;
    i.I++;
    return p;
}

Listing::iterator Listing::iterator::operator+(long _diff) const noexcept
{
    auto p = *this;
    p.i.I += _diff;
    return p;
}

Listing::iterator Listing::iterator::operator-(long _diff) const noexcept
{
    auto p = *this;
    p.i.I -= _diff;
    return p;
}

long Listing::iterator::operator-(const iterator &_rhs) const noexcept
{
    return static_cast<long>(i.I) - static_cast<long>(_rhs.i.I);
}

Listing::iterator &Listing::iterator::operator+=(long _diff) noexcept
{
    i.I += _diff;
    return *this;
}

Listing::iterator &Listing::iterator::operator-=(long _diff) noexcept
{
    i.I -= _diff;
    return *this;
}

bool Listing::iterator::operator==(const iterator &_r) const noexcept
{
    return i.I == _r.i.I && i.L == _r.i.L;
}

bool Listing::iterator::operator!=(const iterator &_r) const noexcept
{
    return !(*this == _r);
}

bool Listing::iterator::operator<(const iterator &_r) const noexcept
{
    return i.I < _r.i.I;
}

bool Listing::iterator::operator<=(const iterator &_r) const noexcept
{
    return i.I <= _r.i.I;
}

bool Listing::iterator::operator>(const iterator &_r) const noexcept
{
    return i.I > _r.i.I;
}

bool Listing::iterator::operator>=(const iterator &_r) const noexcept
{
    return i.I >= _r.i.I;
}

const ListingItem &Listing::iterator::operator*() const noexcept
{
    return i;
}

} // namespace nc::vfs
