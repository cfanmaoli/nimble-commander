// Copyright (C) 2013-2020 Michael Kazakov. Subject to GNU General Public License version 3.
#pragma once

#include <VFS/VFSListing.h>
#include "PanelDataItemVolatileData.h"
#include "PanelDataSortMode.h"
#include "PanelDataStatistics.h"
#include "PanelDataFilter.h"

#include <vector>
#include <string_view>
#include <span>

namespace nc::panel::data {

struct ItemVolatileData;
struct ExternalEntryKey;

/**
 * PanelData actually does the following things:
 * - sorting provided data
 * - handling reloading with preserving of custom entries data
 * - searching
 * - paths accessing
 * - custom information setting/getting
 * - statistics
 * These methods should be called by a controller, since some view's props have to be updated.
 * PanelData is solely sync class - it does not know about concurrency,
 * any parallelism should be done by callers (i.e. controller).
 */
class Model
{
public:
    enum class PanelType : int8_t {
        Directory = 0,
        Temporary = 1
    };

    // creates a Model with an empty listing
    Model();

    Model(const Model &);

    Model(Model &&) noexcept;

    ~Model();

    Model &operator=(const Model &);
    Model &operator=(Model &&) noexcept;

    // Initializes a new model with _listing, allocates fresh volatile data, builds search indices,
    // updates statistics.
    void Load(const VFSListingPtr &_listing, PanelType _type);

    void ReLoad(const VFSListingPtr &_listing);

    /**
     * The outcome of the heavy part of Load(): the volatile data, the sort orders, the filtering
     * indices and the statistics. Produced by PrepareLoad().
     */
    struct PreparedLoad {
        VFSListingPtr listing;
        PanelType type = PanelType::Directory;
        HardFilter hard_filtering;
        TextualFilter soft_filtering;
        std::vector<ItemVolatileData> volatile_data;
        std::vector<unsigned> entries_by_raw_name;
        std::vector<unsigned> entries_by_custom_sort;
        std::vector<unsigned> reverse_to_custom_sort;
        std::vector<unsigned> entries_by_soft_filtering;
        Statistics statistics;
    };

    /**
     * Does everything Load() does apart from touching the Model object itself: allocates the
     * volatile data, runs both sorts, builds the filtering indices and computes the statistics.
     * Safe to call from any thread - the model instance is left untouched.
     */
    [[nodiscard]] static PreparedLoad PrepareLoad(const VFSListingPtr &_listing,
                                                  PanelType _type,
                                                  SortMode _sort_mode,
                                                  HardFilter _hard_filtering,
                                                  TextualFilter _soft_filtering);

    /**
     * Installs the outcome of PrepareLoad()/PrepareReload(), the cheap remainder of Load()/ReLoad().
     * Must be called on the main thread.
     */
    void InstallLoad(PreparedLoad &&_prepared);

    /**
     * A copy of the state ReLoad() needs from the previous listing, so that the heavy part can be
     * done on another thread.
     */
    struct ReloadSnapshot {
        VFSListingPtr listing;
        std::vector<ItemVolatileData> volatile_data;
        std::vector<unsigned> entries_by_raw_name;
        SortMode sort_mode;
        HardFilter hard_filtering;
        TextualFilter soft_filtering;
        PanelType type = PanelType::Directory;
    };

    /**
     * Takes the snapshot above. Must be called on the main thread.
     */
    [[nodiscard]] ReloadSnapshot SnapshotForReload() const;

    /**
     * Same as ReLoad(), but works on a snapshot instead of the model itself, so it is safe to call
     * from any thread. The result is installed with InstallLoad().
     */
    [[nodiscard]] static PreparedLoad PrepareReload(const VFSListingPtr &_listing, ReloadSnapshot &&_snapshot);

    /**
     * Applies a listing that was produced by patching the current one: the entries at
     * '_removed_old_indices' (sorted ascending, unique) are dropped and the last '_appended_count'
     * entries of '_listing' are the freshly fetched ones.
     * Retains the volatile data (selection, icons, calculated sizes) of all the other entries and
     * the already established sort order, so applying a handful of changes to a million-entry
     * listing costs O(n) with cheap operations instead of a full re-sort.
     * Preconditions: no hard filtering is active, both listings are uniform.
     */
    void ApplyPatchedListing(const VFSListingPtr &_listing,
                             std::span<const unsigned> _removed_old_indices,
                             unsigned _appended_count);

    /**
     * Tells whether Model was provided with a valid listing object.
     */
    [[nodiscard]] bool IsLoaded() const noexcept;

    /**
     * Returns a common VHS host referred by the stored listing.
     * Will throw logic_error if called on a listing with no common host.
     */
    [[nodiscard]] const std::shared_ptr<VFSHost> &Host() const;

    /**
     * Returns a stored VFS listing.
     */
    [[nodiscard]] const VFSListing &Listing() const noexcept;

    /**
     * Returns a shared pointer to a stored VFS listing.
     */
    [[nodiscard]] const VFSListingPtr &ListingPtr() const noexcept;

    /**
     * Returns a panel type provided upen loading.
     */
    [[nodiscard]] PanelType Type() const noexcept;

    /**
     * Returns the number of raw i.e. unfiltered entires in the listing.
     */
    [[nodiscard]] int RawEntriesCount() const noexcept;

    /**
     * Returns the number of sorted i.e. possibly filtered entires in the listing.
     */
    [[nodiscard]] int SortedEntriesCount() const noexcept;

    [[nodiscard]] const std::vector<unsigned> &SortedDirectoryEntries() const noexcept;

    /**
     * EntriesBySoftFiltering return a vector of filtered indeces of sorted entries (not raw ones)
     */
    [[nodiscard]] const std::vector<unsigned> &EntriesBySoftFiltering() const noexcept;

    // will return an "empty" item upon invalid index
    [[nodiscard]] VFSListingItem EntryAtRawPosition(int _pos) const noexcept;

    // will throw an exception upon invalid index
    ItemVolatileData &VolatileDataAtRawPosition(int _pos);

    // will throw an exception upon invalid index
    [[nodiscard]] const ItemVolatileData &VolatileDataAtRawPosition(int _pos) const;

    [[nodiscard]] bool IsValidSortPosition(int _pos) const noexcept;

    // will return an "empty" item upon invalid index
    [[nodiscard]] VFSListingItem EntryAtSortPosition(int _pos) const noexcept;

    // will throw an exception upon invalid index
    ItemVolatileData &VolatileDataAtSortPosition(int _pos);

    // will throw an exception upon invalid index
    [[nodiscard]] const ItemVolatileData &VolatileDataAtSortPosition(int _pos) const;

    // Syntax sugar around SortedIndexForRawIndex(_item.Index()), but also checks
    // if the item's listing is the same as the model's.
    // Returns "-1" if the item is not found in the sorted representation.
    // O(1) complexity.
    [[nodiscard]] int SortPositionOfEntry(const VFSListingItem &_item) const noexcept;

    [[nodiscard]] std::vector<std::string> SelectedEntriesFilenames() const;

    /**
     * Returns a list of selected VFS items, without a specific order,
     * according to the raw structure of a listing.
     * O(N) complexity.
     */
    [[nodiscard]] std::vector<VFSListingItem> SelectedEntriesUnsorted() const;

    /**
     * Returns a list of selected VFS items, ordered according to the selected sort mode.
     * O(N) complexity.
     */
    [[nodiscard]] std::vector<VFSListingItem> SelectedEntriesSorted() const;

    /**
     * Will throw an invalid_argument on invalid _pos.
     */
    [[nodiscard]] ExternalEntryKey EntrySortKeysAtSortPosition(int _pos) const;

    /**
     * will redirect ".." upwards
     */
    [[nodiscard]] std::string FullPathForEntry(int _raw_index) const;

    /**
     * Converts sorted index into raw index. Returns -1 on any errors.
     * O(1) complexity.
     */
    [[nodiscard]] int RawIndexForSortIndex(int _index) const noexcept;

    /**
     * Performs a binary case-sensivitive search.
     * Return -1 if didn't found.
     * Returning value is in raw land, that is DirectoryEntries[N], not sorted ones.
     * NB! it has issues with non-uniform listings - it can return only the first entry.
     * Complexity: O(logN ), N - total number of items in the listing.
     */
    [[nodiscard]] int RawIndexForName(std::string_view _filename) const noexcept;

    /**
     * Performs a binary case-sensivitive search.
     * Return a non-owning range of indices.
     * Returning value is in raw land, that is Listing()[N], not sorted ones.
     * Complexity: O(2 * logN ), N - total number of items in the listing.
     */
    [[nodiscard]] std::span<const unsigned> RawIndicesForName(std::string_view _filename) const noexcept;

    /**
     * Performs a search using current sort settings with prodived keys.
     * Return a lower bound entry - first entry with is not less than a key from _keys.
     * Returns -1 if such entry wasn't found.
     */
    [[nodiscard]] int SortLowerBoundForEntrySortKeys(const ExternalEntryKey &_key) const;

    /**
     * Returns a sorted index for a given filename.
     * Returns -1 if such entry wasn't found.
     * Returned value is in sorted indxs land.
     * O(logN) complexity, N - total number of items in the listing.
     * NB! for non-uniform listings this will return only the first item, while there can be more, as filename is not
     * unique there.
     */
    [[nodiscard]] int SortedIndexForName(std::string_view _filename) const noexcept;

    /**
     * Returns a sorted index for the raw index.
     * If the raw index is not present in the sorted indices - returns -1.
     * For OOB access returns -1 as well.
     * O(1) complexity.
     */
    [[nodiscard]] int SortedIndexForRawIndex(int _desired_raw_index) const noexcept;

    /**
     * return current directory in long variant starting from /
     */
    [[nodiscard]] std::string DirectoryPathWithoutTrailingSlash() const;

    /**
     * same as DirectoryPathWithoutTrailingSlash() but path will ends with slash
     */
    [[nodiscard]] std::string DirectoryPathWithTrailingSlash() const;

    /**
     * return name of a current directory in a parent directory.
     * returns a zero string for a root dir.
     */
    [[nodiscard]] std::string DirectoryPathShort() const;

    [[nodiscard]] std::string VerboseDirectoryFullPath() const;

    // sorting
    void SetSortMode(SortMode _mode);
    [[nodiscard]] SortMode SortMode() const;

    // hard filtering filtering
    void SetHardFiltering(const HardFilter &_filter);
    [[nodiscard]] HardFilter HardFiltering() const;

    void SetSoftFiltering(const TextualFilter &_filter);
    [[nodiscard]] TextualFilter SoftFiltering() const;

    /**
     * ClearTextFiltering() efficiently sets SoftFiltering.text = nil and HardFiltering.text.text =
     * nil. It's better than consequent calls of SetHardFiltering()+SetSoftFiltering() - less
     * indeces rebuilding. Return true if calling of this method changed anything, and false if
     * indeces was unchanged
     */
    bool ClearTextFiltering();

    [[nodiscard]] const Statistics &Stats() const noexcept;

    // manupulation with user flags for directory entries

    // TODO: bool results?????

    void CustomFlagsSelectSorted(int _at_sorted_pos, bool _is_selected);
    bool CustomFlagsSelectSorted(const std::vector<bool> &_is_selected);

    void CustomIconClearAll();
    void CustomFlagsClearHighlights();

    /**
     * Searches for a directory named '_filename' in '_directory' using binary search with case-sensitive comparison and
     * sets its size. Return true if the entry was found and the size was set, false otherwise. _size should be less
     * than uint64_t(-1). Automatically rebuilds search/sort indices and statistics.
     */
    bool SetCalculatedSizeForDirectory(std::string_view _filename, std::string_view _directory, uint64_t _size);

    /**
     * A batch version of SetCalculatedSizeForDirectory.
     * Returns a number of entries found and set.
     */
    size_t SetCalculatedSizesForDirectories(std::span<const std::string_view> _filenames,
                                            std::span<const std::string_view> _directories,
                                            std::span<const uint64_t> _sizes);

    /**
     * A batch version of SetCalculatedSizeForDirectory that accepts raw item indices.
     * Returns a number of entries found and set.
     */
    size_t SetCalculatedSizesForDirectories(std::span<const unsigned> _raw_items_indices,
                                            std::span<const uint64_t> _sizes);

    /**
     * Call it in emergency case.
     */
    void __InvariantCheck() const;

private:
    void DoSortWithHardFiltering();
    void CustomFlagsSelectRaw(int _at_raw_pos, bool _is_selected);
    void ClearSelectedFlagsFromHiddenElements();
    void UpdateStatictics();
    void BuildSoftFilteringIndeces();
    void FinalizeSettingCalculatedSizes();

    // m_Listing container will change every time directory change/reloads,
    // while the following sort-indeces(except for m_EntriesByRawName) will be permanent with it's
    // content changing
    VFSListingPtr m_Listing;
    std::vector<ItemVolatileData> m_VolatileData;

    // sorted with raw strcmp comparison
    std::vector<unsigned> m_EntriesByRawName;

    // sorted with customly defined sort
    std::vector<unsigned> m_EntriesByCustomSort;

    // Reversed index: maps from the raw indices to the sorted indices. Can be
    // std::numeric_limits<unsigned>::max() if the entry is not present in the custom sort.
    std::vector<unsigned> m_ReverseToCustomSort;

    // sorted and filtered, points at m_EntriesByCustomSort indices, not the raw ones
    std::vector<unsigned> m_EntriesBySoftFiltering;
    struct SortMode m_CustomSortMode;
    HardFilter m_HardFiltering;
    TextualFilter m_SoftFiltering;
    Statistics m_Stats;
    PanelType m_Type;
};

} // namespace nc::panel::data
