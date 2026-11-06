// Copyright (C) 2013-2025 Michael Kazakov. Subject to GNU General Public License version 3.
#include "PanelController.h"
#include "PanelController+DataAccess.h"
#include <VFS/VFSListingInput.h>
#include <Base/algo.h>
#include <Utility/NSView+Sugar.h>
#include <Utility/NSMenu+Hierarchical.h>
#include "../MainWindowController.h"
#include "PanelPreview.h"
#include "MainWindowFilePanelState.h"
#include "Views/BriefSystemOverview.h"
#include <NimbleCommander/Core/Alert.h>
#include <NimbleCommander/Core/ActionsShortcutsManager.h>
#include <NimbleCommander/Bootstrap/Config.h>
#include "PanelViewLayoutSupport.h"
#include <Panel/PanelDataItemVolatileData.h>
#include "PanelDataOptionsPersistence.h"
#include <Base/CommonPaths.h>
#include <VFS/Native.h>
#include "PanelHistory.h"
#include <Base/SerialQueue.h>
#include <Panel/PanelData.h>
#include "PanelView.h"
#include "DragReceiver.h"
#include "ContextMenu.h"
#include <Panel/PanelDataExternalEntryKey.h>
#include "PanelDataPersistency.h"
#include <NimbleCommander/Core/VFSInstanceManager.h>
#include "Actions/OpenFile.h"
#include "Actions/GoToFolder.h"
#include <NimbleCommander/Core/Alert.h>
#include <chrono>
#include <cstdio>
#include <thread>
#include <ankerl/unordered_dense.h>
#include "Actions/Enter.h"
#include <Operations/Copying.h>
#include <Panel/CursorBackup.h>
#include <Panel/QuickSearch.h>
#include <Panel/Log.h>
#include "PanelViewHeader.h"
#include <Config/RapidJSON.h>
#include <Utility/ObjCpp.h>
#include <Utility/StringExtras.h>
#include <Utility/PathManip.h>
#include <Base/mach_time.h>

#include <algorithm>
#include <span>
#include <vector>

using namespace nc;
using namespace nc::core;
using namespace nc::panel;
using namespace std::literals;

static constexpr size_t g_MaxSizeCalculationCommitBatches = 40;
static constexpr std::chrono::nanoseconds g_FilesystemHintTriggerDelay = std::chrono::milliseconds{500}; // 0.5s

static const auto g_ConfigShowDotDotEntry = "filePanel.general.showDotDotEntry";
static const auto g_ConfigIgnoreDirectoriesOnMaskSelection = "filePanel.general.ignoreDirectoriesOnSelectionWithMask";
static const auto g_ConfigShowLocalizedFilenames = "filePanel.general.showLocalizedFilenames";
static const auto g_ConfigEnableFinderTags = "filePanel.FinderTags.enable";

namespace nc::panel {

ActivityTicket::ActivityTicket() : ticket(0), panel(nil)
{
}

ActivityTicket::ActivityTicket(PanelController *_panel, uint64_t _ticket) : ticket(_ticket), panel(_panel)
{
}

ActivityTicket::ActivityTicket(ActivityTicket &&_rhs) noexcept : ticket(_rhs.ticket), panel(_rhs.panel)
{
    _rhs.panel = nil;
    _rhs.ticket = 0;
}

ActivityTicket::~ActivityTicket()
{
    Reset();
}

ActivityTicket &ActivityTicket::operator=(ActivityTicket &&_rhs) noexcept
{
    Reset();
    panel = _rhs.panel;
    ticket = _rhs.ticket;
    _rhs.panel = nil;
    _rhs.ticket = 0;
    return *this;
}

void ActivityTicket::Reset()
{
    if( ticket )
        if( PanelController *const pc = panel )
            [pc finishExtActivityWithTicket:ticket];
    panel = nil;
    ticket = 0;
}

struct CalculatedSizesBatch {
    std::vector<VFSListingItem> items;
    std::vector<uint64_t> sizes;
};

} // namespace nc::panel

#define MAKE_AUTO_UPDATING_BOOL_CONFIG_VALUE(_name, _path)                                                             \
    static bool _name()                                                                                                \
    {                                                                                                                  \
        static const auto fetch = [] { return GlobalConfig().GetBool((_path)); };                                      \
        static bool value = [] {                                                                                       \
            GlobalConfig().ObserveForever((_path), [] { value = fetch(); });                                           \
            return fetch();                                                                                            \
        }();                                                                                                           \
        return value;                                                                                                  \
    }

MAKE_AUTO_UPDATING_BOOL_CONFIG_VALUE(ConfigShowDotDotEntry, g_ConfigShowDotDotEntry);
MAKE_AUTO_UPDATING_BOOL_CONFIG_VALUE(ConfigShowLocalizedFilenames, g_ConfigShowLocalizedFilenames);
MAKE_AUTO_UPDATING_BOOL_CONFIG_VALUE(ConfigEnableFinderTags, g_ConfigEnableFinderTags);
MAKE_AUTO_UPDATING_BOOL_CONFIG_VALUE(ConfigLazyDates, "filePanel.general.lazyDates");
MAKE_AUTO_UPDATING_BOOL_CONFIG_VALUE(ConfigLazySizes, "filePanel.general.lazySizes");

#define MAKE_AUTO_UPDATING_INT_CONFIG_VALUE(_name, _path, _fallback)                                                   \
    static long _name()                                                                                                \
    {                                                                                                                  \
        static const auto fetch = [] { return GlobalConfig().GetInt((_path)); };                                       \
        static long value = [] {                                                                                       \
            GlobalConfig().ObserveForever((_path), [] { value = fetch(); });                                           \
            return fetch();                                                                                            \
        }();                                                                                                           \
        return value > 0 ? value : (_fallback);                                                                        \
    }

// A flat view of a whole subtree is inherently heavy - these are the safety limits. They are
// generous on purpose: silently dropping a million of entries was far worse than the memory.
MAKE_AUTO_UPDATING_INT_CONFIG_VALUE(ConfigFlatViewMaxItems, "filePanel.general.flatViewMaxItems", 1'000'000);
MAKE_AUTO_UPDATING_INT_CONFIG_VALUE(ConfigFlatViewMaxDirectories,
                                    "filePanel.general.flatViewMaxDirectories",
                                    2'000'000);

// How many directories the flat scan enumerates in parallel. 0 (the default) means "pick
// something sensible for the machine".
MAKE_AUTO_UPDATING_INT_CONFIG_VALUE(ConfigFlatScanThreads, "filePanel.general.flatScanThreads", 0);

static void HeatUpConfigValues()
{
    ConfigShowDotDotEntry();
    ConfigShowLocalizedFilenames();
    ConfigEnableFinderTags();
}

@interface PanelController ()

@property(nonatomic, readonly)
    bool receivesUpdateNotifications; // returns true if underlying vfs will notify controller that content has changed

- (void)accumulateChangedNames:(const std::vector<std::string> &)_names;
- (void)schedulePendingRefresh;
- (void)refreshPanelIncrementallyWithChangedNames:(std::vector<std::string>)_names;
- (void)applyPatchedListing:(const VFSListingPtr &)_listing
                    removed:(const std::vector<unsigned> &)_removed
                   appended:(unsigned)_appended;
- (void)installPreparedReload:(data::Model::PreparedLoad &&)_prepared;
- (void)fetchLazyDatesForTopEntries;
- (void)fetchLazyDatesForSortedRange:(NSRange)_range;
- (void)reportFlatViewTruncation:(size_t)_scanned_items directories:(size_t)_scanned_directories;
@end

namespace {

// Collects everything underneath the given directory into a single listing. Symbolic links to
// directories are listed but not followed, so that a link loop cannot hang the traversal.
struct FlatListingResult {
    VFSListingPtr listing;
    size_t scanned_items = 0;
    size_t scanned_directories = 0;
    bool truncated = false;
    // where the time went, in milliseconds
    long long scan_ms = 0;
    long long compose_ms = 0;
    long long fetch_ms = 0; // the parallel enumeration phase
    long long fold_ms = 0;  // the sequential pass that builds the sub-listings
};

FlatListingResult BuildFlatListing(const VFSHostPtr &_host,
                                   const std::string &_root,
                                   unsigned long _fetch_flags,
                                   const VFSCancelChecker &_cancel_checker,
                                   const size_t _max_items,
                                   const size_t _max_directories,
                                   const size_t _threads)
{
    FlatListingResult result;
    const size_t max_directories = _max_directories;
    const size_t max_items = _max_items;

    const auto flat_begin = std::chrono::steady_clock::now();
    try {
        std::vector<VFSListingPtr> listings;
        std::vector<std::vector<unsigned>> indices;
        size_t total_items = 0;

        // The scan is level-synchronous: every directory of the current level is fetched in
        // parallel (that's where the time goes - 200k directories on a big tree, one syscall
        // stream each), and the entries are then folded in sequentially so that the budget
        // accounting and the resulting listing stay deterministic.
        std::vector<std::string> frontier;
        frontier.emplace_back(_root);
        size_t directories_seen = 1;

        // The flat view never shows "." or "..", so don't ask the host to fetch the dot-dot
        // entry - for a directory tree of a few hundred thousand directories that is one extra
        // per-entry attribute pass each.
        const unsigned long scan_flags = _fetch_flags | VFSFlags::F_NoDotDot;

        const size_t threads = std::max<size_t>(1, _threads);
        bool truncated = false;

        while( !frontier.empty() && !truncated ) {
            if( _cancel_checker && _cancel_checker() )
                return {}; // cancelled - the caller discards the result anyway

            const auto fetch_begin = std::chrono::steady_clock::now();
            std::vector<VFSListingPtr> fetched(frontier.size());
            if( threads == 1 || frontier.size() == 1 ) {
                for( size_t i = 0; i != frontier.size(); ++i ) {
                    if( _cancel_checker && _cancel_checker() )
                        return {};
                    if( auto listing = _host->FetchDirectoryListing(frontier[i], scan_flags, _cancel_checker) )
                        fetched[i] = *listing;
                }
            }
            else {
                std::atomic<size_t> next{0};
                std::atomic<bool> cancelled{false};
                const auto worker = [&] {
                    for( size_t i = next.fetch_add(1); i < frontier.size(); i = next.fetch_add(1) ) {
                        if( cancelled.load(std::memory_order_relaxed) )
                            return;
                        if( _cancel_checker && _cancel_checker() ) {
                            cancelled.store(true, std::memory_order_relaxed);
                            return;
                        }
                        if( auto listing = _host->FetchDirectoryListing(frontier[i], scan_flags, _cancel_checker) )
                            fetched[i] = *listing;
                    }
                };
                std::vector<std::thread> pool;
                pool.reserve(std::min(threads, frontier.size()));
                for( size_t t = 0; t != std::min(threads, frontier.size()); ++t )
                    pool.emplace_back(worker);
                for( auto &t : pool )
                    t.join();
                if( cancelled.load(std::memory_order_relaxed) )
                    return {};
            }

            result.fetch_ms +=
                std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - fetch_begin)
                    .count();
            const auto fold_begin = std::chrono::steady_clock::now();
            std::vector<std::string> next_frontier;
            for( size_t i = 0; i != frontier.size(); ++i ) {
                const VFSListingPtr &listing = fetched[i];
                if( !listing )
                    continue;

                std::vector<unsigned> wanted;
                for( unsigned item_index = 0, items = listing->Count(); item_index != items; ++item_index ) {
                    const VFSListingItem item{listing, item_index};
                    const std::string &filename = item.Filename();
                    // '.' and '..' have no place in a flat view - the latter would also make the
                    // traversal walk towards the filesystem root endlessly.
                    if( filename == "." || filename == ".." )
                        continue;
                    wanted.emplace_back(item_index);
                    if( item.IsDir() && !item.IsSymlink() ) {
                        next_frontier.emplace_back(item.Directory() + filename + "/");
                        ++directories_seen;
                    }
                }

                // An empty directory (or one with nothing but the dot entries) is perfectly
                // normal - skip it and keep walking. Stopping here would silently cut the
                // traversal short at the first empty subdirectory of the tree.
                if( wanted.empty() )
                    continue;

                // take as many entries as the budget allows - dropping the *whole* directory
                // just because it alone is bigger than the limit would leave the user with an
                // empty panel
                size_t take = wanted.size();
                if( total_items + take > max_items ) {
                    take = max_items > total_items ? max_items - total_items : 0;
                    truncated = true;
                }
                if( take == 0 )
                    break; // the budget is gone
                total_items += take;
                wanted.resize(take);
                listings.emplace_back(listing);
                indices.emplace_back(std::move(wanted));
            }

            result.fold_ms +=
                std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - fold_begin)
                    .count();
            if( listings.size() >= max_directories ) {
                truncated = true;
                break;
            }
            frontier = std::move(next_frontier);
        }

        result.scanned_items = total_items;
        result.scanned_directories = directories_seen;
        result.truncated = truncated;

        if( listings.empty() )
            return result; // nothing underneath - keep the regular directory listing
        const auto compose_begin = std::chrono::steady_clock::now();
        result.listing = VFSListing::Build(VFSListing::Compose(listings, indices));
        result.scan_ms = std::chrono::duration_cast<std::chrono::milliseconds>(compose_begin - flat_begin).count();
        result.compose_ms =
            std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - compose_begin)
                .count();
        return result;
    } catch( ... ) {
        return result;
    }
}

// Produces a new listing out of '_base' by dropping the entries at '_removed' (sorted ascending)
// and appending the items from '_appended' (single-item listings of the freshly stat'ed entries).
// Rebuilding through VFSListing::Compose() would sort the data into sparse containers, which is
// O(n) hash-map insertions for a million items - here everything that can stay dense stays dense.
VFSListingPtr ProducePatchedListingGeneric(const VFSListing &_base,
                                           const std::vector<unsigned> &_removed,
                                           const std::vector<VFSListingPtr> &_appended)
{
    using nc::base::variable_container;
    if( !_base.HasCommonHost() || !_base.HasCommonDirectory() )
        return {};

    nc::vfs::ListingInput in;
    in.hosts.insert(0, _base.Host(0));
    in.directories.insert(0, _base.Directory(0));
    in.sizes.reset(variable_container<>::type::dense);
    in.inodes.reset(variable_container<>::type::dense);
    // a listing may simply not carry the timestamps (lazy dates) - keep them absent instead of
    // filling in zeros, the panel would otherwise show 1970 for every entry
    const bool base_has_times = _base.HasAnyTimes();
    const auto times_type = base_has_times ? variable_container<>::type::dense : variable_container<>::type::sparse;
    in.atimes.reset(times_type);
    in.mtimes.reset(times_type);
    in.ctimes.reset(times_type);
    in.btimes.reset(times_type);
    in.uids.reset(variable_container<>::type::dense);
    in.gids.reset(variable_container<>::type::dense);
    in.unix_flags.reset(variable_container<>::type::dense);

    const auto appended_items = [&] {
        size_t n = 0;
        for( auto &ptr : _appended )
            n += ptr->Count();
        return n;
    }();
    const auto total = static_cast<size_t>(_base.Count()) - _removed.size() + appended_items;
    in.filenames.reserve(total);
    in.unix_modes.reserve(total);
    in.unix_types.reserve(total);
    // pre-size the dense containers so that the per-item inserts below are plain assignments
    // instead of a size check + an amortized growth of a million-element vector
    in.sizes.resize(total);
    in.inodes.resize(total);
    if( base_has_times ) {
        in.atimes.resize(total);
        in.mtimes.resize(total);
        in.ctimes.resize(total);
        in.btimes.resize(total);
    }
    in.uids.resize(total);
    in.gids.resize(total);
    in.unix_flags.resize(total);

    // the per-item attribute checks are not free - skip the whole category when a listing simply
    // doesn't carry it
    struct Attrs {
        bool display_filenames;
        bool add_times;
        bool symlinks;
        bool tags;
    };
    const auto attrs_of = [](const VFSListing &_l) {
        return Attrs{_l.HasAnyDisplayFilenames(), _l.HasAnyAddTimes(), _l.HasAnySymlinks(), _l.HasAnyTags()};
    };

    unsigned n = 0;
    const auto append_item = [&](const VFSListing &_l, const Attrs &_attrs, unsigned _i) {
        in.filenames.emplace_back(_l.Filename(_i));
        in.unix_modes.emplace_back(_l.UnixMode(_i));
        in.unix_types.emplace_back(_l.UnixType(_i));
        // the containers are dense and pre-sized, so a direct index beats a mode dispatch + a
        // bounds check per element
        in.sizes[n] = _l.HasSize(_i) ? _l.Size(_i) : uint64_t(-1);
        in.inodes[n] = _l.HasInode(_i) ? _l.Inode(_i) : 0;
        if( base_has_times ) {
            in.atimes[n] = _l.HasATime(_i) ? _l.ATime(_i) : 0;
            in.mtimes[n] = _l.HasMTime(_i) ? _l.MTime(_i) : 0;
            in.ctimes[n] = _l.HasCTime(_i) ? _l.CTime(_i) : 0;
            in.btimes[n] = _l.HasBTime(_i) ? _l.BTime(_i) : 0;
        }
        else { // lazy dates - only the items that actually have them (the freshly fetched ones)
            if( _l.HasATime(_i) )
                in.atimes.insert(n, _l.ATime(_i));
            if( _l.HasMTime(_i) )
                in.mtimes.insert(n, _l.MTime(_i));
            if( _l.HasCTime(_i) )
                in.ctimes.insert(n, _l.CTime(_i));
            if( _l.HasBTime(_i) )
                in.btimes.insert(n, _l.BTime(_i));
        }
        in.uids[n] = _l.HasUID(_i) ? _l.UID(_i) : 0;
        in.gids[n] = _l.HasGID(_i) ? _l.GID(_i) : 0;
        in.unix_flags[n] = _l.HasUnixFlags(_i) ? _l.UnixFlags(_i) : 0;
        if( _attrs.display_filenames && _l.HasDisplayFilename(_i) )
            in.display_filenames.insert(n, _l.DisplayFilename(_i));
        if( _attrs.add_times && _l.HasAddTime(_i) )
            in.add_times.insert(n, _l.AddTime(_i));
        if( _attrs.symlinks && _l.HasSymlink(_i) )
            in.symlinks.insert(n, _l.Symlink(_i));
        if( _attrs.tags && _l.HasTags(_i) ) {
            const auto tags = _l.Tags(_i);
            in.tags.emplace(n, std::vector<utility::Tags::Tag>(tags.begin(), tags.end()));
        }
        ++n;
    };

    const Attrs base_attrs = attrs_of(_base);
    const auto perf_copy_begin = std::chrono::steady_clock::now();
    size_t removed_pos = 0;
    for( unsigned i = 0, e = _base.Count(); i != e; ++i ) {
        if( removed_pos < _removed.size() && _removed[removed_pos] == i ) {
            ++removed_pos;
            continue;
        }
        append_item(_base, base_attrs, i);
    }
    for( auto &ptr : _appended ) {
        const Attrs attrs = attrs_of(*ptr);
        for( unsigned i = 0, e = ptr->Count(); i != e; ++i )
            append_item(*ptr, attrs, i);
    }

    assert(n == total);
    const auto perf_copied = std::chrono::steady_clock::now();
    VFSListingPtr patched = VFSListing::Build(std::move(in));
    if( std::getenv("NC_PERF_LOG") != nullptr ) {
        using namespace std::chrono;
        const auto perf_end = steady_clock::now();
        const auto ms = [](auto _from, auto _to) {
            return static_cast<double>(duration_cast<microseconds>(_to - _from).count()) / 1000.0;
        };
        std::fprintf(stderr,
                     "[perf] patchcopy n=%zu copy=%.1fms build=%.1fms\n",
                     total,
                     ms(perf_copy_begin, perf_copied),
                     ms(perf_copied, perf_end));
    }
    return patched;
}

} // namespace

@implementation PanelController {
    data::Model m_Data; // owns
    PanelView *m_View;  // create and owns

    // VFS changes observation
    vfs::HostDirObservationTicket m_UpdatesObservationTicket;

    // Names of the entries reported as changed, coalesced over a short time window so that a burst
    // of changes (e.g. unpacking an archive into a directory) results in a handful of patches
    // instead of a reload per file.
    std::vector<std::string> m_PendingChangedNames;
    bool m_PendingRefreshScheduled;

    // VFS listing fetch flags
    unsigned long m_VFSFetchingFlags;

    // flat view state
    bool m_FlatView;
    unsigned long m_FlatViewGeneration;
    std::string m_FlatViewRoot;
    VFSHostPtr m_FlatViewHost;

    // background operations' queues
    nc::base::SerialQueue m_DirectorySizeCountingQ;
    nc::base::SerialQueue m_DirectoryLoadingQ;
    nc::base::SerialQueue m_DirectoryReLoadingQ;
    nc::base::SerialQueue m_LazyDatesQ;
    bool m_LazyDates;
    bool m_LazySizes;
    bool m_FlatTruncationReported;
    // raw indices whose attributes are being fetched right now - the scroll notifications can
    // fire many times before the first result lands, so this keeps the work bounded
    ankerl::unordered_dense::set<unsigned> m_LazyPending;

    NCPanelQuickSearch *m_QuickSearch;

    // navigation support
    History m_History;

    // spinning indicator support
    bool m_IsAnythingWorksInBackground;

    // Tickets to show some external activities on this panel
    uint64_t m_NextActivityTicket;
    std::vector<uint64_t> m_ActivitiesTickets;
    spinlock m_ActivitiesTicketsLock;

    // delayed entry selection support
    struct {
        /**
         * Requested item name to select. Empty filename means that request is invalid.
         */
        std::string filename;

        /**
         * Time after which request is meaningless and should be removed
         */
        std::chrono::nanoseconds request_end;

        /**
         * Called when changed a cursor position
         */
        std::function<void()> done;
    } m_DelayedSelection;

    __weak MainWindowFilePanelState *m_FilePanelState;

    boost::container::static_vector<nc::config::Token, 3> m_ConfigObservers;
    nc::core::VFSInstanceManager *m_VFSInstanceManager;
    nc::panel::DirectoryAccessProvider *m_DirectoryAccessProvider;
    std::shared_ptr<PanelViewLayoutsStorage> m_Layouts;
    int m_ViewLayoutIndex;
    std::shared_ptr<const PanelViewLayout> m_AssignedViewLayout;
    PanelViewLayoutsStorage::ObservationTicket m_LayoutsObservation;
    ContextMenuProvider m_ContextMenuProvider;
    nc::utility::NativeFSManager *m_NativeFSManager;
    nc::vfs::NativeHost *m_NativeHost;

    unsigned long m_DataGeneration;
}

@synthesize view = m_View;
@synthesize data = m_Data;
@synthesize history = m_History;
@synthesize layoutIndex = m_ViewLayoutIndex;
@synthesize vfsFetchingFlags = m_VFSFetchingFlags;
@synthesize dataGeneration = m_DataGeneration;

- (instancetype)initWithView:(PanelView *)_panel_view
                     layouts:(std::shared_ptr<nc::panel::PanelViewLayoutsStorage>)_layouts
          vfsInstanceManager:(nc::core::VFSInstanceManager &)_vfs_mgr
     directoryAccessProvider:(nc::panel::DirectoryAccessProvider &)_directory_access_provider
         contextMenuProvider:(nc::panel::ContextMenuProvider)_context_menu_provider
             nativeFSManager:(nc::utility::NativeFSManager &)_native_fs_mgr
                  nativeHost:(nc::vfs::NativeHost &)_native_host
{
    assert(_layouts);
    assert(_context_menu_provider);

    static std::once_flag once;
    std::call_once(once, HeatUpConfigValues);

    self = [super init];
    if( self ) {
        m_Layouts = std::move(_layouts);
        m_VFSInstanceManager = &_vfs_mgr;
        m_NativeFSManager = &_native_fs_mgr;
        m_NativeHost = &_native_host;
        m_DirectoryAccessProvider = &_directory_access_provider;
        m_ContextMenuProvider = std::move(_context_menu_provider);
        m_History.SetVFSInstanceManager(_vfs_mgr);
        m_VFSFetchingFlags = 0;
        m_NextActivityTicket = 1;
        m_DataGeneration = 0;
        m_IsAnythingWorksInBackground = false;
        m_PendingRefreshScheduled = false;
        m_LazyDates = false;
        m_LazySizes = false;
        m_FlatTruncationReported = false;
        m_ViewLayoutIndex = m_Layouts->DefaultLayoutIndex();
        m_AssignedViewLayout = m_Layouts->DefaultLayout();

        __weak PanelController *weakself = self;
        auto on_change = [=] {
            dispatch_to_main_queue([=] { [static_cast<PanelController *>(weakself) updateSpinningIndicator]; });
        };
        m_DirectorySizeCountingQ.SetOnChange(on_change);
        m_DirectoryReLoadingQ.SetOnChange(on_change);
        m_DirectoryLoadingQ.SetOnChange(on_change);

        m_View = _panel_view;
        m_View.delegate = self;
        m_View.data = &m_Data;
        [m_View setPresentationLayout:*m_AssignedViewLayout];

        // wire up config changing notifications
        auto add_co = [&](const char *_path, SEL _sel) {
            m_ConfigObservers.emplace_back(GlobalConfig().Observe(_path, objc_callback(self, _sel)));
        };
        add_co(g_ConfigShowDotDotEntry, @selector(configVFSFetchFlagsChanged));
        add_co(g_ConfigShowLocalizedFilenames, @selector(configVFSFetchFlagsChanged));
        add_co(g_ConfigEnableFinderTags, @selector(configVFSFetchFlagsChanged));

        m_LayoutsObservation = m_Layouts->ObserveChanges(objc_callback(self, @selector(panelLayoutsChanged)));

        // loading config via simulating it's change
        [self configVFSFetchFlagsChanged];

        m_QuickSearch = [[NCPanelQuickSearch alloc] initWithData:m_Data delegate:self config:GlobalConfig()];
        __weak NCPanelQuickSearch *weak_qs = m_QuickSearch;
        auto callback = [weak_qs](NSString *_request) {
            if( NCPanelQuickSearch *const strong_qs = weak_qs )
                strong_qs.searchCriteria = _request;
        };
        m_View.headerView.searchRequestChangeCallback = std::move(callback);

        [m_View addKeystrokeSink:self];
        [m_View addKeystrokeSink:m_QuickSearch];
    }

    return self;
}

- (void)dealloc
{
    // we need to manually set data to nullptr, since PanelView can be destroyed a bit later due
    // to other strong pointers. in that case view will contain a dangling pointer, which can lead
    // to a crash.
    m_View.data = nullptr;
}

- (void)configVFSFetchFlagsChanged
{
    if( !ConfigShowDotDotEntry() )
        m_VFSFetchingFlags |= VFSFlags::F_NoDotDot;
    else
        m_VFSFetchingFlags &= ~VFSFlags::F_NoDotDot;

    if( ConfigShowLocalizedFilenames() )
        m_VFSFetchingFlags |= VFSFlags::F_LoadDisplayNames;
    else
        m_VFSFetchingFlags &= ~VFSFlags::F_LoadDisplayNames;

    if( ConfigEnableFinderTags() )
        m_VFSFetchingFlags |= VFSFlags::F_LoadTags;
    else
        m_VFSFetchingFlags &= ~VFSFlags::F_LoadTags;

    [self refreshPanel];
}

- (void)setState:(MainWindowFilePanelState *)state
{
    m_FilePanelState = state;
}

- (MainWindowFilePanelState *)state
{
    return m_FilePanelState;
}

- (NSWindow *)window
{
    return self.state.window;
}

- (NCMainWindowController *)mainWindowController
{
    return static_cast<NCMainWindowController *>(self.window.delegate);
}

- (bool)isUniform
{
    return m_Data.Listing().IsUniform();
}

- (bool)receivesUpdateNotifications
{
    return static_cast<bool>(m_UpdatesObservationTicket);
}

- (bool)ignoreDirectoriesOnSelectionByMask
{
    return GlobalConfig().GetBool(g_ConfigIgnoreDirectoriesOnMaskSelection);
}

- (void)copyOptionsFromController:(PanelController *)_pc
{
    if( !_pc )
        return;

    data::OptionsImporter{m_Data}.Import(data::OptionsExporter{_pc.data}.Export());
    [self.view dataUpdated];
    [self.view dataSortingHasChanged];
    self.layoutIndex = _pc.layoutIndex;
}

- (bool)isActive
{
    return m_View.active;
}

namespace {

// True when the sort order is derived from the timestamps or the sizes - the lazy modes don't
// carry them, so a full attribute pass is needed before such a sort can make sense.
bool SortModeNeedsAttributes(const nc::panel::data::SortMode &_mode) noexcept
{
    using M = nc::panel::data::SortMode;
    switch( _mode.sort ) {
        case M::SortBySize:
        case M::SortBySizeRev:
        case M::SortByModTime:
        case M::SortByModTimeRev:
        case M::SortByBirthTime:
        case M::SortByBirthTimeRev:
        case M::SortByAddTime:
        case M::SortByAddTimeRev:
        case M::SortByAccessTime:
        case M::SortByAccessTimeRev:
            return true;
        default:
            return false;
    }
}

} // namespace
- (void)changeSortingModeTo:(data::SortMode)_mode
{
    if( _mode != m_Data.SortMode() ) {
        const auto pers = CursorBackup{m_View.curpos, m_Data};

        m_Data.SetSortMode(_mode);

        m_View.curpos = pers.RestoredCursorPosition();

        [m_View dataSortingHasChanged];
        [m_View dataUpdated];
        [self markRestorableStateAsInvalid];

        if( SortModeNeedsAttributes(_mode) && (m_LazyDates || m_LazySizes) ) {
            // the listing doesn't carry what this sort needs - reload it with the full attributes
            m_LazyDates = false;
            m_LazySizes = false;
            [self refreshPanel];
        }
    }
}

- (void)changeHardFilteringTo:(data::HardFilter)_filter
{
    if( _filter != m_Data.HardFiltering() ) {
        const auto pers = CursorBackup{m_View.curpos, m_Data};

        m_Data.SetHardFiltering(_filter);

        m_View.curpos = pers.RestoredCursorPosition();
        [m_View dataUpdated];
        [self markRestorableStateAsInvalid];
    }
}

- (void)reloadRefreshedListing:(const VFSListingPtr &)_ptr
{
    assert(dispatch_is_main_queue());
    Log::Info("Reloading refreshed listing, {}", _ptr->IsUniform() ? _ptr->Directory().c_str() : "uniform");

    const auto pers = CursorBackup{m_View.curpos, m_Data};

    m_Data.ReLoad(_ptr);
    [m_View dataUpdated];
    [m_QuickSearch dataUpdated];

    if( [self checkAgainstRequestedFocusing] ) {
        Log::Trace("Cursor position was changed by requested focusing, skipping RestoredCursorPosition()");
    }
    else {
        m_View.curpos = pers.RestoredCursorPosition();
    }

    [self onCursorChanged];
    [m_View setNeedsDisplay];
}

// Coalesces the changes reported by FSEvents over a short window: a bulk operation then costs a
// single patch instead of one per reported file.
- (void)accumulateChangedNames:(const std::vector<std::string> &)_names
{
    if( _names.empty() )
        return;
    m_PendingChangedNames.insert(m_PendingChangedNames.end(), _names.begin(), _names.end());
    [self schedulePendingRefresh];
}

- (void)schedulePendingRefresh
{
    if( m_PendingRefreshScheduled )
        return;
    m_PendingRefreshScheduled = true;
    __weak PanelController *weak_self = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
      PanelController *const pc = weak_self;
      if( pc == nil )
          return;
      pc->m_PendingRefreshScheduled = false;

      // don't step on the toes of an operation that is already running - try again a bit later
      if( !pc->m_DirectoryLoadingQ.Empty() || pc->m_DirectoryReLoadingQ.Length() > 0 ) {
          [pc schedulePendingRefresh];
          return;
      }

      std::vector<std::string> names;
      names.swap(pc->m_PendingChangedNames);
      if( names.empty() )
          return;
      std::ranges::sort(names);
      names.erase(std::ranges::unique(names).begin(), names.end());
      if( names.size() > 4096 ) {
          // too many to patch, the bookkeeping would cost more than a reload
          [pc refreshPanel];
          return;
      }
      [pc refreshPanelIncrementallyWithChangedNames:std::move(names)];
    });
}

- (void)refreshPanelIncrementallyWithChangedNames:(std::vector<std::string>)_names
{
    Log::Debug("[PanelController refreshPanelIncrementallyWithChangedNames] {} name(s)", _names.size());

    if( m_FlatView || !self.isUniform || _names.size() > 128 ) {
        [self refreshPanel];
        return;
    }
    if( !m_DirectoryLoadingQ.Empty() || m_DirectoryReLoadingQ.Length() > 0 ) {
        // a load/reload is already in flight - replay these names once it's finished
        [self accumulateChangedNames:_names];
        return;
    }

    const VFSListingPtr listing = m_Data.ListingPtr();
    if( listing == nullptr || listing->Count() == 0 || !listing->IsUniform() || !listing->HasCommonHost() ||
        !listing->HasCommonDirectory() ) {
        [self refreshPanel];
        return;
    }

    const VFSHostPtr host = self.vfs;
    const std::string directory = m_Data.DirectoryPathWithTrailingSlash();
    if( host == nullptr || directory.empty() ) {
        [self refreshPanel];
        return;
    }

    struct Change {
        std::string name;
        int old_index;
    };
    std::vector<Change> changes;
    changes.reserve(_names.size());
    for( const auto &name : _names ) {
        // m_Data is a main-thread-only object, so resolve the names against the listing here
        const auto indices = m_Data.RawIndicesForName(name);
        changes.push_back(Change{name, indices.empty() ? -1 : static_cast<int>(indices.front())});
    }

    const unsigned long fetch_flags = m_VFSFetchingFlags;
    __weak PanelController *weak_self = self;
    m_DirectoryReLoadingQ.Run([=] {
        if( m_DirectoryReLoadingQ.IsStopped() )
            return;
        const auto perf_begin = std::chrono::steady_clock::now();

        std::vector<unsigned> removed;
        std::vector<VFSListingPtr> appended;
        bool need_full_reload = false;
        for( const auto &change : changes ) {
            const std::expected<VFSListingPtr, Error> fetched =
                host->FetchSingleItemListing(directory + change.name, fetch_flags, [] { return false; });
            if( fetched ) {
                appended.emplace_back(*fetched);
                if( change.old_index >= 0 )
                    removed.emplace_back(static_cast<unsigned>(change.old_index));
            }
            else if( fetched.error().Domain() == Error::POSIX && fetched.error().Code() == ENOENT ) {
                // the entry is really gone
                if( change.old_index >= 0 )
                    removed.emplace_back(static_cast<unsigned>(change.old_index));
            }
            else {
                // something unusual, e.g. a permission problem - let the slow path deal with it
                if( std::getenv("NC_PERF_LOG") != nullptr )
                    std::fprintf(stderr,
                                 "[perf] incr.fetch-failed domain=%s code=%lld name=%s\n",
                                 fetched.error().Domain().c_str(),
                                 static_cast<long long>(fetched.error().Code()),
                                 change.name.c_str());
                need_full_reload = true;
                break;
            }
        }

        if( need_full_reload ) {
            dispatch_to_main_queue([=] {
                if( PanelController *const pc = weak_self )
                    [pc refreshPanel];
            });
            return;
        }

        if( removed.empty() && appended.empty() )
            return;

        std::ranges::sort(removed);
        removed.erase(std::ranges::unique(removed).begin(), removed.end());
        const unsigned appended_count = static_cast<unsigned>(appended.size());
        const auto perf_fetched = std::chrono::steady_clock::now();
        // the bulk implementation is the fast path, the generic one handles the listings that
        // carry per-item extras (display names, tags, symlinks)
        VFSListingPtr patched = VFSListing::ProducePatchedListing(*listing, removed, appended);
        if( patched == nullptr )
            patched = ProducePatchedListingGeneric(*listing, removed, appended);
        if( std::getenv("NC_PERF_LOG") != nullptr ) {
            using namespace std::chrono;
            const auto perf_end = steady_clock::now();
            const auto ms = [](auto _from, auto _to) {
                return static_cast<double>(duration_cast<microseconds>(_to - _from).count()) / 1000.0;
            };
            std::fprintf(stderr,
                         "[perf] incr k=%zu removed=%zu appended=%u mem=%.1fMB fetch=%.1fms patch=%.1fms\n",
                         changes.size(),
                         removed.size(),
                         appended_count,
                         patched ? static_cast<double>(patched->ApproximateMemoryFootprint()) / (1024.0 * 1024.0) : 0.0,
                         ms(perf_begin, perf_fetched),
                         ms(perf_fetched, perf_end));
        }
        if( patched == nullptr ) {
            Log::Warn("[PanelController] failed to patch the listing, falling back to a full reload");
            dispatch_to_main_queue([=] {
                if( PanelController *const pc = weak_self )
                    [pc refreshPanel];
            });
            return;
        }

        dispatch_to_main_queue([=] {
            PanelController *const pc = weak_self;
            if( pc == nil )
                return;
            if( pc.currentDirectoryPath != directory )
                return;
            [pc applyPatchedListing:patched removed:removed appended:appended_count];
        });
    });
}

- (void)applyPatchedListing:(const VFSListingPtr &)_listing
                    removed:(const std::vector<unsigned> &)_removed
                   appended:(unsigned)_appended
{
    Log::Info(
        "Applying a patched listing, {} entries ({} dropped, {} added)", _listing->Count(), _removed.size(), _appended);
    [self CancelBackgroundOperations];
    const auto perf_begin = std::chrono::steady_clock::now();
    const auto pers = CursorBackup{m_View.curpos, m_Data};
    m_Data.ApplyPatchedListing(_listing, _removed, _appended);
    const auto perf_patched = std::chrono::steady_clock::now();
    m_DataGeneration++;
    const auto perf_view_begin = std::chrono::steady_clock::now();
    [m_View dataUpdated];
    const auto perf_view_done = std::chrono::steady_clock::now();
    [m_QuickSearch dataUpdated];
    const auto perf_qs_done = std::chrono::steady_clock::now();
    if( [self checkAgainstRequestedFocusing] ) {
        Log::Trace("Cursor position was changed by requested focusing, skipping RestoredCursorPosition()");
    }
    else {
        m_View.curpos = pers.RestoredCursorPosition();
    }
    [self onCursorChanged];
    [m_View setNeedsDisplay];
    if( std::getenv("NC_PERF_LOG") != nullptr ) {
        using namespace std::chrono;
        const auto perf_end = steady_clock::now();
        const auto ms = [](auto _from, auto _to) {
            return static_cast<double>(duration_cast<microseconds>(_to - _from).count()) / 1000.0;
        };
        std::fprintf(stderr,
                     "[perf] incr.ui n=%u model=%.1fms view=%.1fms qs=%.1fms rest=%.1fms total=%.1fms\n",
                     _listing->Count(),
                     ms(perf_begin, perf_patched),
                     ms(perf_view_begin, perf_view_done),
                     ms(perf_view_done, perf_qs_done),
                     ms(perf_qs_done, perf_end),
                     ms(perf_begin, perf_end));
    }
}

- (void)fetchLazyDatesForTopEntries
{
    [self fetchLazyDatesForSortedRange:NSMakeRange(0, 200)];
}

- (void)fetchLazyDatesForSortedRange:(NSRange)_range
{
    assert(dispatch_is_main_queue());
    if( !m_LazyDates && !m_LazySizes )
        return;
    const VFSListingPtr listing = m_Data.ListingPtr();
    if( !listing || listing->Count() == 0 )
        return;

    std::vector<unsigned> raw_indices;
    const int total = m_Data.SortedEntriesCount();
    const int begin = static_cast<int>(std::min<NSUInteger>(_range.location, static_cast<NSUInteger>(total)));
    const int end =
        static_cast<int>(std::min<NSUInteger>(_range.location + _range.length, static_cast<NSUInteger>(total)));
    raw_indices.reserve(static_cast<size_t>(std::max(0, end - begin)));
    for( int i = begin; i < end; ++i ) {
        const int raw_index = m_Data.RawIndexForSortIndex(i);
        if( raw_index < 0 )
            continue;
        if( m_LazyPending.contains(static_cast<unsigned>(raw_index)) )
            continue;
        const bool need_dates = m_LazyDates && !m_Data.FetchedTimesAtRawPos(raw_index).has_value();
        const bool need_size = m_LazySizes && !m_Data.HasFetchedSize(static_cast<unsigned>(raw_index));
        if( !need_dates && !need_size )
            continue;
        raw_indices.push_back(static_cast<unsigned>(raw_index));
    }
    if( raw_indices.empty() )
        return;
    for( const unsigned raw_index : raw_indices )
        m_LazyPending.insert(raw_index);

    const auto host = listing->Host();
    const auto directory = listing->Directory();
    std::vector<std::string> paths;
    paths.reserve(raw_indices.size());
    for( auto raw_index : raw_indices )
        paths.emplace_back(directory + listing->Filename(raw_index));

    m_LazyDatesQ.Run([self, paths = std::move(paths), raw_indices = std::move(raw_indices), host] {
        struct FetchedEntry {
            unsigned raw_index;
            data::Model::FetchedTimes times;
            uint64_t size;
        };
        std::vector<FetchedEntry> fetched;
        fetched.reserve(paths.size());
        for( size_t i = 0; i != paths.size(); ++i ) {
            if( m_LazyDatesQ.IsStopped() )
                return;
            const auto item = host->FetchSingleItemListing(paths[i], VFSFlags::F_NoFollow, {});
            if( !item || (*item)->Count() != 1 )
                continue;
            const auto &entry = **item;
            data::Model::FetchedTimes times;
            times.atime = entry.HasATime(0) ? entry.ATime(0) : 0;
            times.mtime = entry.HasMTime(0) ? entry.MTime(0) : 0;
            times.ctime = entry.HasCTime(0) ? entry.CTime(0) : 0;
            times.btime = entry.HasBTime(0) ? entry.BTime(0) : 0;
            times.addtime = entry.HasAddTime(0) ? entry.AddTime(0) : -1;
            const uint64_t size = entry.HasSize(0) ? entry.Size(0) : std::numeric_limits<uint64_t>::max();
            fetched.emplace_back(raw_indices[i], times, size);
        }
        if( fetched.empty() )
            return;
        dispatch_to_main_queue([self, fetched = std::move(fetched), raw_indices = std::move(raw_indices)] {
            for( const unsigned raw_index : raw_indices )
                m_LazyPending.erase(raw_index);
            if( !m_LazyDates && !m_LazySizes )
                return;
            for( const auto &i : fetched ) {
                if( m_LazyDates )
                    m_Data.SetFetchedTimes(i.raw_index, i.times);
                if( m_LazySizes && i.size != std::numeric_limits<uint64_t>::max() )
                    m_Data.SetFetchedSize(i.raw_index, i.size);
            }
            // Repaint only the rows that are on screen. A full dataUpdated() here would rebuild the
            // view's contents (the brief view even reloads its collection view), which resets the
            // scroll position - i.e. the view would refuse to scroll while the dates are being
            // pulled in.
            [m_View volatileDataChanged];
        });
    });
}

- (void)installPreparedReload:(data::Model::PreparedLoad &&)_prepared
{
    assert(dispatch_is_main_queue());
    [self CancelBackgroundOperations];
    const auto pers = CursorBackup{m_View.curpos, m_Data};
    m_Data.InstallLoad(std::move(_prepared));
    m_DataGeneration++;
    [m_View dataUpdated];
    [m_QuickSearch dataUpdated];
    if( [self checkAgainstRequestedFocusing] ) {
        Log::Trace("Cursor position was changed by requested focusing, skipping RestoredCursorPosition()");
    }
    else {
        m_View.curpos = pers.RestoredCursorPosition();
    }
    [self onCursorChanged];
    [m_View setNeedsDisplay];
}

- (void)refreshPanelDiscardingCaches:(bool)_force
{
    Log::Debug("refreshPanelDiscardingCaches:{} was called", _force);

    if( m_View == nil )
        return; // guard agains calls from init process
    if( &m_Data.Listing() == VFSListing::EmptyListing().get() )
        return; // guard agains calls from init process

    if( !m_DirectoryLoadingQ.Empty() ) {
        Log::Debug("Discarding the refresh request as there is a load request in place");
        return; // reducing overhead
    }

    if( m_DirectoryReLoadingQ.Length() >= 2 ) {
        Log::Debug("Discarding the refresh request as the current length of reload queue is {}",
                   m_DirectoryReLoadingQ.Length());
        return; // reducing overhead
    }

    // later: maybe check PanelType somehow

    if( m_FlatView ) {
        [self reloadFlatView];
        return;
    }

    if( self.isUniform ) {
        const auto fetch_flags = m_VFSFetchingFlags | (_force ? VFSFlags::F_ForceRefresh : 0) |
                                 (m_LazyDates ? VFSFlags::F_NoTimes : 0) | (m_LazySizes ? VFSFlags::F_NoSizes : 0);
        const auto dirpath = m_Data.DirectoryPathWithTrailingSlash();
        const auto vfs = self.vfs;
        // the model is main-thread-only, so its state is captured here and the heavy merging is
        // done on the reloading queue
        const auto snapshot = std::make_shared<data::Model::ReloadSnapshot>(m_Data.SnapshotForReload());

        m_DirectoryReLoadingQ.Run([=] {
            if( m_DirectoryReLoadingQ.IsStopped() ) {
                Log::Trace("[PanelController refreshPanelDiscardingCaches] cancelled the refresh");
                return;
            }
            const std::expected<VFSListingPtr, Error> listing =
                vfs->FetchDirectoryListing(dirpath, fetch_flags, [&] { return m_DirectoryReLoadingQ.IsStopped(); });
            if( m_DirectoryReLoadingQ.IsStopped() ) {
                Log::Trace("[PanelController refreshPanelDiscardingCaches] cancelled the refresh");
                return;
            }
            std::shared_ptr<data::Model::PreparedLoad> prepared;
            if( listing ) {
                try {
                    prepared = std::make_shared<data::Model::PreparedLoad>(
                        data::Model::PrepareReload(*listing, std::move(*snapshot)));
                } catch( ... ) {
                    prepared.reset();
                }
            }
            dispatch_to_main_queue([=] {
                if( self.currentDirectoryPath != dirpath ) {
                    Log::Debug(
                        "[PanelController refreshPanelDiscardingCaches]: discarding a stale request to refresh '{}'",
                        dirpath);
                    return;
                }

                if( prepared )
                    [self installPreparedReload:std::move(*prepared)];
                else if( listing )
                    [self reloadRefreshedListing:*listing];
                else
                    [self recoverFromInvalidDirectory];
            });
        });
    }
    else {
        m_DirectoryReLoadingQ.Run([=] {
            if( m_DirectoryReLoadingQ.IsStopped() )
                return;
            const auto listing = VFSListing::ProduceUpdatedTemporaryPanelListing(
                m_Data.Listing(), [&] { return m_DirectoryReLoadingQ.IsStopped(); });
            if( listing )
                dispatch_to_main_queue([=] { [self reloadRefreshedListing:listing]; });
        });
    }
}

- (void)refreshPanel
{
    Log::Trace("[Panel refreshPanel] was called");
    [self refreshPanelDiscardingCaches:false];
}

- (void)forceRefreshPanel
{
    Log::Trace("[Panel forceRefreshPanel] was called");
    [self refreshPanelDiscardingCaches:true];
}

- (int)bidForHandlingKeyDown:(NSEvent *)_event forPanelView:(PanelView *) [[maybe_unused]] _panel_view
{
    // this is doubtful, actually. need to figure out something clearer:
    [self clearFocusingRequest]; // on any key press we clear entry selection request, if any

    const auto keycode = _event.keyCode;
    if( keycode == 53 ) { // Esc button
        if( m_IsAnythingWorksInBackground )
            return panel::view::BiddingPriority::Default;
        if( self.quickLook || self.briefSystemOverview )
            return panel::view::BiddingPriority::Default;
        ;
    }

    return panel::view::BiddingPriority::Skip;
}

- (void)handleKeyDown:(NSEvent *)_event forPanelView:(PanelView *) [[maybe_unused]] _panel_view
{
    const auto keycode = _event.keyCode;
    if( keycode == 53 ) { // Esc button
        if( m_IsAnythingWorksInBackground ) {
            [self CancelBackgroundOperations];
            return;
        }
        if( self.quickLook || self.briefSystemOverview ) {
            [self.state closeAttachedUI:self];
            return;
        }
    }
}

- (void)calculateSizesOfItems:(const std::vector<VFSListingItem> &)_items
{
    if( !_items.empty() ) {
        m_DirectorySizeCountingQ.Run([=] { [self doCalculateSizesOfItems:_items]; });
    }
}

- (void)doCalculateSizesOfItems:(const std::vector<VFSListingItem> &)_items
{
    dispatch_assert_background_queue();
    assert(!_items.empty());

    // divide all items into maximum of g_MaxSizeCalculationCommitBatches batches as equally as
    // possible
    const size_t items_count = _items.size();
    const size_t batches = std::min(g_MaxSizeCalculationCommitBatches, items_count);
    const size_t items_per_batch = items_count / batches;
    const size_t items_leftover = items_count - (items_per_batch * batches);

    for( size_t batch = 0, items_first = 0, items_last = 0; batch != batches; ++batch ) {
        items_first = items_last;
        items_last += items_per_batch + (batch < items_leftover ? 1 : 0);

        panel::CalculatedSizesBatch calculated;
        calculated.items.reserve(items_last - items_first);
        calculated.sizes.reserve(items_last - items_first);

        for( size_t item_index = items_first; item_index != items_last; ++item_index ) {
            if( m_DirectorySizeCountingQ.IsStopped() )
                return;

            auto &i = _items[item_index];
            if( !i.IsDir() )
                continue;

            const std::expected<uint64_t, Error> result = i.Host()->CalculateDirectorySize(
                !i.IsDotDot() ? i.Path() : i.Directory(), [=] { return m_DirectorySizeCountingQ.IsStopped(); });

            if( !result )
                continue; // silently skip items that caused erros while calculating size

            calculated.items.emplace_back(i);
            calculated.sizes.emplace_back(*result);
        }

        if( calculated.items.empty() )
            continue;

        auto commit_batch = [=, calculated = std::move(calculated)] {
            assert(!calculated.items.empty());

            // may cause re-sorting if current sorting is by size so save the cursor
            const auto pers = CursorBackup{m_View.curpos, m_Data};

            size_t num_set = 0;
            if( &m_Data.Listing() == calculated.items.front().Listing().get() ) {
                // the listing is the same, can use indices directly
                std::vector<unsigned> raw_indices(calculated.items.size());
                std::ranges::transform(calculated.items, raw_indices.begin(), [](auto &i) { return i.Index(); });
                num_set = m_Data.SetCalculatedSizesForDirectories(raw_indices, calculated.sizes);
            }
            else {
                // the listing has changed, need to use indirects: filename and directory
                std::vector<std::string_view> filenames(calculated.items.size());
                std::vector<std::string_view> directories(calculated.items.size());
                std::ranges::transform(
                    calculated.items, filenames.begin(), [](auto &i) { return std::string_view{i.Filename()}; });
                std::ranges::transform(
                    calculated.items, directories.begin(), [](auto &i) { return std::string_view{i.Directory()}; });
                num_set = m_Data.SetCalculatedSizesForDirectories(filenames, directories, calculated.sizes);
            }
            if( num_set != 0 ) {
                [m_View dataUpdated];
                [m_View volatileDataChanged];
                m_View.curpos = pers.RestoredCursorPosition();
            }
        };
        dispatch_to_main_queue(std::move(commit_batch));
    }
}

- (void)CancelBackgroundOperations
{
    m_DirectorySizeCountingQ.Stop();
    m_DirectoryLoadingQ.Stop();
    m_DirectoryReLoadingQ.Stop();
}

- (void)updateSpinningIndicator
{
    dispatch_assert_main_queue();

    size_t ext_activities_no = call_locked(m_ActivitiesTicketsLock, [&] { return m_ActivitiesTickets.size(); });
    bool is_anything_working = !m_DirectorySizeCountingQ.Empty() || !m_DirectoryLoadingQ.Empty() ||
                               !m_DirectoryReLoadingQ.Empty() || ext_activities_no > 0;

    if( is_anything_working == m_IsAnythingWorksInBackground )
        return; // nothing to update;

    if( is_anything_working ) {
        // there should be 100ms of workload before the user gets the spinning indicator
        dispatch_to_main_queue_after(100ms, [=] {
            // need to check if task was already done
            if( m_IsAnythingWorksInBackground )
                [m_View.busyIndicator startAnimation:nil];
        });
    }
    else
        [m_View.busyIndicator stopAnimation:nil];

    m_IsAnythingWorksInBackground = is_anything_working;
}

- (void)selectEntriesWithFilenames:(const std::vector<std::string> &)_filenames
{
    for( auto &i : _filenames )
        m_Data.CustomFlagsSelectSorted(m_Data.SortedIndexForName(i), true);
    [m_View volatileDataChanged];
}

- (void)setEntriesSelection:(const std::vector<bool> &)_selection
{
    if( m_Data.CustomFlagsSelectSorted(_selection) )
        [m_View volatileDataChanged];
}

- (void)setSelectionForItemAtIndex:(int)_index selected:(bool)_selected
{
    if( m_Data.VolatileDataAtSortPosition(_index).is_selected() == _selected )
        return;
    m_Data.CustomFlagsSelectSorted(_index, _selected);
    [m_View volatileDataChanged];
}

- (void)onPathChanged
{
    Log::Trace("[PanelController onPathChanged] was called");
    // update directory changes notification ticket
    __weak PanelController *weakself = self;
    m_UpdatesObservationTicket.reset();
    m_PendingChangedNames.clear();
    if( self.isUniform ) {
        const std::string current_directory_path = self.currentDirectoryPath;
        auto dir_change_callback = [=](std::span<const std::string> _changed_names) {
            // the handler may inject changes from different threads - hand them over by value
            const std::vector<std::string> changed_names(_changed_names.begin(), _changed_names.end());
            dispatch_to_main_queue([=] {
                Log::Debug("Got a notification about a directory change: '{}', {} changed entr{}",
                           current_directory_path,
                           changed_names.size(),
                           changed_names.size() == 1 ? "y" : "ies");
                PanelController *const pc = weakself;
                if( pc == nil )
                    return;
                if( pc.currentDirectoryPath != current_directory_path ) {
                    Log::Debug("Discarded a stale directory change notification");
                    return;
                }
                if( !changed_names.empty() ) {
                    if( std::getenv("NC_PERF_LOG") != nullptr )
                        std::fprintf(stderr, "[perf] change.paths n=%zu\n", changed_names.size());
                    [pc accumulateChangedNames:changed_names];
                }
                else {
                    if( std::getenv("NC_PERF_LOG") != nullptr )
                        std::fprintf(stderr, "[perf] change.no_paths -> full refresh\n");
                    [pc refreshPanel];
                }
            });
        };
        m_UpdatesObservationTicket =
            self.vfs->ObserveDirectoryChangesWithPaths(current_directory_path, std::move(dir_change_callback));
    }

    [self clearFocusingRequest];
    [m_QuickSearch setSearchCriteria:nil];

    [self.state PanelPathChanged:self];
    [self onCursorChanged];
    [self updateAttachedBriefSystemOverview];
    m_History.Put(m_Data.Listing());

    [self markRestorableStateAsInvalid];
}

- (void)markRestorableStateAsInvalid
{
    if( auto wc = objc_cast<NCMainWindowController>(self.state.window.delegate) )
        [wc invalidateRestorableState];
}

- (void)panelView:(PanelView *) [[maybe_unused]] _view visibleSortedRangeChangedTo:(NSRange)_range
{
    if( (!m_LazyDates && !m_LazySizes) || _range.location == NSNotFound )
        return;
    // pull in a bit more than what's visible, so that a small scroll doesn't need a round trip
    const NSUInteger margin = 100;
    const NSUInteger begin = _range.location > margin ? _range.location - margin : 0;
    [self fetchLazyDatesForSortedRange:NSMakeRange(begin, _range.length + 2 * margin)];
}

- (void)onCursorChanged
{
    [self updateAttachedQuickLook];
    if( m_LazyDates || m_LazySizes ) {
        // the attributes are fetched on demand - top up the area around the cursor, so that moving
        // through the list with the keyboard or clicking does pull them in
        const int cursor = m_View.curpos;
        if( cursor >= 0 )
            [self fetchLazyDatesForSortedRange:NSMakeRange(std::max(0, cursor - 20), 220)];
    }
}

- (void)updateAttachedQuickLook
{
    if( auto ql = self.quickLook )
        if( auto i = self.view.item )
            [ql previewVFSItem:vfs::VFSPath{i.Host(), i.Path()} forPanel:self];
}

- (void)updateAttachedBriefSystemOverview
{
    if( const auto bso = self.briefSystemOverview ) {
        if( auto i = self.view.item )
            [bso UpdateVFSTarget:i.Directory() host:i.Host()];
        else if( self.isUniform )
            [bso UpdateVFSTarget:self.currentDirectoryPath host:self.vfs];
    }
}

- (void)panelViewCursorChanged:(PanelView *) [[maybe_unused]] _view
{
    [self onCursorChanged];
}

- (NCPanelContextMenu *)panelView:(PanelView *)_view requestsContextMenuForItemNo:(int)_sort_pos
{
    dispatch_assert_main_queue();

    const auto clicked_item = m_Data.EntryAtSortPosition(_sort_pos);
    if( !clicked_item || clicked_item.IsDotDot() )
        return nil;

    const auto clicked_item_vd = m_Data.VolatileDataAtSortPosition(_sort_pos);

    std::vector<VFSListingItem> vfs_items;
    if( !clicked_item_vd.is_selected() )
        vfs_items.emplace_back(clicked_item); // only clicked item
    else
        vfs_items = m_Data.SelectedEntriesSorted(); // all selected items

    for( auto &i : vfs_items )
        m_Data.VolatileDataAtRawPosition(i.Index()).toggle_highlight(true);
    [_view volatileDataChanged];

    NCPanelContextMenu *const menu = m_ContextMenuProvider(std::move(vfs_items), self);
    return menu;
}

- (void)contextMenuDidClose:(NSMenu *) [[maybe_unused]] _menu
{
    m_Data.CustomFlagsClearHighlights();
    [m_View volatileDataChanged];
}

static void ShowAlertAboutInvalidFilename(const std::string &_filename)
{
    Alert *const a = [[Alert alloc] init];
    auto fn = [NSString stringWithUTF8StdString:_filename];
    if( fn.length > 256 )
        fn = [[fn substringToIndex:256] stringByAppendingString:@"..."];

    const auto msg =
        NSLocalizedString(@"The name “%@” can’t be used.", "Message text when user is entering an invalid filename");
    a.messageText = [NSString stringWithFormat:msg, fn];
    const auto info = NSLocalizedString(@"Try using a name with fewer characters or without punctuation marks.",
                                        "Informative text when user is entering an invalid filename");
    a.informativeText = info;
    a.alertStyle = NSAlertStyleCritical;
    [a runModal];
}

- (void)requestQuickRenamingOfItem:(VFSListingItem)_item to:(const std::string &)_filename
{
    if( _filename == "." || _filename == ".." || !_item || _item.IsDotDot() || !_item.Host()->IsWritable() ||
        _filename == _item.Filename() )
        return;

    const auto &target_fn = _filename;

    // checking for invalid symbols
    if( !_item.Host()->ValidateFilename(target_fn) ) {
        ShowAlertAboutInvalidFilename(target_fn);
        return;
    }

    nc::ops::CopyingOptions opts;
    opts.docopy = false;

    const auto op = std::make_shared<nc::ops::Copying>(
        std::vector<VFSListingItem>{_item}, _item.Directory() + target_fn, _item.Host(), opts);

    if( self.isUniform && m_View.item && m_View.item.Filename() == _item.Filename() ) {
        std::string curr_path = self.currentDirectoryPath;
        auto curr_vfs = self.vfs;
        op->ObserveUnticketed(nc::ops::Operation::NotifyAboutCompletion, [=] {
            if( self.currentDirectoryPath == curr_path && self.vfs == curr_vfs )
                dispatch_to_main_queue([=] {
                    DelayedFocusing req;
                    req.filename = target_fn;
                    [self scheduleDelayedFocusing:req];
                    [self refreshPanel];
                });
        });
    }

    [self.mainWindowController enqueueOperation:op];
}

- (void)panelViewDidBecomeFirstResponder
{
    [self.state activePanelChangedTo:self];
    [self updateAttachedQuickLook];
    [self updateAttachedBriefSystemOverview];
}

- (void)changeDataOptions:(const std::function<void(nc::panel::data::Model &_data)> &)_workload
{
    assert(dispatch_is_main_queue());
    assert(_workload);

    const auto pers = CursorBackup{m_View.curpos, m_Data};

    _workload(m_Data);

    [m_View dataUpdated];
    [m_View dataSortingHasChanged];
    m_View.curpos = pers.RestoredCursorPosition();
}

- (ActivityTicket)registerExtActivity
{
    auto ticket = call_locked(m_ActivitiesTicketsLock, [&] {
        m_ActivitiesTickets.emplace_back(m_NextActivityTicket);
        return ActivityTicket(self, m_NextActivityTicket++);
    });
    dispatch_to_main_queue([=] { [self updateSpinningIndicator]; });
    return ticket;
}

- (void)finishExtActivityWithTicket:(uint64_t)_ticket
{
    {
        auto lock = std::lock_guard{m_ActivitiesTicketsLock};
        auto i = std::ranges::find(m_ActivitiesTickets, _ticket);
        if( i == end(m_ActivitiesTickets) )
            return;
        m_ActivitiesTickets.erase(i);
    }
    dispatch_to_main_queue([=] { [self updateSpinningIndicator]; });
}

- (void)setLayoutIndex:(int)layoutIndex
{
    if( m_ViewLayoutIndex != layoutIndex ) {
        if( auto l = m_Layouts->GetLayout(layoutIndex) )
            if( !l->is_disabled() ) {
                m_ViewLayoutIndex = layoutIndex;
                m_AssignedViewLayout = l;
                [m_View setPresentationLayout:*l];
                [self markRestorableStateAsInvalid];
            }
    }
}

- (void)panelLayoutsChanged
{
    if( auto l = m_Layouts->GetLayout(m_ViewLayoutIndex) ) {
        if( m_AssignedViewLayout && *m_AssignedViewLayout == *l )
            return;

        if( !l->is_disabled() ) {
            m_AssignedViewLayout = l;
            [m_View setPresentationLayout:*l];
        }
        else {
            m_AssignedViewLayout = nc::panel::PanelViewLayoutsStorage::LastResortLayout();
            [m_View setPresentationLayout:*m_AssignedViewLayout];
        }
    }
}

- (void)panelViewDidChangePresentationLayout
{
    PanelViewLayout layout;
    layout.name = m_AssignedViewLayout->name;
    layout.layout = [m_View presentationLayout];

    if( layout != *m_AssignedViewLayout )
        m_Layouts->ReplaceLayout(std::move(layout), m_ViewLayoutIndex);
}

- (void)commitCancelableLoadingTask:(std::function<void(const std::function<bool()> &_is_cancelled)>)_task
{
    m_DirectoryLoadingQ.Run(
        [task = std::move(_task), sq = &m_DirectoryLoadingQ] { task([sq] { return sq->IsStopped(); }); });
}

- (bool)probeDirectoryAccessForRequest:(DirectoryChangeRequest &)_request
{
    const auto &directory = _request.RequestedDirectory;
    auto &vfs = *_request.VFS;
    auto &access_provider = *m_DirectoryAccessProvider;
    const auto has_access = access_provider.HasAccess(self, directory, vfs);
    if( has_access ) {
        return true;
    }
    else {
        if( _request.InitiatedByUser )
            return access_provider.RequestAccessSync(self, directory, vfs);
        else
            return false;
    }
}

- (std::expected<void, Error>)doGoToDirWithContext:(std::shared_ptr<DirectoryChangeRequest>)_request
                                          sortMode:(data::SortMode)_sort_mode
                                        hardFilter:(data::HardFilter)_hard_filter
                                        softFilter:(data::TextualFilter)_soft_filter
                                   previousListing:(const VFSListingPtr &)_previous_listing
{
    assert(_request != nullptr);
    assert(_request->VFS != nullptr);
    Log::Debug("[PanelController doGoToDirWithContext] was called with {}", *_request);

    try {
        if( ![self probeDirectoryAccessForRequest:*_request] ) {
            return std::unexpected(Error{Error::POSIX, EPERM});
        }

        auto directory = _request->RequestedDirectory;
        auto &vfs = *_request->VFS;
        const auto canceller = VFSCancelChecker([&] { return m_DirectoryLoadingQ.IsStopped(); });

        bool big_directory = false;
        // Showing nothing for the seconds a huge directory takes to enumerate is the worst part of
        // opening it. Fetch the first screenful right away and put it on screen while the rest is
        // still being read.
        {
            static constexpr size_t preview_items = 4096;
            const auto perf_preview_begin = std::chrono::steady_clock::now();
            const std::expected<VFSListingPtr, Error> preview =
                vfs.FetchDirectoryListingPreview(directory, preview_items, m_VFSFetchingFlags, canceller);
            if( preview && (*preview)->Count() >= preview_items ) {
                big_directory = true;
                const auto prepared_preview = std::make_shared<data::Model::PreparedLoad>(data::Model::PrepareLoad(
                    *preview, data::Model::PanelType::Directory, _sort_mode, _hard_filter, _soft_filter));
                if( std::getenv("NC_PERF_LOG") != nullptr ) {
                    using namespace std::chrono;
                    const auto ms = duration_cast<microseconds>(steady_clock::now() - perf_preview_begin).count();
                    std::fprintf(stderr,
                                 "[perf] preview n=%u ready=%.1fms\n",
                                 (*preview)->Count(),
                                 static_cast<double>(ms) / 1000.0);
                }
                dispatch_to_main_queue([self, prepared_preview, _previous_listing] {
                    // don't clobber anything that may have been installed in the meantime
                    if( m_Data.ListingPtr() != _previous_listing )
                        return;
                    m_Data.InstallLoad(std::move(*prepared_preview));
                    m_DataGeneration++;
                    [m_View dataUpdated];
                });
            }
        }

        // Only the huge directories benefit from lazy dates, and the preview has just told us
        // whether this one is big.
        const bool lazy_dates = big_directory && ConfigLazyDates();
        const bool lazy_sizes = big_directory && ConfigLazySizes();
        const unsigned long fetch_flags =
            m_VFSFetchingFlags | (lazy_dates ? VFSFlags::F_NoTimes : 0) | (lazy_sizes ? VFSFlags::F_NoSizes : 0);
        const std::expected<VFSListingPtr, Error> listing =
            vfs.FetchDirectoryListing(directory, fetch_flags, canceller);
        if( _request->LoadingResultCallback ) {
            _request->LoadingResultCallback(listing ? std::expected<void, Error>{}
                                                    : std::expected<void, Error>{std::unexpected(listing.error())});
        }

        if( !listing )
            return std::unexpected(listing.error());

        // TODO: need an ability to show errors at least

        // do the expensive part of the model setup right here, on the background queue
        const auto prepared = std::make_shared<data::Model::PreparedLoad>(data::Model::PrepareLoad(
            *listing, data::Model::PanelType::Directory, _sort_mode, _hard_filter, _soft_filter));

        [self CancelBackgroundOperations]; // clean running operations if any
        dispatch_or_run_in_main_queue([=] {
            const auto perf_begin = std::chrono::steady_clock::now();
            [m_View savePathState];
            m_FlatView = false;
            m_FlatViewHost.reset();
            m_FlatViewRoot.clear();
            ++m_FlatViewGeneration;
            m_LazyDates = lazy_dates;
            m_LazySizes = lazy_sizes;
            m_Data.InstallLoad(std::move(*prepared));
            const auto perf_loaded = std::chrono::steady_clock::now();
            for( const auto &i : _request->RequestSelectedEntries )
                m_Data.CustomFlagsSelectSorted(m_Data.SortedIndexForName(i), true);
            m_DataGeneration++;
            [m_View dataUpdated];
            [self fetchLazyDatesForTopEntries];
            const auto perf_updated = std::chrono::steady_clock::now();
            [m_View panelChangedWithFocusedFilename:_request->RequestFocusedEntry
                                  loadPreviousState:_request->LoadPreviousViewState];
            [self onPathChanged];
            if( std::getenv("NC_PERF_LOG") != nullptr ) {
                using namespace std::chrono;
                const auto perf_end = steady_clock::now();
                const auto ms = [](auto _from, auto _to) {
                    return static_cast<double>(duration_cast<microseconds>(_to - _from).count()) / 1000.0;
                };
                std::fprintf(stderr,
                             "[perf] ui n=%u modelLoad=%.1fms dataUpdated=%.1fms tail=%.1fms total=%.1fms\n",
                             (*listing)->Count(),
                             ms(perf_begin, perf_loaded),
                             ms(perf_loaded, perf_updated),
                             ms(perf_updated, perf_end),
                             ms(perf_begin, perf_end));
            }
        });
    } catch( std::exception &e ) {
        ShowExceptionAlert(e);
    } catch( ... ) {
        ShowExceptionAlert();
    }
    return {};
}

- (std::expected<void, Error>)GoToDirWithContext:(std::shared_ptr<DirectoryChangeRequest>)_request
{
    if( _request == nullptr )
        return std::unexpected(Error{Error::POSIX, EINVAL});

    if( _request->RequestedDirectory.empty() || _request->RequestedDirectory.front() != '/' ||
        _request->VFS == nullptr )
        return std::unexpected(Error{Error::POSIX, EINVAL});

    assert(_request != nullptr);
    assert(_request->VFS != nullptr);
    Log::Debug("[PanelController GoToDirWithContext] was called with {}", *_request);

    // The sort order and the filters are owned by the model, which is main-thread-only - take a
    // snapshot of them here so that the heavy part of the load can run on a background queue.
    const data::SortMode sort_mode = m_Data.SortMode();
    const data::HardFilter hard_filtering = m_Data.HardFiltering();
    const data::TextualFilter soft_filtering = m_Data.SoftFiltering();

    if( !_request->PerformAsynchronous ) {
        assert(dispatch_is_main_queue());
        m_DirectoryLoadingQ.Stop();
        m_DirectoryLoadingQ.Wait();

        const std::expected<void, Error> result = [self doGoToDirWithContext:_request
                                                                    sortMode:sort_mode
                                                                  hardFilter:hard_filtering
                                                                  softFilter:soft_filtering
                                                             previousListing:m_Data.ListingPtr()];
        return result;
    }
    else {
        if( !m_DirectoryLoadingQ.Empty() )
            return {};

        const VFSListingPtr previous_listing = m_Data.ListingPtr();
        m_DirectoryLoadingQ.Run([=] {
            [self doGoToDirWithContext:_request
                              sortMode:sort_mode
                            hardFilter:hard_filtering
                            softFilter:soft_filtering
                       previousListing:previous_listing];
        });
        return {};
    }
}

- (void)loadListing:(const VFSListingPtr &)_listing
{
    [self CancelBackgroundOperations]; // clean running operations if any
    dispatch_or_run_in_main_queue([=] {
        const auto perf_begin = std::chrono::steady_clock::now();
        [m_View savePathState];
        if( _listing->IsUniform() )
            m_Data.Load(_listing, data::Model::PanelType::Directory);
        else
            m_Data.Load(_listing, data::Model::PanelType::Temporary);
        const auto perf_loaded = std::chrono::steady_clock::now();
        m_DataGeneration++;
        [m_View dataUpdated];
        const auto perf_updated = std::chrono::steady_clock::now();
        [m_View panelChangedWithFocusedFilename:"" loadPreviousState:false];
        [self onPathChanged];
        if( std::getenv("NC_PERF_LOG") != nullptr ) {
            using namespace std::chrono;
            const auto perf_end = steady_clock::now();
            const auto ms = [](auto _from, auto _to) {
                return static_cast<double>(duration_cast<microseconds>(_to - _from).count()) / 1000.0;
            };
            std::fprintf(stderr,
                         "[perf] ui n=%u loadListing=%.1fms dataUpdated=%.1fms pathChanged=%.1fms total=%.1fms\n",
                         _listing->Count(),
                         ms(perf_begin, perf_loaded),
                         ms(perf_loaded, perf_updated),
                         ms(perf_updated, perf_end),
                         ms(perf_begin, perf_end));
        }
    });
}

- (bool)isFlatView
{
    return m_FlatView;
}

- (std::string)flatViewRoot
{
    return m_FlatViewRoot;
}

- (const VFSHostPtr &)flatViewHost
{
    return m_FlatViewHost;
}

- (void)toggleFlatView
{
    if( m_FlatView ) {
        [self leaveFlatView];
        return;
    }

    if( !self.isUniform )
        return;

    const VFSHostPtr host = self.vfs;
    const std::string root = m_Data.DirectoryPathWithTrailingSlash();
    if( host == nullptr || root.empty() )
        return;

    m_FlatViewHost = host;
    m_FlatViewRoot = root;
    m_FlatView = true;
    ++m_FlatViewGeneration;
    m_FlatTruncationReported = false;
    [self reloadFlatView];
}

- (void)leaveFlatView
{
    const VFSHostPtr host = m_FlatViewHost;
    const std::string root = m_FlatViewRoot;

    m_FlatView = false;
    m_FlatViewHost.reset();
    m_FlatViewRoot.clear();
    ++m_FlatViewGeneration;

    if( host == nullptr || root.empty() )
        return;

    const auto request = std::make_shared<DirectoryChangeRequest>();
    request->RequestedDirectory = root;
    request->VFS = host;
    request->PerformAsynchronous = false;
    [self GoToDirWithContext:request];
}

- (void)reportFlatViewTruncation:(size_t)_scanned_items directories:(size_t)_scanned_directories
{
    assert(dispatch_is_main_queue());
    Log::Warn("The flat view of '{}' was truncated: {} entries in {} directories, the limits are {} / {}",
              m_FlatViewRoot,
              _scanned_items,
              _scanned_directories,
              ConfigFlatViewMaxItems(),
              ConfigFlatViewMaxDirectories());
    if( m_FlatTruncationReported )
        return; // don't nag on every refresh
    m_FlatTruncationReported = true;

    Alert *const alert = [[Alert alloc] init];
    alert.messageText = NSLocalizedString(@"The flat view is incomplete", "");
    alert.informativeText = [NSString
        stringWithFormat:NSLocalizedString(
                             @"There are too many entries under this directory - only the first %ld are shown. The "
                             @"limit can be raised with the filePanel.general.flatViewMaxItems setting.",
                             ""),
                         static_cast<long>(_scanned_items)];
    [alert addButtonWithTitle:NSLocalizedString(@"OK", "")];
    if( NSWindow *const window = m_View.window )
        [alert beginSheetModalForWindow:window completionHandler:nil];
    else
        [alert runModal];
}

- (void)reloadFlatView
{
    if( !m_FlatView )
        return;

    const VFSHostPtr host = m_FlatViewHost;
    const std::string root = m_FlatViewRoot;
    const unsigned long generation = m_FlatViewGeneration;
    const unsigned long fetch_flags = m_VFSFetchingFlags;
    if( host == nullptr || root.empty() )
        return;

    const size_t max_items = static_cast<size_t>(ConfigFlatViewMaxItems());
    const size_t max_directories = static_cast<size_t>(ConfigFlatViewMaxDirectories());
    const size_t threads = [&]() -> size_t {
        const long configured = ConfigFlatScanThreads();
        if( configured > 0 )
            return std::min<size_t>(static_cast<size_t>(configured), 32);
        return std::min<size_t>(std::max(1u, std::thread::hardware_concurrency()), 8);
    }();
    __weak PanelController *weak_self = self;
    [self commitCancelableLoadingTask:[host,
                                       root,
                                       generation,
                                       fetch_flags,
                                       max_items,
                                       max_directories,
                                       threads,
                                       weak_self](const std::function<bool()> &_is_cancelled) {
        const auto flat_begin = std::chrono::steady_clock::now();
        const FlatListingResult result =
            BuildFlatListing(host, root, fetch_flags, _is_cancelled, max_items, max_directories, threads);
        if( std::getenv("NC_PERF_LOG") != nullptr ) {
            using namespace std::chrono;
            const auto ms = duration_cast<milliseconds>(steady_clock::now() - flat_begin).count();
            std::fprintf(stderr,
                         "[perf] flat root=%s items=%zu dirs=%zu truncated=%d listing=%d took=%lldms "
                         "scan=%lldms compose=%lldms fetch=%lldms fold=%lldms threads=%zu\n",
                         root.c_str(),
                         result.scanned_items,
                         result.scanned_directories,
                         result.truncated ? 1 : 0,
                         result.listing ? 1 : 0,
                         static_cast<long long>(ms),
                         result.scan_ms,
                         result.compose_ms,
                         result.fetch_ms,
                         result.fold_ms,
                         threads);
        }
        if( !result.listing )
            return; // cancelled, or nothing could be fetched at all
        dispatch_to_main_queue([weak_self, result, generation] {
            PanelController *const panel = weak_self;
            if( panel == nil || !panel->m_FlatView || panel->m_FlatViewGeneration != generation )
                return;
            [panel loadListing:result.listing];
            if( result.truncated )
                [panel reportFlatViewTruncation:result.scanned_items directories:result.scanned_directories];
        });
    }];
}

- (void)recoverFromInvalidDirectory
{
    std::filesystem::path initial_path = EnsureNoTrailingSlash(self.currentDirectoryPath);
    auto initial_vfs = self.vfs;
    m_DirectoryLoadingQ.Run([=] {
        // 1st - try to locate a valid dir in current host
        std::filesystem::path path = initial_path;
        const auto &vfs = initial_vfs;

        while( true ) {
            if( vfs->IterateDirectoryListing(path.native(), [](const VFSDirEnt &) { return false; }) ) {
                dispatch_to_main_queue([=] {
                    const auto request = std::make_shared<DirectoryChangeRequest>();
                    request->RequestedDirectory = path.native();
                    request->VFS = vfs;
                    request->PerformAsynchronous = true;
                    [self GoToDirWithContext:request];
                });
                break;
            }

            if( path == "/" )
                break;

            path = path.parent_path();
        }

        // we can't work on this vfs. currently for simplicity - just go home
        const auto request = std::make_shared<DirectoryChangeRequest>();
        request->RequestedDirectory = nc::base::CommonPaths::Home();
        request->VFS = m_NativeHost->SharedPtr();
        request->PerformAsynchronous = true;
        [self GoToDirWithContext:request];
    });
}

- (void)scheduleDelayedFocusing:(const DelayedFocusing &)request
{
    assert(dispatch_is_main_queue()); // to preserve against fancy threading stuff
    // we assume that _item_name will not contain any forward slashes

    if( request.filename.empty() )
        return;

    nc::panel::Log::Trace("[PanelController scheduleDelayedFocusing] called for '{}'", request.filename);

    m_DelayedSelection.request_end = nc::base::machtime() + request.timeout;
    m_DelayedSelection.filename = request.filename;
    m_DelayedSelection.done = request.done;

    if( request.check_now )
        [self checkAgainstRequestedFocusing];
}

// This function checks if a requested focusing can be satisfied and if so - changes the cursor.
// The check is destructive/has side effects - it clears a focus request if either it was satisfied
// or if it became outdated.
// Returns true if the request was satisfied and the cursor position was changed.
- (bool)checkAgainstRequestedFocusing
{
    assert(dispatch_is_main_queue()); // to preserve against fancy threading stuff
    if( m_DelayedSelection.filename.empty() )
        return false;

    if( nc::base::machtime() > m_DelayedSelection.request_end ) {
        nc::panel::Log::Trace("[PanelController checkAgainstRequestedFocusing] removing a stale request for '{}'",
                              m_DelayedSelection.filename);
        [self clearFocusingRequest];
        return false;
    }

    // now try to find it
    int raw_index = m_Data.RawIndexForName(m_DelayedSelection.filename);
    if( raw_index < 0 )
        return false;
    nc::panel::Log::Trace("[PanelController checkAgainstRequestedFocusing] found an entry for '{}'",
                          m_DelayedSelection.filename);

    // we found this entry. regardless of appearance of this entry in current directory presentation
    // there's no reason to search for it again
    auto done = std::move(m_DelayedSelection.done);

    const int sort_index = m_Data.SortedIndexForRawIndex(raw_index);
    if( sort_index >= 0 ) {
        m_View.curpos = sort_index;
        if( !self.isActive )
            [self.state ActivatePanelByController:self];
        if( done )
            done();
    }

    // focus requests are one-shot
    [self clearFocusingRequest];

    // return 'true' only if the entry was actually focused, regardless if it is present in raw
    // listing.
    return sort_index >= 0;
}

- (void)clearFocusingRequest
{
    m_DelayedSelection.filename.clear();
    m_DelayedSelection.done = nullptr;
}

- (BriefSystemOverview *)briefSystemOverview
{
    return [self.state briefSystemOverviewForPanel:self make:false];
}

- (id<NCPanelPreview>)quickLook
{
    return [self.state quickLookForPanel:self make:false];
}

- (nc::panel::PanelViewLayoutsStorage &)layoutStorage
{
    return *m_Layouts;
}

- (nc::core::VFSInstanceManager &)vfsInstanceManager
{
    return *m_VFSInstanceManager;
}

- (int)quickSearchNeedsCursorPosition:(NCPanelQuickSearch *) [[maybe_unused]] _qs
{
    return m_View.curpos;
}

- (void)quickSearch:(NCPanelQuickSearch *) [[maybe_unused]] _qs wantsToSetCursorPosition:(int)_cursor_position
{
    m_View.curpos = _cursor_position;
}

- (void)quickSearchHasChangedVolatileData:(NCPanelQuickSearch *) [[maybe_unused]] _qs
{
    [m_View volatileDataChanged];
}

- (void)quickSearchHasUpdatedData:(NCPanelQuickSearch *) [[maybe_unused]] _qs
{
    [m_View dataUpdated];
}

- (void)quickSearch:(NCPanelQuickSearch *) [[maybe_unused]] _qs
    wantsToSetSearchPrompt:(NSString *)_prompt
          withMatchesCount:(int)_count
{
    m_View.headerView.searchPrompt = _prompt;
    m_View.headerView.searchMatches = _count;
}

- (bool)isDoingBackgroundLoading
{
    return !m_DirectoryLoadingQ.Empty();
}

- (std::unique_ptr<nc::panel::DragReceiver>)panelView:(PanelView *) [[maybe_unused]] _view
                      requestsDragReceiverForDragging:(id<NSDraggingInfo>)_dragging
                                               onItem:(int)_on_sorted_index
{
    return std::make_unique<nc::panel::DragReceiver>(
        self, _dragging, _on_sorted_index, *m_NativeFSManager, *m_NativeHost);
}

- (void)hintAboutFilesystemChange
{
    Log::Trace("[PanelController hintAboutFilesystemChange] was called");
    dispatch_assert_main_queue(); // to preserve against fancy threading stuff
    if( self.receivesUpdateNotifications ) {
        // check in some future that the notification actually came
        const auto timestamp = nc::base::machtime();
        __weak PanelController *weak_me = self;
        dispatch_to_main_queue_after(g_FilesystemHintTriggerDelay, [weak_me, timestamp] {
            if( PanelController *const me = weak_me ) {
                // now check if our listing was created after we were hinted
                if( me->m_Data.Listing().BuildTicksTimestamp() > timestamp )
                    return; // yep, fresh enough.

                // nope, stale -> refresh
                [me refreshPanel];
            }
        });
    }
    else {
        // immediately request a listing reload since a notification won't come anyway
        [self refreshPanel];
    }
}

@end
