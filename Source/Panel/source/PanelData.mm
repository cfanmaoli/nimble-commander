// Copyright (C) 2013-2024 Michael Kazakov. Subject to GNU General Public License version 3.
#include "PanelData.h"
#include "Log.h"
#include "PanelDataEntriesComparator.h"
#include "PanelDataExternalEntryKey.h"
#include "PanelDataItemVolatileData.h"
#include <Base/DispatchGroup.h>
#include <VFS/VFS.h>
#include <algorithm>
#include <magic_enum.hpp>
#include <numeric>
#include <pstld/pstld.h>
#include <chrono>
#include <cstdio>

namespace nc::panel::data {

// Don't bother with parallelism unless we have at least 10'000 items in a listing
constexpr inline size_t g_ParallelSortThresh = 10'000;

static void DoRawSort(const VFSListing &_from, std::vector<unsigned> &_to);

static inline SortMode DefaultSortMode()
{
    SortMode mode;
    mode.sep_dirs = true;
    mode.sort = SortMode::SortByName;
    return mode;
}

// returned string IS NOT NULL TERMINATED and MAY CONTAIN ZEROES INSIDE
// a bit overkill, need to consider some simplier kind of keys
static std::string LongEntryKey(const VFSListing &_l, unsigned _i)
{
    // host + dir + filename
    union {
        void *v;
        char b[sizeof(void *)];
    } host_addr;
    host_addr.v = _l.Host(_i).get();

    auto &directory = _l.Directory(_i);
    auto &filename = _l.Filename(_i);

    std::string key;
    key.reserve(sizeof(host_addr) + directory.size() + filename.size() + 1);
    key.append(std::begin(host_addr.b), std::end(host_addr.b));
    key.append(directory);
    key.append(filename);
    return key;
}

static std::vector<std::string> ProduceLongKeysForListing(const VFSListing &_l)
{
    std::vector<std::string> keys;
    keys.reserve(_l.Count());
    for( unsigned i = 0, e = _l.Count(); i != e; ++i )
        keys.emplace_back(LongEntryKey(_l, i));
    return keys;
}

static std::vector<unsigned> ProduceSortedIndirectIndecesForLongKeys(const std::vector<std::string> &_keys)
{
    std::vector<unsigned> src_keys_ind(_keys.size());
    std::ranges::iota(src_keys_ind, 0);
    std::ranges::sort(src_keys_ind, [&_keys](auto _1, auto _2) { return _keys[_1] < _keys[_2]; });
    return src_keys_ind;
}

Model::Model() : m_Listing(VFSListing::EmptyListing()), m_CustomSortMode(DefaultSortMode())
{
}

Model::Model(const Model &) = default;

Model::Model(Model &&) noexcept = default;

Model::~Model() = default;

Model &Model::operator=(const Model &) = default;

Model &Model::operator=(Model &&) noexcept = default;

bool Model::IsLoaded() const noexcept
{
    return m_Listing != VFSListing::EmptyListing();
}

static void InitVolatileDataWithListing(std::vector<ItemVolatileData> &_vd, const VFSListing &_listing)
{
    _vd.clear();
    _vd.resize(_listing.Count());
    for( unsigned i = 0, e = _listing.Count(); i != e; ++i ) {
        if( _listing.IsDir(i) ) {
            if( _listing.HasSize(i) ) {
                const auto sz = _listing.Size(i);
                if( sz != std::numeric_limits<uint64_t>::max() )
                    _vd[i].size = sz;
            }
        }
        else if( _listing.HasSize(i) ) {
            // the listings built with F_NamesOnly simply don't have the sizes
            _vd[i].size = _listing.Size(i);
        }
    }
}

Model::PreparedLoad Model::PrepareLoad(const VFSListingPtr &_listing,
                                       PanelType _type,
                                       struct SortMode _sort_mode,
                                       HardFilter _hard_filtering,
                                       TextualFilter _soft_filtering)
{
    if( !_listing )
        throw std::logic_error("PanelData::PrepareLoad: listing can't be nullptr");

    const auto perf_begin = std::chrono::steady_clock::now();

    // A scratch model lets us reuse the existing sorting/filtering machinery as is - none of these
    // operations depend on the instance they are called on.
    Model scratch;
    scratch.m_Listing = _listing;
    scratch.m_Type = _type;
    scratch.m_CustomSortMode = _sort_mode;
    scratch.m_HardFiltering = std::move(_hard_filtering);
    scratch.m_SoftFiltering = std::move(_soft_filtering);

    InitVolatileDataWithListing(scratch.m_VolatileData, *scratch.m_Listing);
    const auto perf_vd = std::chrono::steady_clock::now();

    scratch.m_HardFiltering.text.OnPanelDataLoad();
    scratch.m_SoftFiltering.OnPanelDataLoad();

    // Both sorts are independent - run them concurrently, exactly like Load() always did
    {
        const base::DispatchGroup exec_group{base::DispatchGroup::High};
        exec_group.Run([&] { DoRawSort(*scratch.m_Listing, scratch.m_EntriesByRawName); });
        exec_group.Run([&] { scratch.DoSortWithHardFiltering(); });
        exec_group.Wait();
    }
    const auto perf_sorted = std::chrono::steady_clock::now();
    scratch.BuildSoftFilteringIndeces();
    const auto perf_filtered = std::chrono::steady_clock::now();
    scratch.UpdateStatictics();
    if( std::getenv("NC_PERF_LOG") != nullptr ) {
        using namespace std::chrono;
        const auto perf_end = steady_clock::now();
        const auto ms = [](auto _from, auto _to) {
            return static_cast<double>(duration_cast<microseconds>(_to - _from).count()) / 1000.0;
        };
        std::fprintf(stderr,
                     "[perf] prepare n=%u vd=%.1fms sorts=%.1fms softfilter=%.1fms stats=%.1fms total=%.1fms\n",
                     _listing->Count(),
                     ms(perf_begin, perf_vd),
                     ms(perf_vd, perf_sorted),
                     ms(perf_sorted, perf_filtered),
                     ms(perf_filtered, perf_end),
                     ms(perf_begin, perf_end));
    }

    PreparedLoad prepared;
    prepared.listing = std::move(scratch.m_Listing);
    prepared.type = scratch.m_Type;
    prepared.hard_filtering = std::move(scratch.m_HardFiltering);
    prepared.soft_filtering = std::move(scratch.m_SoftFiltering);
    prepared.volatile_data = std::move(scratch.m_VolatileData);
    prepared.entries_by_raw_name = std::move(scratch.m_EntriesByRawName);
    prepared.entries_by_custom_sort = std::move(scratch.m_EntriesByCustomSort);
    prepared.reverse_to_custom_sort = std::move(scratch.m_ReverseToCustomSort);
    prepared.entries_by_soft_filtering = std::move(scratch.m_EntriesBySoftFiltering);
    prepared.statistics = scratch.m_Stats;
    return prepared;
}

void Model::InstallLoad(PreparedLoad &&_prepared)
{
    assert(dispatch_is_main_queue()); // STA api design
    m_Listing = std::move(_prepared.listing);
    m_Type = _prepared.type;
    m_HardFiltering = std::move(_prepared.hard_filtering);
    m_SoftFiltering = std::move(_prepared.soft_filtering);
    m_VolatileData = std::move(_prepared.volatile_data);
    m_EntriesByRawName = std::move(_prepared.entries_by_raw_name);
    m_EntriesByCustomSort = std::move(_prepared.entries_by_custom_sort);
    m_ReverseToCustomSort = std::move(_prepared.reverse_to_custom_sort);
    m_EntriesBySoftFiltering = std::move(_prepared.entries_by_soft_filtering);
    m_Stats = _prepared.statistics;
}

void Model::Load(const VFSListingPtr &_listing, PanelType _type)
{
    assert(dispatch_is_main_queue()); // STA api design

    if( !_listing )
        throw std::logic_error("PanelData::Load: listing can't be nullptr");

    Log::Info("Loading {} listing, {} entries, {}",
              magic_enum::enum_name(_type),
              _listing->Count(),
              _listing->IsUniform() ? _listing->Directory().c_str() : "N/A");

    InstallLoad(PrepareLoad(_listing, _type, m_CustomSortMode, m_HardFiltering, m_SoftFiltering));
}

void Model::ApplyPatchedListing(const VFSListingPtr &_listing,
                                std::span<const unsigned> _removed_old_indices,
                                unsigned _appended_count)
{
    assert(dispatch_is_main_queue());
    assert(_listing);
    assert(_listing->IsUniform());
    assert(m_Listing && m_Listing->IsUniform());
    assert(!m_HardFiltering.IsFiltering());

    const unsigned old_count = m_Listing->Count();
    const unsigned new_count = _listing->Count();
    assert(new_count == old_count - static_cast<unsigned>(_removed_old_indices.size()) + _appended_count);
    if( new_count != old_count - static_cast<unsigned>(_removed_old_indices.size()) + _appended_count )
        throw std::logic_error("Model::ApplyPatchedListing: listing doesn't match the patch");

    // old raw index -> new raw index, or 'invalid' for the dropped entries
    constexpr unsigned invalid = std::numeric_limits<unsigned>::max();
    std::vector<unsigned> old_to_new(old_count, invalid);
    {
        size_t removed_pos = 0;
        unsigned new_index = 0;
        for( unsigned old_index = 0; old_index != old_count; ++old_index ) {
            if( removed_pos < _removed_old_indices.size() && _removed_old_indices[removed_pos] == old_index ) {
                ++removed_pos;
                continue;
            }
            old_to_new[old_index] = new_index++;
        }
        assert(new_index + _appended_count == new_count);
    }

    const auto init_volatile_data = [&](ItemVolatileData &_vd, unsigned _index) {
        _vd = ItemVolatileData{};
        if( _listing->IsDir(_index) ) {
            if( _listing->HasSize(_index) ) {
                const auto sz = _listing->Size(_index);
                if( sz != std::numeric_limits<uint64_t>::max() )
                    _vd.size = sz;
            }
        }
        else {
            _vd.size = _listing->Size(_index);
        }
    };

    // volatile data: keep everything that survives and add fresh entries for the appended ones
    std::vector<ItemVolatileData> new_vd(new_count);
    for( unsigned old_index = 0; old_index != old_count; ++old_index ) {
        const unsigned new_index = old_to_new[old_index];
        if( new_index != invalid )
            new_vd[new_index] = m_VolatileData[old_index];
    }
    for( unsigned i = new_count - _appended_count; i != new_count; ++i )
        init_volatile_data(new_vd[i], i);

    // raw-name order: the retained entries keep their relative order, the appended ones are
    // inserted at their alphabetical positions
    std::vector<unsigned> new_by_raw_name;
    new_by_raw_name.reserve(new_count);
    for( const unsigned old_index : m_EntriesByRawName ) {
        const unsigned new_index = old_to_new[old_index];
        if( new_index != invalid )
            new_by_raw_name.emplace_back(new_index);
    }
    const auto name_less = [&](unsigned _lhs, unsigned _rhs) {
        return _listing->Filename(_lhs) < _listing->Filename(_rhs);
    };
    for( unsigned i = new_count - _appended_count; i != new_count; ++i )
        new_by_raw_name.insert(std::lower_bound(new_by_raw_name.begin(), new_by_raw_name.end(), i, name_less), i);

    // custom sort order: same story - the retained entries are already ordered correctly, the
    // appended ones have to be placed according to the current sort mode
    std::vector<unsigned> new_by_custom_sort;
    new_by_custom_sort.reserve(new_count);
    for( const unsigned old_index : m_EntriesByCustomSort ) {
        const unsigned new_index = old_to_new[old_index];
        if( new_index != invalid )
            new_by_custom_sort.emplace_back(new_index);
    }

    if( m_CustomSortMode.sort != SortMode::SortNoSort ) {
        const IndirectListingComparator cmp{*_listing, new_vd, m_CustomSortMode};
        const auto first = std::next(new_by_custom_sort.begin(), _listing->IsDotDot(0) ? 1 : 0);
        for( unsigned i = new_count - _appended_count; i != new_count; ++i ) {
            const bool is_dotdot = _listing->IsDotDot(i);
            auto pos =
                is_dotdot ? new_by_custom_sort.begin() : std::lower_bound(first, new_by_custom_sort.end(), i, cmp);
            new_by_custom_sort.insert(pos, i);
        }
    }
    else {
        for( unsigned i = new_count - _appended_count; i != new_count; ++i )
            new_by_custom_sort.emplace_back(i);
    }

    m_Listing = _listing;
    m_VolatileData = std::move(new_vd);
    m_EntriesByRawName = std::move(new_by_raw_name);
    m_EntriesByCustomSort = std::move(new_by_custom_sort);

    m_ReverseToCustomSort.resize(new_count);
    std::ranges::fill(m_ReverseToCustomSort, invalid);
    for( unsigned i = 0; i != new_count; ++i ) {
        const unsigned raw_index = m_EntriesByCustomSort[i];
        assert(raw_index < new_count);
        m_ReverseToCustomSort[raw_index] = i;
    }

    BuildSoftFilteringIndeces();
    UpdateStatictics();
}

static void UpdateWithExisingVD(ItemVolatileData &_new_vd, const ItemVolatileData &_ex_vd)
{
    if( _new_vd.size == ItemVolatileData::invalid_size ) {
        _new_vd = _ex_vd;
    }
    else {
        const auto sz = _new_vd.size;
        _new_vd = _ex_vd;
        _new_vd.size = sz;
    }
}

Model::ReloadSnapshot Model::SnapshotForReload() const
{
    ReloadSnapshot snapshot;
    snapshot.listing = m_Listing;
    snapshot.volatile_data = m_VolatileData;
    snapshot.entries_by_raw_name = m_EntriesByRawName;
    snapshot.sort_mode = m_CustomSortMode;
    snapshot.hard_filtering = m_HardFiltering;
    snapshot.soft_filtering = m_SoftFiltering;
    snapshot.type = m_Type;
    return snapshot;
}

Model::PreparedLoad Model::PrepareReload(const VFSListingPtr &_listing, ReloadSnapshot &&_snapshot)
{
    if( !_listing )
        throw std::logic_error("PanelData::PrepareReload: listing can't be nullptr");

    const auto perf_begin = std::chrono::steady_clock::now();

    // A scratch model carries the previous state, so that the merging logic below can run as is.
    Model scratch;
    scratch.m_Listing = std::move(_snapshot.listing);
    scratch.m_VolatileData = std::move(_snapshot.volatile_data);
    scratch.m_EntriesByRawName = std::move(_snapshot.entries_by_raw_name);
    scratch.m_CustomSortMode = _snapshot.sort_mode;
    scratch.m_HardFiltering = std::move(_snapshot.hard_filtering);
    scratch.m_SoftFiltering = std::move(_snapshot.soft_filtering);
    scratch.m_Type = _snapshot.type;
    if( !scratch.m_Listing )
        throw std::logic_error("PanelData::PrepareReload: no previous listing");

    // sort new entries by raw c name for sync-swapping needs
    std::vector<unsigned> dirbyrawcname;
    DoRawSort(*_listing, dirbyrawcname);

    std::vector<ItemVolatileData> new_vd;
    InitVolatileDataWithListing(new_vd, *_listing);

    if( _listing->IsUniform() && scratch.m_Listing->IsUniform() ) {
        // transfer custom data to new array using sorted indeces arrays based in raw C filename.
        // assumes that there can't be more than one file with same filenamr
        unsigned dst_i = 0;
        const unsigned dst_e = _listing->Count();
        unsigned src_i = 0;
        const unsigned src_e = scratch.m_Listing->Count();
        for( ; src_i != src_e && dst_i != dst_e; ++src_i ) {
            const int src = scratch.m_EntriesByRawName[src_i];
        check:
            const int dst = dirbyrawcname[dst_i];
            const int cmp = scratch.m_Listing->Filename(src).compare(_listing->Filename(dst));
            if( cmp == 0 ) {

                //                new_vd[ dst ] = m_VolatileData[ src ];
                UpdateWithExisingVD(new_vd[dst], scratch.m_VolatileData[src]);

                ++dst_i; // check this! we assume that normal directory can't hold
                         // two files with a same name
            }
            else if( cmp > 0 ) {
                dst_i++;
                if( dst_i == dst_e )
                    break;
                goto check;
            }
        }
    }
    else if( !_listing->IsUniform() && !scratch.m_Listing->IsUniform() ) {
        auto src_keys = ProduceLongKeysForListing(*scratch.m_Listing);
        auto src_keys_ind = ProduceSortedIndirectIndecesForLongKeys(src_keys);
        auto dst_keys = ProduceLongKeysForListing(*_listing);
        auto dst_keys_ind = ProduceSortedIndirectIndecesForLongKeys(dst_keys);

        // TODO: consider moving into separate algorithm
        unsigned dst_i = 0;
        const unsigned dst_e = static_cast<unsigned>(dst_keys.size());
        unsigned src_i = 0;
        const unsigned src_e = static_cast<unsigned>(src_keys.size());
        for( ; src_i != src_e && dst_i != dst_e; ++src_i ) {
            const int src = src_keys_ind[src_i];
        check2:
            const int dst = dst_keys_ind[dst_i];
            const int cmp = src_keys[src].compare(dst_keys[dst]);
            if( cmp == 0 ) {
                //                new_vd[ dst ] = m_VolatileData[ src ];
                UpdateWithExisingVD(new_vd[dst], scratch.m_VolatileData[src]);
                ++dst_i;
            }
            else if( cmp > 0 ) {
                dst_i++;
                if( dst_i == dst_e )
                    break;
                goto check2;
            }
        }
    }
    else
        throw std::invalid_argument("PanelData::PrepareReload: incompatible listing type!");

    // put a new data in a place
    scratch.m_Listing = _listing;
    scratch.m_VolatileData = std::move(new_vd);
    scratch.m_EntriesByRawName = std::move(dirbyrawcname);

    // now sort our new data with custom sortings
    scratch.DoSortWithHardFiltering();
    const auto perf_sorted = std::chrono::steady_clock::now();
    scratch.BuildSoftFilteringIndeces();
    scratch.UpdateStatictics();
    if( std::getenv("NC_PERF_LOG") != nullptr ) {
        using namespace std::chrono;
        const auto ms = [](auto _from, auto _to) {
            return static_cast<double>(duration_cast<microseconds>(_to - _from).count()) / 1000.0;
        };
        std::fprintf(stderr,
                     "[perf] prepare.reload n=%u sort+merge=%.1fms rest=%.1fms\n",
                     _listing->Count(),
                     ms(perf_begin, perf_sorted),
                     ms(perf_sorted, steady_clock::now()));
    }

    PreparedLoad prepared;
    prepared.listing = std::move(scratch.m_Listing);
    prepared.type = scratch.m_Type;
    prepared.hard_filtering = std::move(scratch.m_HardFiltering);
    prepared.soft_filtering = std::move(scratch.m_SoftFiltering);
    prepared.volatile_data = std::move(scratch.m_VolatileData);
    prepared.entries_by_raw_name = std::move(scratch.m_EntriesByRawName);
    prepared.entries_by_custom_sort = std::move(scratch.m_EntriesByCustomSort);
    prepared.reverse_to_custom_sort = std::move(scratch.m_ReverseToCustomSort);
    prepared.entries_by_soft_filtering = std::move(scratch.m_EntriesBySoftFiltering);
    prepared.statistics = scratch.m_Stats;
    return prepared;
}

void Model::ReLoad(const VFSListingPtr &_listing)
{
    assert(dispatch_is_main_queue()); // STA api design

    Log::Info("ReLoading listing, {} entries, {}",
              _listing->Count(),
              _listing->IsUniform() ? _listing->Directory().c_str() : "N/A");

    InstallLoad(PrepareReload(_listing, SnapshotForReload()));
}

const std::shared_ptr<VFSHost> &Model::Host() const
{
    if( !m_Listing->HasCommonHost() )
        throw std::logic_error("PanelData::Host was called with no common host in listing");
    return m_Listing->Host(0);
}

const VFSListing &Model::Listing() const noexcept
{
    return *m_Listing;
}

const VFSListingPtr &Model::ListingPtr() const noexcept
{
    return m_Listing;
}

Model::PanelType Model::Type() const noexcept
{
    return m_Type;
}

const std::vector<unsigned> &Model::SortedDirectoryEntries() const noexcept
{
    return m_EntriesByCustomSort;
}

ItemVolatileData &Model::VolatileDataAtRawPosition(int _pos)
{
    const size_t pos = _pos;
    if( pos >= m_VolatileData.size() ) // assuming we won't have more than 2^31 elements
        throw std::out_of_range("PanelData::VolatileDataAtRawPosition: index can't be out of range");

    return m_VolatileData[pos];
}

const ItemVolatileData &Model::VolatileDataAtRawPosition(int _pos) const
{
    const size_t pos = _pos;
    if( pos >= m_VolatileData.size() ) // assuming we won't have more than 2^31 elements
        throw std::out_of_range("PanelData::VolatileDataAtRawPosition: index can't be out of range");

    return m_VolatileData[pos];
}

ItemVolatileData &Model::VolatileDataAtSortPosition(int _pos)
{
    return VolatileDataAtRawPosition(RawIndexForSortIndex(_pos));
}

const ItemVolatileData &Model::VolatileDataAtSortPosition(int _pos) const
{
    return VolatileDataAtRawPosition(RawIndexForSortIndex(_pos));
}

std::string Model::FullPathForEntry(int _raw_index) const
{
    if( _raw_index < 0 || _raw_index >= static_cast<int>(m_Listing->Count()) )
        return "";

    const auto entry = m_Listing->Item(_raw_index);
    if( !entry.IsDotDot() )
        return entry.Path();
    else {
        auto t = entry.Directory();
        const auto i = t.rfind('/');
        if( i == 0 )
            t.resize(i + 1);
        else if( i != std::string::npos )
            t.resize(i);
        return t;
    }
}

int Model::RawIndexForName(std::string_view _filename) const noexcept
{
    assert(m_EntriesByRawName.size() == m_Listing->Count()); // consistency check

    if( _filename.empty() )
        return -1; // can't handle empty filenames

    const auto listing = m_Listing.get();
    assert(listing != nullptr);

    // performing binary search on m_EntriesByRawName
    const auto begin = m_EntriesByRawName.begin();
    const auto end = m_EntriesByRawName.end();
    const auto i = std::lower_bound(
        begin, end, _filename, [listing](unsigned _i, std::string_view _s) { return listing->Filename(_i) < _s; });
    if( i < end && listing->Filename(*i) == _filename )
        return *i;

    return -1;
}

std::span<const unsigned> Model::RawIndicesForName(std::string_view _filename) const noexcept
{
    assert(m_EntriesByRawName.size() == m_Listing->Count()); // consistency check

    if( _filename.empty() )
        return {};

    struct Cmp {
        const VFSListing *listing;
        bool operator()(unsigned _i, std::string_view _s) const noexcept { return listing->Filename(_i) < _s; }
        bool operator()(std::string_view _s, unsigned _i) const noexcept { return _s < listing->Filename(_i); }
    };

    const auto begin = m_EntriesByRawName.begin();
    const auto end = m_EntriesByRawName.end();

    // O( 2 * logN )
    const auto [first, last] = std::equal_range(begin, end, _filename, Cmp{m_Listing.get()});

    return {m_EntriesByRawName.data() + std::distance(begin, first),
            m_EntriesByRawName.data() + std::distance(begin, last)};
}

std::string Model::DirectoryPathWithoutTrailingSlash() const
{
    if( !m_Listing->HasCommonDirectory() )
        return "";

    std::string path = m_Listing->Directory(0);
    if( path.size() > 1 )
        path.pop_back();

    return path;
}

std::string Model::DirectoryPathWithTrailingSlash() const
{
    if( !m_Listing->HasCommonDirectory() )
        return "";
    return m_Listing->Directory();
}

std::string Model::DirectoryPathShort() const
{
    const std::string tmp = DirectoryPathWithoutTrailingSlash();
    const auto i = tmp.rfind('/');
    if( i != std::string::npos )
        return tmp.c_str() + i + 1;
    return "";
}

std::string Model::VerboseDirectoryFullPath() const
{
    if( !m_Listing || !m_Listing->IsUniform() )
        return "";
    std::array<VFSHost *, 32> hosts;
    int hosts_n = 0;

    VFSHost *cur = m_Listing->Host().get();
    while( cur ) {
        hosts[hosts_n++] = cur;
        cur = cur->Parent().get();
    }

    std::string s;
    while( hosts_n > 0 )
        s += hosts[--hosts_n]->Configuration().VerboseJunction();
    s += m_Listing->Directory();
    if( s.back() != '/' )
        s += '/';
    return s;
}

static void DoRawSort(const VFSListing &_from, std::vector<unsigned> &_to)
{
    _to.resize(_from.Count());
    std::ranges::iota(_to, 0);
    const auto less = [&_from](unsigned _1, unsigned _2) { return _from.Filename(_1) < _from.Filename(_2); };
    if( _to.size() < g_ParallelSortThresh )
        std::sort(_to.begin(), _to.end(), less);
    else
        pstld::sort(_to.begin(), _to.end(), less);
}

void Model::SetSortMode(struct SortMode _mode)
{
    if( m_CustomSortMode == _mode )
        return;

    m_CustomSortMode = _mode;
    DoSortWithHardFiltering();
    BuildSoftFilteringIndeces();
    UpdateStatictics();
}

// need to call UpdateStatictics() after this method since we alter selected set
void Model::ClearSelectedFlagsFromHiddenElements()
{
    for( auto &vd : m_VolatileData )
        if( !vd.is_shown() && vd.is_selected() )
            vd.toggle_selected(false);
}

SortMode Model::SortMode() const
{
    return m_CustomSortMode;
}

void Model::UpdateStatictics()
{
    m_Stats = Statistics{};
    if( m_Listing.get() == nullptr )
        return;
    assert(m_Listing->Count() == m_VolatileData.size());

    m_Stats.total_entries_amount = m_Listing->Count();
    if( !m_Listing->Empty() && m_Listing->IsDotDot(0) )
        m_Stats.total_entries_amount--;

    // calculate totals for directory
    for( const auto &i : *m_Listing )
        if( i.IsReg() ) {
            m_Stats.bytes_in_raw_reg_files += i.Size();
            m_Stats.raw_reg_files_amount++;
        }

    // calculate totals for selected. look only for entries which is visible (sorted/filtered ones)
    for( const auto n : m_EntriesByCustomSort ) {
        const auto &vd = m_VolatileData[n];
        if( vd.is_selected() ) {
            m_Stats.bytes_in_selected_entries += vd.is_size_calculated() ? vd.size : 0;

            m_Stats.selected_entries_amount++;
            if( m_Listing->IsDir(n) )
                m_Stats.selected_dirs_amount++;
            else
                m_Stats.selected_reg_amount++;
        }
    }
}

int Model::SortedIndexForRawIndex(int _index) const noexcept
{
    if( _index < 0 || static_cast<size_t>(_index) >= m_ReverseToCustomSort.size() )
        return -1;

    const unsigned reverse = m_ReverseToCustomSort[_index];
    if( reverse == std::numeric_limits<unsigned>::max() )
        return -1;
    else
        return static_cast<int>(reverse);
}

int Model::RawIndexForSortIndex(int _index) const noexcept
{
    if( _index < 0 || _index >= static_cast<int>(m_EntriesByCustomSort.size()) )
        return -1;
    return m_EntriesByCustomSort[_index];
}

VFSListingItem Model::EntryAtRawPosition(int _pos) const noexcept
{
    if( _pos >= 0 && _pos < static_cast<int>(m_Listing->Count()) )
        return m_Listing->Item(_pos);
    return {};
}

bool Model::IsValidSortPosition(int _pos) const noexcept
{
    return RawIndexForSortIndex(_pos) >= 0;
}

VFSListingItem Model::EntryAtSortPosition(int _pos) const noexcept
{
    return EntryAtRawPosition(RawIndexForSortIndex(_pos));
}

int Model::SortPositionOfEntry(const VFSListingItem &_item) const noexcept
{
    if( _item.Listing() != m_Listing ) {
        Log::Warn("Model::SortPositionOfEntry has been provided with an unrelated vfs item");
        return -1;
    }
    return SortedIndexForRawIndex(_item.Index());
}

void Model::CustomFlagsSelectRaw(int _at_raw_pos, bool _is_selected)
{
    if( _at_raw_pos < 0 || _at_raw_pos >= static_cast<int>(m_Listing->Count()) )
        return;

    if( m_Listing->IsDotDot(_at_raw_pos) )
        return; // assuming we can't select dotdot entry

    auto &vd = m_VolatileData[_at_raw_pos];

    if( vd.is_selected() == _is_selected ) // check if item is already selected
        return;

    const auto sz = vd.is_size_calculated() ? vd.size : 0;
    if( _is_selected ) {
        m_Stats.bytes_in_selected_entries += sz;
        m_Stats.selected_entries_amount++;
        if( m_Listing->IsDir(_at_raw_pos) )
            m_Stats.selected_dirs_amount++;
        else
            m_Stats.selected_reg_amount++; // mb another check for reg here?
    }
    else {
        m_Stats.bytes_in_selected_entries =
            m_Stats.bytes_in_selected_entries >= static_cast<int64_t>(sz) ? m_Stats.bytes_in_selected_entries - sz : 0;

        assert(m_Stats.selected_entries_amount > 0); // sanity check
        m_Stats.selected_entries_amount--;
        if( m_Listing->IsDir(_at_raw_pos) ) {
            assert(m_Stats.selected_dirs_amount > 0);
            m_Stats.selected_dirs_amount--;
        }
        else {
            assert(m_Stats.selected_reg_amount > 0);
            m_Stats.selected_reg_amount--;
        }
    }
    vd.toggle_selected(_is_selected);
}

void Model::CustomFlagsSelectSorted(int _at_sorted_pos, bool _is_selected)
{
    if( _at_sorted_pos < 0 || _at_sorted_pos >= static_cast<int>(m_EntriesByCustomSort.size()) )
        return;

    CustomFlagsSelectRaw(m_EntriesByCustomSort[_at_sorted_pos], _is_selected);
}

bool Model::CustomFlagsSelectSorted(const std::vector<bool> &_is_selected)
{
    bool changed = false;
    for( int i = 0, e = static_cast<int>(std::min(_is_selected.size(), m_EntriesByCustomSort.size())); i != e; ++i ) {
        const auto raw_pos = m_EntriesByCustomSort[i];
        if( !m_Listing->IsDotDot(raw_pos) ) {
            if( !changed ) {
                if( m_VolatileData[raw_pos].is_selected() != _is_selected[i] ) {
                    m_VolatileData[raw_pos].toggle_selected(_is_selected[i]);
                    changed = true;
                }
            }
            else {
                m_VolatileData[raw_pos].toggle_selected(_is_selected[i]);
            }
        }
    }
    if( changed )
        UpdateStatictics();
    return changed;
}

std::vector<std::string> Model::SelectedEntriesFilenames() const
{
    std::vector<std::string> list;
    for( int i = 0, e = static_cast<int>(m_VolatileData.size()); i != e; ++i )
        if( m_VolatileData[i].is_selected() )
            list.emplace_back(m_Listing->Filename(i));
    return list;
}

std::vector<VFSListingItem> Model::SelectedEntriesUnsorted() const
{
    std::vector<VFSListingItem> list;
    for( int i = 0, e = static_cast<int>(m_VolatileData.size()); i != e; ++i )
        if( m_VolatileData[i].is_selected() )
            list.emplace_back(m_Listing->Item(i));
    return list;
}

std::vector<VFSListingItem> Model::SelectedEntriesSorted() const
{
    std::vector<VFSListingItem> list;
    const auto sorted_count = SortedEntriesCount();
    for( int i = 0; i < sorted_count; ++i ) {
        assert(i < static_cast<int>(m_EntriesByCustomSort.size()));
        const auto raw_index = m_EntriesByCustomSort[i];
        assert(raw_index < m_VolatileData.size());
        if( m_VolatileData[raw_index].is_selected() )
            list.emplace_back(m_Listing->Item(raw_index));
    }
    return list;
}

bool Model::SetCalculatedSizeForDirectory(std::string_view _filename, std::string_view _directory, uint64_t _size)
{
    if( _filename.empty() || _directory.empty() || _size == ItemVolatileData::invalid_size )
        return false;

    // O(logN) - binary search over all elements
    const auto raw_indices = RawIndicesForName(_filename);

    // O(N) over the items with the same filename, usually N=1
    for( const auto raw_index : raw_indices ) {
        assert(m_Listing->Filename(raw_index) == _filename);
        if( m_Listing->IsDir(raw_index) && m_Listing->Directory(raw_index) == _directory ) {
            auto &vd = m_VolatileData[raw_index];
            if( vd.size == _size )
                return true;

            vd.size = _size;

            FinalizeSettingCalculatedSizes();
            return true;
        }
    }

    return false;
}

size_t Model::SetCalculatedSizesForDirectories(std::span<const std::string_view> _filenames,
                                               std::span<const std::string_view> _directories,
                                               std::span<const uint64_t> _sizes)
{
    if( _filenames.size() != _directories.size() || _filenames.size() != _sizes.size() )
        return 0;

    size_t num_set = 0;
    size_t num_changed = 0;
    const auto listing = m_Listing.get();

    // O(N) iterate over the entire input set
    for( size_t ind = 0; ind != _filenames.size(); ++ind ) {
        const auto filename = _filenames[ind];
        const auto directory = _directories[ind];
        const auto size = _sizes[ind];

        // O(logN) - binary search over all elements in the listing
        const auto raw_indices = RawIndicesForName(filename);

        // O(N) over the items with the same filename, usually N=1
        for( const auto raw_index : raw_indices ) {
            assert(listing->Filename(raw_index) == filename);
            if( listing->IsDir(raw_index) && listing->Directory(raw_index) == directory ) {
                ++num_set;
                auto &vd = m_VolatileData[raw_index];
                if( vd.size != size ) {
                    vd.size = size;
                    ++num_changed;
                }
                break;
            }
        }
    }

    if( num_changed != 0 )
        FinalizeSettingCalculatedSizes();

    return num_set;
}

size_t Model::SetCalculatedSizesForDirectories(std::span<const unsigned> _raw_items_indices,
                                               std::span<const uint64_t> _sizes)
{
    if( _raw_items_indices.size() != _sizes.size() )
        return 0;

    size_t num_set = 0;
    size_t num_changed = 0;
    const auto listing = m_Listing.get();
    const auto items_count = listing->Count();

    // O(N) iterate over the entire input set
    for( size_t ind = 0; ind != _raw_items_indices.size(); ++ind ) {
        const unsigned raw_index = _raw_items_indices[ind];
        const uint64_t size = _sizes[ind];
        if( raw_index >= items_count )
            throw std::out_of_range("SetCalculatedSizesForDirectories: invalid index");

        if( listing->IsDir(raw_index) ) {
            ++num_set;
            auto &vd = m_VolatileData[raw_index];
            if( vd.size != size ) {
                vd.size = size;
                ++num_changed;
            }
        }
    }

    if( num_changed != 0 )
        FinalizeSettingCalculatedSizes();

    return num_set;
}

void Model::FinalizeSettingCalculatedSizes()
{
    // double-check me
    DoSortWithHardFiltering();
    ClearSelectedFlagsFromHiddenElements();
    BuildSoftFilteringIndeces();
    UpdateStatictics();
}

void Model::CustomIconClearAll()
{
    for( auto &vd : m_VolatileData )
        vd.icon = 0;
}

void Model::CustomFlagsClearHighlights()
{
    for( auto &vd : m_VolatileData )
        vd.toggle_highlight(false);
}

int Model::SortedIndexForName(std::string_view _filename) const noexcept
{
    return SortedIndexForRawIndex(RawIndexForName(_filename));
}

bool Model::ClearTextFiltering()
{
    if( m_SoftFiltering.text == nil && m_HardFiltering.text.text == nil )
        return false;

    m_SoftFiltering.text = nil;
    m_HardFiltering.text.text = nil;

    for( auto &vd : m_VolatileData ) {
        vd.highlight = {};
    }

    DoSortWithHardFiltering();
    ClearSelectedFlagsFromHiddenElements(); // not sure if this is needed here
    BuildSoftFilteringIndeces();
    UpdateStatictics();
    return true;
}

void Model::SetHardFiltering(const HardFilter &_filter)
{
    if( m_HardFiltering == _filter )
        return;

    m_HardFiltering = _filter;

    DoSortWithHardFiltering();
    ClearSelectedFlagsFromHiddenElements();
    BuildSoftFilteringIndeces();
    UpdateStatictics();
}

HardFilter Model::HardFiltering() const
{
    return m_HardFiltering;
}

void Model::DoSortWithHardFiltering()
{
    m_EntriesByCustomSort.clear();
    m_ReverseToCustomSort.clear();

    const unsigned size = m_Listing->Count();

    if( size == 0 )
        return;

    m_EntriesByCustomSort.reserve(size);
    for( auto &vd : m_VolatileData ) {
        vd.highlight = {};
        vd.toggle_shown(true);
    }

    if( m_HardFiltering.IsFiltering() ) {
        const auto filter = [&](const VFSListingItem &_item) -> std::optional<QuickSearchHighlight> {
            QuickSearchHighlight found_range;
            const bool valid = m_HardFiltering.IsValidItem(_item, found_range);
            if( valid )
                return found_range;
            return {};
        };
        std::vector<std::optional<QuickSearchHighlight>> found_ranges(size);
        pstld::transform(m_Listing->begin(), m_Listing->end(), found_ranges.begin(), filter);

        const bool hightlight_results = m_HardFiltering.text.hightlight_results;
        for( unsigned i = 0; i != size; ++i ) {
            if( !found_ranges[i] ) {
                m_VolatileData[i].toggle_shown(false);
            }
            else {
                if( hightlight_results ) {
                    m_VolatileData[i].highlight = *found_ranges[i];
                }
                m_EntriesByCustomSort.push_back(i);
            }
        }
    }
    else {
        m_EntriesByCustomSort.resize(m_Listing->Count());
        std::ranges::iota(m_EntriesByCustomSort, 0);
    }

    if( m_EntriesByCustomSort.empty() || m_CustomSortMode.sort == SortMode::SortNoSort )
        return; // we're already done

    // do not touch dotdot directory. however, in some cases (root dir for example) there will be
    // no dotdot dir. also assumes that no filtering will exclude dotdot dir
    const auto first = std::next(m_EntriesByCustomSort.begin(), m_Listing->IsDotDot(0) ? 1 : 0);
    const auto last = std::end(m_EntriesByCustomSort);

    if( m_EntriesByCustomSort.size() < g_ParallelSortThresh )
        std::sort(first, last, IndirectListingComparator{*m_Listing, m_VolatileData, m_CustomSortMode});
    else
        pstld::sort(first, last, IndirectListingComparator{*m_Listing, m_VolatileData, m_CustomSortMode});

    m_ReverseToCustomSort.resize(size);
    std::ranges::fill(m_ReverseToCustomSort, std::numeric_limits<unsigned>::max());
    for( unsigned i = 0, e = static_cast<unsigned>(m_EntriesByCustomSort.size()); i != e; ++i ) {
        const unsigned forward_index = m_EntriesByCustomSort[i];
        assert(forward_index < size);
        m_ReverseToCustomSort[forward_index] = i;
    }
}

void Model::SetSoftFiltering(const TextualFilter &_filter)
{
    m_SoftFiltering = _filter;
    BuildSoftFilteringIndeces();
}

TextualFilter Model::SoftFiltering() const
{
    return m_SoftFiltering;
}

const std::vector<unsigned> &Model::EntriesBySoftFiltering() const noexcept
{
    return m_EntriesBySoftFiltering;
}

void Model::BuildSoftFilteringIndeces()
{
    if( m_SoftFiltering.IsFiltering() ) {
        m_EntriesBySoftFiltering.clear();
        m_EntriesBySoftFiltering.reserve(m_EntriesByCustomSort.size());

        int i = 0;
        const int e = static_cast<int>(m_EntriesByCustomSort.size());
        for( ; i != e; ++i ) {
            QuickSearchHighlight found_range;
            const int raw_index = m_EntriesByCustomSort[i];
            if( m_SoftFiltering.IsValidItem(m_Listing->Item(raw_index), found_range) )
                m_EntriesBySoftFiltering.push_back(i);

            if( m_SoftFiltering.hightlight_results ) {
                m_VolatileData[raw_index].highlight = found_range;
            }
        }
    }
    else {
        // An empty array means "identity": every sorted entry is visible in its own position.
        // Not materialising the whole iota saves 4MB on a million-entry listing.
        m_EntriesBySoftFiltering.clear();
        m_EntriesBySoftFiltering.shrink_to_fit();
    }
}

int Model::SoftFilteredCount() const noexcept
{
    if( !m_SoftFiltering.IsFiltering() )
        return SortedEntriesCount();
    return static_cast<int>(m_EntriesBySoftFiltering.size());
}

int Model::SortIndexForSoftFiltered(int _pos) const noexcept
{
    if( !m_SoftFiltering.IsFiltering() )
        return _pos;
    if( _pos < 0 || static_cast<size_t>(_pos) >= m_EntriesBySoftFiltering.size() )
        return -1;
    return static_cast<int>(m_EntriesBySoftFiltering[_pos]);
}

ExternalEntryKey Model::EntrySortKeysAtSortPosition(int _pos) const
{
    const auto item = EntryAtSortPosition(_pos);
    if( !item )
        throw std::invalid_argument("PanelData::EntrySortKeysAtSortPosition: invalid item position");
    return ExternalEntryKey{item, VolatileDataAtSortPosition(_pos)};
}

int Model::SortLowerBoundForEntrySortKeys(const ExternalEntryKey &_keys) const
{
    if( !_keys.is_valid() )
        return -1;

    // NOLINTNEXTLINE
    auto it = std::lower_bound(std::begin(m_EntriesByCustomSort),
                               std::end(m_EntriesByCustomSort),
                               _keys,
                               ExternalListingComparator(*m_Listing, m_VolatileData, m_CustomSortMode));
    if( it != std::end(m_EntriesByCustomSort) )
        return static_cast<int>(std::distance(std::begin(m_EntriesByCustomSort), it));
    return -1;
}

const Statistics &Model::Stats() const noexcept
{
    return m_Stats;
}

void Model::__InvariantCheck() const
{
    assert(m_Listing != nullptr);
    assert(m_VolatileData.size() == m_Listing->Count());
    assert(m_EntriesByRawName.size() == m_Listing->Count());
    assert(m_EntriesByCustomSort.size() <= m_Listing->Count());
    assert(m_EntriesBySoftFiltering.size() <= m_EntriesByCustomSort.size());
}

int Model::RawEntriesCount() const noexcept
{
    return m_Listing ? static_cast<int>(m_Listing->Count()) : 0;
}

int Model::SortedEntriesCount() const noexcept
{
    return static_cast<int>(m_EntriesByCustomSort.size());
}

} // namespace nc::panel::data
