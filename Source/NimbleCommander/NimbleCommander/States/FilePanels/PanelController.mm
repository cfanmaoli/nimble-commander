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
#include <chrono>
#include <cstdio>
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

static void HeatUpConfigValues()
{
    ConfigShowDotDotEntry();
    ConfigShowLocalizedFilenames();
    ConfigEnableFinderTags();
}

@interface PanelController ()

@property(nonatomic, readonly)
    bool receivesUpdateNotifications; // returns true if underlying vfs will notify controller that content has changed

- (void)refreshPanelIncrementallyWithChangedNames:(std::vector<std::string>)_names;
- (void)applyPatchedListing:(const VFSListingPtr &)_listing
                    removed:(const std::vector<unsigned> &)_removed
                   appended:(unsigned)_appended;
@end

namespace {

// Collects everything underneath the given directory into a single listing. Symbolic links to
// directories are listed but not followed, so that a link loop cannot hang the traversal.
VFSListingPtr BuildFlatListing(const VFSHostPtr &_host,
                               const std::string &_root,
                               unsigned long _fetch_flags,
                               const VFSCancelChecker &_cancel_checker)
{
    constexpr size_t max_directories = size_t{64} * 1024;
    constexpr int max_items = 1'000'000;

    try {
        std::vector<VFSListingPtr> listings;
        std::vector<std::vector<unsigned>> indices;
        std::vector<std::string> directories;
        directories.emplace_back(_root);

        size_t total_items = 0;
        for( size_t index = 0; index != directories.size() && listings.size() < max_directories; ++index ) {
            if( _cancel_checker && _cancel_checker() )
                return {};

            const std::string &directory = directories[index];
            std::expected<VFSListingPtr, Error> fetched =
                _host->FetchDirectoryListing(directory, _fetch_flags, _cancel_checker);
            if( !fetched )
                continue;

            const VFSListingPtr &listing = *fetched;
            std::vector<unsigned> wanted;
            for( unsigned item_index = 0, items = listing->Count(); item_index != items; ++item_index ) {
                const VFSListingItem item{listing, item_index};
                const std::string &filename = item.Filename();
                // '.' and '..' have no place in a flat view - the latter would also make the
                // traversal walk towards the filesystem root endlessly.
                if( filename == "." || filename == ".." )
                    continue;
                wanted.emplace_back(item_index);
                if( item.IsDir() && !item.IsSymlink() )
                    directories.emplace_back(item.Directory() + filename + "/");
            }

            total_items += wanted.size();
            if( total_items > max_items )
                break;
            if( wanted.empty() )
                continue;
            listings.emplace_back(listing);
            indices.emplace_back(std::move(wanted));
        }

        if( listings.empty() )
            return {}; // nothing underneath - keep the regular directory listing
        return VFSListing::Build(VFSListing::Compose(listings, indices));
    } catch( ... ) {
        return {};
    }
}

// Produces a new listing out of '_base' by dropping the entries at '_removed' (sorted ascending)
// and appending the items from '_appended' (single-item listings of the freshly stat'ed entries).
// Rebuilding through VFSListing::Compose() would sort the data into sparse containers, which is
// O(n) hash-map insertions for a million items - here everything that can stay dense stays dense.
VFSListingPtr ProducePatchedListing(const VFSListing &_base,
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
    in.atimes.reset(variable_container<>::type::dense);
    in.mtimes.reset(variable_container<>::type::dense);
    in.ctimes.reset(variable_container<>::type::dense);
    in.btimes.reset(variable_container<>::type::dense);
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

    unsigned n = 0;
    const auto append_item = [&](const VFSListing &_l, unsigned _i) {
        in.filenames.emplace_back(_l.Filename(_i));
        in.unix_modes.emplace_back(_l.UnixMode(_i));
        in.unix_types.emplace_back(_l.UnixType(_i));
        in.sizes.insert(n, _l.HasSize(_i) ? _l.Size(_i) : uint64_t(-1));
        in.inodes.insert(n, _l.HasInode(_i) ? _l.Inode(_i) : 0);
        in.atimes.insert(n, _l.HasATime(_i) ? _l.ATime(_i) : 0);
        in.mtimes.insert(n, _l.HasMTime(_i) ? _l.MTime(_i) : 0);
        in.ctimes.insert(n, _l.HasCTime(_i) ? _l.CTime(_i) : 0);
        in.btimes.insert(n, _l.HasBTime(_i) ? _l.BTime(_i) : 0);
        in.uids.insert(n, _l.HasUID(_i) ? _l.UID(_i) : 0);
        in.gids.insert(n, _l.HasGID(_i) ? _l.GID(_i) : 0);
        in.unix_flags.insert(n, _l.HasUnixFlags(_i) ? _l.UnixFlags(_i) : 0);
        if( _l.HasDisplayFilename(_i) )
            in.display_filenames.insert(n, _l.DisplayFilename(_i));
        if( _l.HasAddTime(_i) )
            in.add_times.insert(n, _l.AddTime(_i));
        if( _l.HasSymlink(_i) )
            in.symlinks.insert(n, _l.Symlink(_i));
        if( _l.HasTags(_i) ) {
            const auto tags = _l.Tags(_i);
            in.tags.emplace(n, std::vector<utility::Tags::Tag>(tags.begin(), tags.end()));
        }
        ++n;
    };

    size_t removed_pos = 0;
    for( unsigned i = 0, e = _base.Count(); i != e; ++i ) {
        if( removed_pos < _removed.size() && _removed[removed_pos] == i ) {
            ++removed_pos;
            continue;
        }
        append_item(_base, i);
    }
    for( auto &ptr : _appended )
        for( unsigned i = 0, e = ptr->Count(); i != e; ++i )
            append_item(*ptr, i);

    assert(n == total);
    return VFSListing::Build(std::move(in));
}

} // namespace

@implementation PanelController {
    data::Model m_Data; // owns
    PanelView *m_View;  // create and owns

    // VFS changes observation
    vfs::HostDirObservationTicket m_UpdatesObservationTicket;

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

- (void)changeSortingModeTo:(data::SortMode)_mode
{
    if( _mode != m_Data.SortMode() ) {
        const auto pers = CursorBackup{m_View.curpos, m_Data};

        m_Data.SetSortMode(_mode);

        m_View.curpos = pers.RestoredCursorPosition();

        [m_View dataSortingHasChanged];
        [m_View dataUpdated];
        [self markRestorableStateAsInvalid];
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

- (void)refreshPanelIncrementallyWithChangedNames:(std::vector<std::string>)_names
{
    Log::Debug("[PanelController refreshPanelIncrementallyWithChangedNames] {} name(s)", _names.size());

    if( m_FlatView || !self.isUniform || _names.size() > 128 ) {
        [self refreshPanel];
        return;
    }
    if( !m_DirectoryLoadingQ.Empty() || m_DirectoryReLoadingQ.Length() >= 2 ) {
        // a full (re)load is already on its way - it will pick the changes up
        return;
    }

    const VFSListingPtr listing = m_Data.ListingPtr();
    if( listing == nullptr || listing->Count() == 0 || !listing->IsUniform() || !listing->HasCommonHost() ||
        !listing->HasCommonDirectory() || m_Data.HardFiltering().IsFiltering() ) {
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
        const VFSListingPtr patched = ProducePatchedListing(*listing, removed, appended);
        if( std::getenv("NC_PERF_LOG") != nullptr ) {
            using namespace std::chrono;
            const auto perf_end = steady_clock::now();
            const auto ms = [](auto _from, auto _to) {
                return static_cast<double>(duration_cast<microseconds>(_to - _from).count()) / 1000.0;
            };
            std::fprintf(stderr,
                         "[perf] incr k=%zu removed=%zu appended=%u fetch=%.1fms patch=%.1fms\n",
                         changes.size(),
                         removed.size(),
                         appended_count,
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
    if( std::getenv("NC_PERF_LOG") != nullptr ) {
        using namespace std::chrono;
        const auto perf_end = steady_clock::now();
        const auto ms = [](auto _from, auto _to) {
            return static_cast<double>(duration_cast<microseconds>(_to - _from).count()) / 1000.0;
        };
        std::fprintf(stderr,
                     "[perf] incr.ui n=%u model=%.1fms view=%.1fms total=%.1fms\n",
                     _listing->Count(),
                     ms(perf_begin, perf_patched),
                     ms(perf_patched, perf_end),
                     ms(perf_begin, perf_end));
    }
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
        const auto fetch_flags = m_VFSFetchingFlags | (_force ? VFSFlags::F_ForceRefresh : 0);
        const auto dirpath = m_Data.DirectoryPathWithTrailingSlash();
        const auto vfs = self.vfs;

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
            dispatch_to_main_queue([=] {
                if( self.currentDirectoryPath != dirpath ) {
                    Log::Debug(
                        "[PanelController refreshPanelDiscardingCaches]: discarding a stale request to refresh '{}'",
                        dirpath);
                    return;
                }

                if( listing )
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
                if( !changed_names.empty() )
                    [pc refreshPanelIncrementallyWithChangedNames:changed_names];
                else
                    [pc refreshPanel];
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

- (void)onCursorChanged
{
    [self updateAttachedQuickLook];
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
        const std::expected<VFSListingPtr, Error> listing =
            vfs.FetchDirectoryListing(directory, m_VFSFetchingFlags, canceller);
        if( _request->LoadingResultCallback ) {
            _request->LoadingResultCallback(listing ? std::expected<void, Error>{}
                                                    : std::expected<void, Error>{std::unexpected(listing.error())});
        }

        if( !listing )
            return std::unexpected(listing.error());

        // TODO: need an ability to show errors at least

        [self CancelBackgroundOperations]; // clean running operations if any
        dispatch_or_run_in_main_queue([=] {
            const auto perf_begin = std::chrono::steady_clock::now();
            [m_View savePathState];
            m_FlatView = false;
            m_FlatViewHost.reset();
            m_FlatViewRoot.clear();
            ++m_FlatViewGeneration;
            m_Data.Load(*listing, data::Model::PanelType::Directory);
            const auto perf_loaded = std::chrono::steady_clock::now();
            for( const auto &i : _request->RequestSelectedEntries )
                m_Data.CustomFlagsSelectSorted(m_Data.SortedIndexForName(i), true);
            m_DataGeneration++;
            [m_View dataUpdated];
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

    if( !_request->PerformAsynchronous ) {
        assert(dispatch_is_main_queue());
        m_DirectoryLoadingQ.Stop();
        m_DirectoryLoadingQ.Wait();

        const std::expected<void, Error> result = [self doGoToDirWithContext:_request];
        return result;
    }
    else {
        if( !m_DirectoryLoadingQ.Empty() )
            return {};

        m_DirectoryLoadingQ.Run([=] { [self doGoToDirWithContext:_request]; });
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

    __weak PanelController *weak_self = self;
    [self commitCancelableLoadingTask:[host, root, generation, fetch_flags, weak_self](
                                          const std::function<bool()> &_is_cancelled) {
        const VFSListingPtr listing = BuildFlatListing(host, root, fetch_flags, _is_cancelled);
        if( !listing )
            return; // cancelled, or nothing could be fetched at all
        dispatch_to_main_queue([weak_self, listing, generation] {
            PanelController *const panel = weak_self;
            if( panel == nil || !panel->m_FlatView || panel->m_FlatViewGeneration != generation )
                return;
            [panel loadListing:listing];
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
