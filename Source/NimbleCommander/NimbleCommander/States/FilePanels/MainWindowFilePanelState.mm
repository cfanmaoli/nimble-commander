// Copyright (C) 2013-2025 Michael Kazakov. Subject to GNU General Public License version 3.
#include <Base/CommonPaths.h>
#include <Utility/PathManip.h>
#include <Utility/NSView+Sugar.h>
#include <Utility/NSMenu+Hierarchical.h>
#include <Utility/ColoredSeparatorLine.h>
#include <VFS/Native.h>
#include <NimbleCommander/Bootstrap/AppDelegate.h>
#include <NimbleCommander/Bootstrap/Config.h>
#include <NimbleCommander/Bootstrap/NativeVFSHostInstance.h>
#include <NimbleCommander/Core/AnyHolder.h>
#include <Config/RapidJSON.h>
#include "Actions/Helpers.h"
#include <NimbleCommander/Core/Alert.h>
#include <NimbleCommander/Core/ActionsShortcutsManager.h>
#include <NimbleCommander/Bootstrap/Actions.h>
#include <CUI/CommandPopover.h>
#include <cstring>
#include <cstdlib>
#include <NimbleCommander/Core/SandboxManager.h>
#include <NimbleCommander/Core/Theming/Theme.h>
#include <NimbleCommander/Core/Theming/ThemesManager.h>
#include <NimbleCommander/States/MainWindowController.h>
#include "MainWindowFilePanelState.h"
#include "PanelViewPresentationSettings.h"
#include "PanelController.h"
#include "PanelController+DataAccess.h"
#include "PanelViewLayoutSupport.h" // DefaultPanelLayout()
#include "MainWindowFilePanelsStateToolbarDelegate.h"
#include "Favorites.h"
#include "Views/QuickLookOverlay.h"
#include "Views/FilePanelMainSplitView.h"
#include "Views/BriefSystemOverview.h"
#include "Views/FilePanelOverlappedTerminal.h"
#include <Panel/PanelData.h>
#include "PanelView.h"
#include <Operations/Pool.h>
#include <Operations/PoolViewController.h>
#include "Views/QuickLookPanel.h"
#include <Quartz/Quartz.h>
#include "PanelAux.h"
#include "PanelControllerPersistency.h"
#include "Helpers/ClosedPanelsHistory.h"
#include "PanelHistory.h"
#include "MainWindowFilePanelState+OverlappedTerminalSupport.h"
#include "MainWindowFilePanelState+TabsSupport.h"
#include "ToolsMenuDelegate.h"
#include <Utility/ObjCpp.h>
#include <Utility/StringExtras.h>
#include <Base/dispatch_cpp.h>
#include <Base/debug.h>

using namespace nc;
using namespace nc::panel;
using namespace std::literals;

static const auto g_ConfigGoToActivation = "filePanel.general.goToButtonForcesPanelActivation";
static const auto g_ConfigInitialLeftPath = "filePanel.general.initialLeftPanelPath";
static const auto g_ConfigInitialRightPath = "filePanel.general.initialRightPanelPath";
static const auto g_ConfigGeneralShowTabs = "general.showTabs";
static const auto g_ConfigWorkspaces = "filePanel.workspaces";
static const auto g_ConfigRouteKeyboardInputIntoTerminal = "filePanel.general.routeKeyboardInputIntoTerminal";
static const auto g_ResorationPanelsKey = "panels_v1";
static const auto g_ResorationUIKey = "uiState";
static const auto g_ResorationUISelectedLeftTab = "selectedLeftTab";
static const auto g_ResorationUISelectedRightTab = "selectedRightTab";
static const auto g_ResorationUIFocusedSide = "focusedSide";
static const auto g_InitialStatePath = "filePanel.initialState";
static const auto g_InitialStateLeftDefaults = "left";
static const auto g_InitialStateRightDefaults = "right";

// bottom bar now holds the command line only (v4 dropped the
// F-key row - the tree + tabs are the real TC/DC workflow, not cosmetic keys).
static constexpr double kFKeyBarTotalHeight = 30.0;
static constexpr double kDirectoryTreeWidth = 230.0;
// 2.1.16: the sidebar divider doubles as a resize handle - a hairline painted inside
// a wider hit area, since a 1px view is essentially impossible to grab.
static constexpr double kTreeDividerHitWidth = 6.0;
static constexpr double kDirectoryTreeMinWidth = 160.0;
static constexpr double kDirectoryTreeMaxWidth = 400.0;
static NSString *const g_ConfigDirectoryTreeWidth = @"nc.directoryTreeWidth";

// Never let the tree eat the panels: on a narrow window the ceiling shrinks too.
static double NCClampDirectoryTreeWidth(double _width, double _container_width)
{
    double max_width = kDirectoryTreeMaxWidth;
    if( _container_width > 0 )
        max_width = _container_width * 0.4 < max_width ? _container_width * 0.4 : max_width;
    if( max_width < kDirectoryTreeMinWidth )
        max_width = kDirectoryTreeMinWidth;
    if( _width < kDirectoryTreeMinWidth )
        return kDirectoryTreeMinWidth;
    return _width > max_width ? max_width : _width;
}

static double NCStoredDirectoryTreeWidth(double _container_width)
{
    NSUserDefaults *const defaults = NSUserDefaults.standardUserDefaults;
    const double width = [defaults objectForKey:g_ConfigDirectoryTreeWidth]
                             ? [defaults doubleForKey:g_ConfigDirectoryTreeWidth]
                             : kDirectoryTreeWidth;
    return NCClampDirectoryTreeWidth(width, _container_width);
}

static bool GoToForcesPanelActivation()
{
    static const auto fetch = [] { return GlobalConfig().GetBool(g_ConfigGoToActivation); };
    static bool force = [] {
        [[clang::no_destroy]] static const auto ticket =
            GlobalConfig().Observe(g_ConfigGoToActivation, [] { force = fetch(); });
        return fetch();
    }();
    return force;
}

static NSString *TrimmedTitleForWindow(NSString *_title, NSWindow *_window);
static NSString *TitleForData(const data::Model *_data);

// MARK: - left-hand persistent directory tree
//
// Modelled on XYplorer / Directory Opus: a tree that is always visible on the
// left, with the two (already tabbed) file panels to its right. Clicking a node
// navigates the last-focused panel; Option-click navigates the opposite panel
// without stealing focus; Shift+Option-click opens the path in a new tab there.

typedef NS_ENUM(NSInteger, NCSidebarNodeKind) {
    NCSidebarNodeKindDirectory = 0, // a real folder, children are lazily listed from disk
    NCSidebarNodeKindGroup,         // a sidebar section header, e.g. "Favorites"
    NCSidebarNodeKindBookmark,      // a saved favorite location
    NCSidebarNodeKindRecent,        // a frecently visited location
    NCSidebarNodeKindWorkspace,     // a saved window layout
    NCSidebarNodeKindAction,        // a clickable command row, e.g. "Save Workspace…"
};

@interface NCDirectoryTreeNode : NSObject
@property(nonatomic, copy) NSString *path;
@property(nonatomic, copy) NSString *name;
@property(nonatomic, strong) NSImage *icon;
@property(nonatomic, strong) NSMutableArray<NCDirectoryTreeNode *> *children;
@property(nonatomic, assign) BOOL childrenLoaded;
@property(nonatomic, assign) NCSidebarNodeKind kind;
@property(nonatomic, strong) AnyHolder *location; // a PersistentLocation, for bookmarks/recent rows
@property(nonatomic, assign) NSInteger entryIndex; // position inside its storage snapshot
- (instancetype)initWithPath:(NSString *)path;
+ (instancetype)groupWithTitle:(NSString *)title kind:(NCSidebarNodeKind)kind;
@end

@implementation NCDirectoryTreeNode
@synthesize path = _path;
@synthesize name = _name;
@synthesize icon = _icon;
@synthesize children = _children;
@synthesize childrenLoaded = _childrenLoaded;
@synthesize kind = _kind;
@synthesize location = _location;
@synthesize entryIndex = _entryIndex;

- (instancetype)initWithPath:(NSString *)path_
{
    self = [super init];
    if( self ) {
        _path = [path_ copy];
        NSString *display = [NSFileManager.defaultManager displayNameAtPath:path_];
        _name = [display.length ? display : path_.lastPathComponent copy];
        _children = [NSMutableArray array];
        _childrenLoaded = NO;
        _kind = NCSidebarNodeKindDirectory;
        _entryIndex = -1;
    }
    return self;
}

+ (instancetype)groupWithTitle:(NSString *)title kind:(NCSidebarNodeKind)kind_
{
    NCDirectoryTreeNode *const group = [NCDirectoryTreeNode new];
    group.kind = kind_;
    group.name = title;
    group.children = [NSMutableArray array];
    group.childrenLoaded = YES;
    group.entryIndex = -1;
    return group;
}
@end

// 2.1.16: sidebar resize handle. The view is a few points wide so it can be grabbed,
// but only paints a centered hairline, keeping the 1px separator look.
@interface NCSidebarDividerView : NSView
@property(nonatomic) NSColor *lineColor;
@property(nonatomic, copy) void (^onDragBegan)(void);
@property(nonatomic, copy) void (^onDragged)(CGFloat delta_x);
@property(nonatomic, copy) void (^onDragEnded)(void);
@property(nonatomic, copy) void (^onDoubleClicked)(void);
@end

@implementation NCSidebarDividerView {
    NSColor *_lineColor;
    CGFloat _drag_start_x;
    BOOL _dragging;
}
@synthesize lineColor = _lineColor;
// Xcode builds with -Wobjc-missing-property-synthesis as an error, so every
// property (blocks included) needs an explicit synthesis.
@synthesize onDragBegan = _onDragBegan;
@synthesize onDragged = _onDragged;
@synthesize onDragEnded = _onDragEnded;
@synthesize onDoubleClicked = _onDoubleClicked;

- (void)drawRect:(NSRect)dirtyRect
{
    [super drawRect:dirtyRect];
    [( _lineColor ?: NSColor.separatorColor ) setFill];
    const CGFloat x = (self.bounds.size.width - 1.0) * 0.5;
    NSRectFillUsingOperation(NSMakeRect(x, 0, 1, self.bounds.size.height), NSCompositingOperationSourceOver);
}

- (void)resetCursorRects
{
    [super resetCursorRects];
    [self addCursorRect:self.bounds cursor:NSCursor.resizeLeftRightCursor];
}

- (void)mouseDown:(NSEvent *)event
{
    if( event.clickCount == 2 ) {
        if( self.onDoubleClicked )
            self.onDoubleClicked();
        return;
    }
    // window space - stable while this view itself moves under the cursor
    _drag_start_x = event.locationInWindow.x;
    _dragging = YES;
    if( self.onDragBegan )
        self.onDragBegan();
}

- (void)mouseDragged:(NSEvent *)event
{
    if( !_dragging )
        return;
    if( self.onDragged )
        self.onDragged(event.locationInWindow.x - _drag_start_x);
}

- (void)mouseUp:(NSEvent *)event
{
    if( !_dragging )
        return;
    _dragging = NO;
    if( self.onDragEnded )
        self.onDragEnded();
}
@end

// 2.1.18: whether a section is expanded is part of the user's layout, so it is
// stored per section and re-applied on every rebuild - which includes launch.
static NSString *const g_ConfigSidebarExpandedWorkspaces = @"nc.sidebar.expanded.workspaces";
static NSString *const g_ConfigSidebarExpandedFavorites = @"nc.sidebar.expanded.favorites";
static NSString *const g_ConfigSidebarExpandedRecent = @"nc.sidebar.expanded.recent";
static NSString *const g_ConfigSidebarExpandedFolders = @"nc.sidebar.expanded.folders";
static NSString *const g_ConfigSidebarExpandedFolderRoot = @"nc.sidebar.expanded.folderRoot";
// 2.1.19: how deep the folder tree was opened - absolute paths of the expanded folders.
static NSString *const g_ConfigSidebarExpandedFolderPaths = @"nc.sidebar.expanded.folderPaths";

// 2.1.25: writing NSUserDefaults posts NSUserDefaultsDidChangeNotification
// synchronously. The sidebar writes its own expansion bookkeeping on every
// expand/collapse, so without this flag the change would bounce back into a
// rebuild that re-applies the previous (pre-collapse) state.
static BOOL g_WritingSidebarDefaults = NO;

// 2.1.26: the command line's placeholder is a hint, not a billboard - keep it to one
// short line, and let the user switch it off completely.
static NSString *const g_ConfigCommandLineShowHint = @"nc.commandLine.showHint";

static BOOL NCCommandLineHintVisible()
{
    NSUserDefaults *const defaults = NSUserDefaults.standardUserDefaults;
    return [defaults objectForKey:g_ConfigCommandLineShowHint]
               ? [defaults boolForKey:g_ConfigCommandLineShowHint]
               : YES;
}

// 2.1.21: sidebar settings live in NSUserDefaults so the preferences tab can change
// them without going through the config plumbing.
static NSString *const g_ConfigSidebarRecentLimit = @"nc.sidebar.recentLimit";
static NSString *const g_ConfigSidebarLinkMode = @"nc.sidebar.linkMode";
static constexpr int kSidebarRecentLimitDefault = 5;
static constexpr int kSidebarRecentLimitMin = 1;
static constexpr int kSidebarRecentLimitMax = 20;

// 0 = the tree drives the panels (default), 1 = both ways, 2 = no syncing at all.
static constexpr int kSidebarLinkModeTreeToPanels = 0;
static constexpr int kSidebarLinkModeBoth = 1;
static constexpr int kSidebarLinkModeNone = 2;

static int NCSidebarRecentLimit()
{
    NSUserDefaults *const defaults = NSUserDefaults.standardUserDefaults;
    if( ![defaults objectForKey:g_ConfigSidebarRecentLimit] )
        return kSidebarRecentLimitDefault;
    const NSInteger value = [defaults integerForKey:g_ConfigSidebarRecentLimit];
    if( value < kSidebarRecentLimitMin )
        return kSidebarRecentLimitMin;
    return value > kSidebarRecentLimitMax ? kSidebarRecentLimitMax : static_cast<int>(value);
}

static int NCSidebarLinkMode()
{
    NSUserDefaults *const defaults = NSUserDefaults.standardUserDefaults;
    if( ![defaults objectForKey:g_ConfigSidebarLinkMode] )
        return kSidebarLinkModeTreeToPanels;
    const NSInteger value = [defaults integerForKey:g_ConfigSidebarLinkMode];
    if( value == kSidebarLinkModeBoth )
        return kSidebarLinkModeBoth;
    return value == kSidebarLinkModeNone ? kSidebarLinkModeNone : kSidebarLinkModeTreeToPanels;
}

static BOOL NCSidebarStoredExpansion(NSString *_key, BOOL _fallback)
{
    NSUserDefaults *const defaults = NSUserDefaults.standardUserDefaults;
    return [defaults objectForKey:_key] ? [defaults boolForKey:_key] : _fallback;
}

// 2.1.29: the sections can be shuffled by the user. The order is stored as stable tokens
// (not indices) so the per-section expansion bookkeeping keeps working unchanged.
static NSString *const g_ConfigSidebarSectionOrder = @"nc.sidebar.order";
static NSString *const g_SidebarSectionPBoardType = @"com.magnumbytes.nc.sidebar.section";

@interface NCDirectoryTreeView : NSView <NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate>
@property(nonatomic, weak) id<NCDirectoryTreeDelegate> treeDelegate;
- (void)revealPath:(NSString *)path;
- (void)rebuildSections;
@end

@implementation NCDirectoryTreeView {
    NSOutlineView *_outline;
    NSScrollView *_scroll; // MUST wrap the outline, else its full row count becomes
                           // the intrinsic height and blows up the whole split view (no scroll).
    NCDirectoryTreeNode *_root; // invisible container, its children are the sections
    NCDirectoryTreeNode *_workspacesSection;
    NCDirectoryTreeNode *_favoritesSection;
    NCDirectoryTreeNode *_recentSection;
    NCDirectoryTreeNode *_foldersSection;
    NCDirectoryTreeNode *_folderRoot; // the "/" tree itself
    nc::panel::FavoriteLocationsStorage *_favoritesStorage; // owned by the app delegate
    std::optional<nc::panel::FavoriteLocationsStorage::ObservationTicket> _favoritesTicket;
    NCDirectoryTreeNode *_contextNode; // the row the context menu was opened on
    BOOL _rebuilding;
    NSInteger _pendingSectionDropIndex; // 2.1.29: insertion slot agreed on in validateDrop
}
@synthesize treeDelegate = _treeDelegate;

static NSImage *NCSidebarSymbolIcon(NSString *_symbol)
{
    NSImage *const image = [NSImage imageWithSystemSymbolName:_symbol accessibilityDescription:nil];
    if( !image )
        return nil;
    image.size = NSMakeSize(14, 14);
    return image;
}

// Favorites have an optional user-defined title; recents only have a verbose path
// like "~/Downloads" or "smb://nas/media/", so fall back to its last component.
static NSString *NCSidebarNameForLocation(const FavoriteLocationsStorage::Location &_location,
                                          const std::string &_title)
{
    if( !_title.empty() ) {
        if( NSString *const title = [NSString stringWithUTF8StdString:_title] )
            return title;
    }
    NSString *const verbose = [NSString stringWithUTF8StdString:_location.verbose_path];
    if( verbose.length == 0 )
        return @"";
    NSString *const trimmed = [verbose stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSString *const without_slash = [trimmed hasSuffix:@"/"] ? [trimmed substringToIndex:trimmed.length - 1] : trimmed;
    NSString *const tail = without_slash.lastPathComponent;
    return tail.length ? tail : trimmed;
}

static NSImage *NCSidebarIconForLocation(const FavoriteLocationsStorage::Location &_location)
{
    if( _location.hosts_stack.is_native() ) {
        NSString *const path = [NSString stringWithUTF8StdString:_location.hosts_stack.path];
        if( path.length ) {
            NSImage *const icon = [NSWorkspace.sharedWorkspace iconForFile:path];
            if( icon ) {
                icon.size = NSMakeSize(16, 16);
                return icon;
            }
        }
    }
    if( NSImage *const symbol = NCSidebarSymbolIcon(@"folder") )
        return symbol;
    return [NSWorkspace.sharedWorkspace iconForFile:@"/"];
}

static NSMenuItem *NCSidebarMenuItem(NSString *_title, id _target, SEL _action)
{
    NSMenuItem *const item = [[NSMenuItem alloc] initWithTitle:_title action:_action keyEquivalent:@""];
    item.target = _target;
    return item;
}

- (instancetype)initWithFrame:(NSRect)frameRect
{
    self = [super initWithFrame:frameRect];
    if( !self )
        return nil;

    // Sections, top to bottom: Favorites / Recent / the always-there folder tree.
    // A single outline keeps the existing lazy-loading tree code intact.
    _root = [NCDirectoryTreeNode groupWithTitle:@"" kind:NCSidebarNodeKindGroup];
    _workspacesSection = [NCDirectoryTreeNode groupWithTitle:NSLocalizedString(@"Workspaces", "Sidebar section with saved window layouts")
                                                       kind:NCSidebarNodeKindGroup];
    _favoritesSection = [NCDirectoryTreeNode groupWithTitle:NSLocalizedString(@"Favorites", "Sidebar section with saved locations")
                                                      kind:NCSidebarNodeKindGroup];
    _recentSection = [NCDirectoryTreeNode groupWithTitle:NSLocalizedString(@"Recent", "Sidebar section with recently visited folders")
                                                   kind:NCSidebarNodeKindGroup];
    _foldersSection = [NCDirectoryTreeNode groupWithTitle:NSLocalizedString(@"Folders", "Sidebar section with the folder tree")
                                                    kind:NCSidebarNodeKindGroup];
    _folderRoot = [[NCDirectoryTreeNode alloc] initWithPath:@"/"];
    _foldersSection.children = [NSMutableArray arrayWithObject:_folderRoot];
    _root.children = [NSMutableArray arrayWithObjects:_workspacesSection, _favoritesSection, _recentSection, _foldersSection, nil];
    _pendingSectionDropIndex = -1;
    [self applyStoredSectionOrder];

    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    column.title = @"Folders";
    column.minWidth = 120;

    // Frame-based sizing on purpose: an NSTableView inside an NSScrollView grows its
    // own frame to fit the rows, which is exactly what gives the clip view something
    // to scroll. With translatesAutoresizingMaskIntoConstraints = NO and no height
    // constraint the document height just stayed equal to the viewport, so a long
    // expanded tree was clipped with no scroll range at all.
    _outline = [[NSOutlineView alloc] initWithFrame:NSMakeRect(0, 0, kDirectoryTreeWidth, 0)];
    _outline.translatesAutoresizingMaskIntoConstraints = YES;
    _outline.autoresizingMask = NSViewWidthSizable;
    [_outline addTableColumn:column];
    _outline.outlineTableColumn = column;
    _outline.dataSource = self;
    _outline.delegate = self;
    _outline.target = self;
    _outline.action = @selector(onOutlineClicked:);
    _outline.rowHeight = 22;
    _outline.indentationPerLevel = 14;
    _outline.autoresizesOutlineColumn = YES;
    _outline.allowsMultipleSelection = NO;
    // Folders dragged out of the file panels or Finder land in Favorites.
    [_outline registerForDraggedTypes:@[NSPasteboardTypeFileURL, g_SidebarSectionPBoardType]];

    // Right-click on a row: add/remove favorites, clear recents, open in the
    // other pane. NSMenu's delegate rebuilds itself from the clicked row.
    NSMenu *const context_menu = [[NSMenu alloc] initWithTitle:@""];
    context_menu.delegate = self;
    _outline.menu = context_menu;

    // an NSOutlineView outside a scroll view reports its
    // full content height as intrinsic size. That inflated m_SplitView to ~1200px
    // inside a 750px window, so BOTH the tree and the right file panels scrolled
    // off-screen with no visible scroller. Wrap it in a real NSScrollView whose
    // clipsToBounds keeps the document height out of Auto Layout's fitting pass.
    _scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _scroll.translatesAutoresizingMaskIntoConstraints = NO;
    _scroll.hasVerticalScroller = YES;
    _scroll.hasHorizontalScroller = NO;
    _scroll.autohidesScrollers = YES;
    _scroll.drawsBackground = NO;
    _scroll.documentView = _outline;
    [self addSubview:_scroll];
    NSDictionary *views = NSDictionaryOfVariableBindings(_scroll);
    [self addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"|-(0)-[_scroll]-(0)-|"
                                                                 options:0
                                                                 metrics:nil
                                                                   views:views]];
    [self addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|-(0)-[_scroll]-(0)-|"
                                                                 options:0
                                                                 metrics:nil
                                                                   views:views]];

    // Expand to the user's home directory on first layout so the tree is useful
    // immediately instead of showing a single collapsed "/" row.
    dispatch_async(dispatch_get_main_queue(), ^{ [self revealPath:NSHomeDirectory()]; });
    return self;
}

// The storage is created by the app delegate, which may outlive/underlive this view,
// so grab it lazily and (re)subscribe whenever the pointer changes.
- (void)attachFavoritesStorageIfNeeded
{
    FavoriteLocationsStorage *const storage = NCAppDelegate.me.favoriteLocationsStorage.get();
    if( storage == _favoritesStorage )
        return;
    _favoritesTicket.reset();
    _favoritesStorage = storage;
    if( _favoritesStorage ) {
        __weak NCDirectoryTreeView *weak_self = self;
        _favoritesTicket = _favoritesStorage->ObserveFavoritesChanges([weak_self] { [weak_self rebuildSections]; });
    }
}

// Rebuilds the Favorites / Recent sections from the storage. The folder tree itself
// is untouched - it stays lazily loaded, only its expansion state is preserved.
- (void)rebuildSections
{
    if( _rebuilding )
        return;
    [self attachFavoritesStorageIfNeeded];

    // 2.1.18: the stored preference is the source of truth, not the outline's live
    // state. The old "numberOfRows == 0 means first build" test stopped holding once
    // the outline had rows laid out, so launch read "collapsed" and every section
    // silently closed. Reading the preference also makes a failed programmatic
    // expand harmless - the next rebuild simply retries it.
    const BOOL workspaces_was_expanded = NCSidebarStoredExpansion(g_ConfigSidebarExpandedWorkspaces, YES);
    const BOOL favorites_was_expanded = NCSidebarStoredExpansion(g_ConfigSidebarExpandedFavorites, YES);
    const BOOL recent_was_expanded = NCSidebarStoredExpansion(g_ConfigSidebarExpandedRecent, YES);
    const BOOL folders_was_expanded = NCSidebarStoredExpansion(g_ConfigSidebarExpandedFolders, YES);
    const BOOL folder_root_was_expanded = NCSidebarStoredExpansion(g_ConfigSidebarExpandedFolderRoot, NO);

    NSMutableArray<NCDirectoryTreeNode *> *const workspaces = [NSMutableArray array];
    const auto workspace_states = GlobalConfig().Get(g_ConfigWorkspaces);
    if( workspace_states.IsArray() ) {
        for( rapidjson::SizeType i = 0; i < workspace_states.Size(); ++i ) {
            const auto &entry = workspace_states[i];
            if( !entry.IsObject() || !entry.HasMember("name") || !entry["name"].IsString() )
                continue;
            NCDirectoryTreeNode *const node = [NCDirectoryTreeNode new];
            node.kind = NCSidebarNodeKindWorkspace;
            node.name = [NSString stringWithUTF8StdString:entry["name"].GetString()] ?: @"";
            node.icon = NCSidebarSymbolIcon(@"square.grid.2x2");
            node.entryIndex = static_cast<NSInteger>(i); // raw index, the same one config editing uses
            [workspaces addObject:node];
        }
    }
    NCDirectoryTreeNode *const save_action = [NCDirectoryTreeNode new];
    save_action.kind = NCSidebarNodeKindAction;
    save_action.name = NSLocalizedString(@"Save Workspace…", "Sidebar row to save the current window layout as a workspace");
    save_action.icon = NCSidebarSymbolIcon(@"plus.circle");
    save_action.entryIndex = -1;
    [workspaces addObject:save_action];

    NSMutableArray<NCDirectoryTreeNode *> *const favorites = [NSMutableArray array];
    if( _favoritesStorage ) {
        NSInteger favorite_index = 0;
        for( const auto &favorite : _favoritesStorage->Favorites() ) {
            NSString *const path = [NSString stringWithUTF8StdString:favorite.location->hosts_stack.path] ?: @"";
            NCDirectoryTreeNode *const node = [[NCDirectoryTreeNode alloc] initWithPath:path];
            node.kind = NCSidebarNodeKindBookmark;
            node.name = NCSidebarNameForLocation(*favorite.location, favorite.title);
            node.icon = NCSidebarIconForLocation(*favorite.location);
            node.location = [[AnyHolder alloc] initWithAny:std::any(favorite.location->hosts_stack)];
            node.entryIndex = favorite_index++;
            [favorites addObject:node];
        }
    }

    NSMutableArray<NCDirectoryTreeNode *> *const recent = [NSMutableArray array];
    if( _favoritesStorage ) {
        NSInteger recent_index = 0;
        for( const auto &location : _favoritesStorage->FrecentlyUsed(NCSidebarRecentLimit()) ) {
            NSString *const path = [NSString stringWithUTF8StdString:location->hosts_stack.path] ?: @"";
            NCDirectoryTreeNode *const node = [[NCDirectoryTreeNode alloc] initWithPath:path];
            node.kind = NCSidebarNodeKindRecent;
            node.name = NCSidebarNameForLocation(*location, "");
            node.icon = NCSidebarIconForLocation(*location);
            node.location = [[AnyHolder alloc] initWithAny:std::any(location->hosts_stack)];
            node.entryIndex = recent_index++;
            [recent addObject:node];
        }
    }

    _rebuilding = YES;
    _workspacesSection.children = workspaces;
    _favoritesSection.children = favorites;
    _recentSection.children = recent;
    _workspacesSection.icon = NCSidebarSymbolIcon(@"rectangle.3.group");
    _favoritesSection.icon = NCSidebarSymbolIcon(@"star");
    _recentSection.icon = NCSidebarSymbolIcon(@"clock");
    _foldersSection.icon = NCSidebarSymbolIcon(@"folder");

    [self applyStoredSectionOrder];
    [_outline reloadData];
    if( workspaces_was_expanded )
        [_outline expandItem:_workspacesSection];
    if( favorites_was_expanded )
        [_outline expandItem:_favoritesSection];
    if( recent_was_expanded )
        [_outline expandItem:_recentSection];
    if( folders_was_expanded )
        [_outline expandItem:_foldersSection];
    if( folder_root_was_expanded ) {
        [_outline expandItem:_folderRoot];
        // 2.1.19: reopen the tree down to the depth the user left it at.
        [self restoreExpandedFolderPaths];
    }
    _rebuilding = NO;
}

// MARK: section ordering (2.1.29)

- (NSString *)sectionTokenForNode:(NCDirectoryTreeNode *)node
{
    if( node == nil )
        return nil;
    if( node == _workspacesSection )
        return @"workspaces";
    if( node == _favoritesSection )
        return @"favorites";
    if( node == _recentSection )
        return @"recent";
    if( node == _foldersSection )
        return @"folders";
    return nil;
}

- (NCDirectoryTreeNode *)sectionNodeForToken:(NSString *)token
{
    if( [token isEqualToString:@"workspaces"] )
        return _workspacesSection;
    if( [token isEqualToString:@"favorites"] )
        return _favoritesSection;
    if( [token isEqualToString:@"recent"] )
        return _recentSection;
    if( [token isEqualToString:@"folders"] )
        return _foldersSection;
    return nil;
}

// The stored array wins, but it may be incomplete (fresh install, or a token we stopped
// using) - whatever it does not mention is appended in the default order.
- (NSArray<NSString *> *)storedSectionOrder
{
    NSArray<NSString *> *const all = @[@"workspaces", @"favorites", @"recent", @"folders"];
    NSMutableArray<NSString *> *const order = [NSMutableArray arrayWithCapacity:all.count];
    for( id token in [NSUserDefaults.standardUserDefaults arrayForKey:g_ConfigSidebarSectionOrder] )
        if( [token isKindOfClass:NSString.class] && [all containsObject:token] && ![order containsObject:token] )
            [order addObject:token];
    for( NSString *token in all )
        if( ![order containsObject:token] )
            [order addObject:token];
    return order;
}

- (void)applyStoredSectionOrder
{
    NSMutableArray<NCDirectoryTreeNode *> *const ordered = [NSMutableArray arrayWithCapacity:4];
    for( NSString *token in [self storedSectionOrder] )
        if( NCDirectoryTreeNode *const section = [self sectionNodeForToken:token] )
            [ordered addObject:section];
    _root.children = ordered;
}

- (void)storeSectionOrder
{
    NSMutableArray<NSString *> *const tokens = [NSMutableArray arrayWithCapacity:4];
    for( NCDirectoryTreeNode *section in _root.children )
        if( NSString *const token = [self sectionTokenForNode:section] )
            [tokens addObject:token];
    if( tokens.count != 4 )
        return;
    // Same re-entrancy guard as the expansion bookkeeping: writing defaults posts a
    // synchronous change notification, which must not rebuild the sidebar underneath us.
    g_WritingSidebarDefaults = YES;
    [NSUserDefaults.standardUserDefaults setObject:tokens forKey:g_ConfigSidebarSectionOrder];
    g_WritingSidebarDefaults = NO;
}

- (void)moveSection:(NCDirectoryTreeNode *)node by:(NSInteger)offset
{
    NSMutableArray<NCDirectoryTreeNode *> *const order = [NSMutableArray arrayWithArray:_root.children];
    const NSInteger from = static_cast<NSInteger>([order indexOfObject:node]);
    const NSInteger to = from + offset;
    if( from == NSNotFound || to < 0 || to >= static_cast<NSInteger>(order.count) )
        return;
    [order exchangeObjectAtIndex:from withObjectAtIndex:to];
    _root.children = order;
    // Persist the live expansion state first: rebuildSections re-applies it from the
    // preferences, so anything not yet written down would snap back to the default.
    [self storeSectionExpansions];
    [self storeSectionOrder];
    [self rebuildSections];
}

- (IBAction)onMoveSectionUp:(id) [[maybe_unused]] _sender
{
    [self moveSection:_contextNode by:-1];
}

- (IBAction)onMoveSectionDown:(id) [[maybe_unused]] _sender
{
    [self moveSection:_contextNode by:+1];
}

- (id<NSPasteboardWriting>)outlineView:(NSOutlineView *) [[maybe_unused]] outline_view
                pasteboardWriterForItem:(id)item
{
    NSString *const token = [self sectionTokenForNode:static_cast<NCDirectoryTreeNode *>(item)];
    if( token == nil )
        return nil;
    NSPasteboardItem *const pb = [NSPasteboardItem new];
    [pb setString:token forType:g_SidebarSectionPBoardType];
    return pb;
}

- (void)loadChildrenForNode:(NCDirectoryTreeNode *)node
{
    if( node.childrenLoaded )
        return;
    node.childrenLoaded = YES;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSString *> *names = [fm contentsOfDirectoryAtPath:node.path error:nil];
    if( !names )
        return;
    NSMutableArray<NCDirectoryTreeNode *> *kids = [NSMutableArray arrayWithCapacity:names.count];
    for( NSString *name in names ) {
        if( [name hasPrefix:@"."] )
            continue;
        NSString *full = [node.path stringByAppendingPathComponent:name];
        BOOL is_dir = NO;
        if( ![fm fileExistsAtPath:full isDirectory:&is_dir] || !is_dir )
            continue;
        [kids addObject:[[NCDirectoryTreeNode alloc] initWithPath:full]];
    }
    [kids sortUsingComparator:^NSComparisonResult(NCDirectoryTreeNode *lhs, NCDirectoryTreeNode *rhs) {
        return [lhs.name localizedCompare:rhs.name];
    }];
    node.children = kids;
}

- (NSInteger)outlineView:(NSOutlineView *)outline_view numberOfChildrenOfItem:(id)item
{
    NCDirectoryTreeNode *node = item ?: _root;
    if( node.kind != NCSidebarNodeKindGroup )
        [self loadChildrenForNode:node];
    return node.children.count;
}

- (id)outlineView:(NSOutlineView *)outline_view child:(NSInteger)index ofItem:(id)item
{
    NCDirectoryTreeNode *node = item ?: _root;
    if( node.kind != NCSidebarNodeKindGroup )
        [self loadChildrenForNode:node];
    return index >= 0 && index < static_cast<NSInteger>(node.children.count) ? node.children[index] : nil;
}

- (BOOL)outlineView:(NSOutlineView *)outline_view isItemExpandable:(id)item
{
    NCDirectoryTreeNode *node = item ?: _root;
    if( node.kind == NCSidebarNodeKindGroup )
        return node.children.count > 0;
    BOOL is_dir = NO;
    return [NSFileManager.defaultManager fileExistsAtPath:node.path isDirectory:&is_dir] && is_dir;
}

- (BOOL)outlineView:(NSOutlineView *)outline_view isGroupItem:(id)item
{
    const auto node = item ? static_cast<NCDirectoryTreeNode *>(item) : _root;
    return node.kind == NCSidebarNodeKindGroup;
}

- (BOOL)outlineView:(NSOutlineView *)outline_view shouldSelectItem:(id)item
{
    const auto node = static_cast<NCDirectoryTreeNode *>(item);
    return node.kind != NCSidebarNodeKindGroup;
}

// 2.1.18: remember the user's expand/collapse choice per section. The five states are
// read straight from the outline, which avoids depending on the notification's
// userInfo key - the SDK does not export that constant.
- (void)storeSectionExpansions
{
    // AppKit fires these while rebuildSections re-applies the stored layout;
    // writing then would echo programmatic state back into the preferences.
    if( _rebuilding )
        return;
    NSUserDefaults *const defaults = NSUserDefaults.standardUserDefaults;
    // 2.1.25: writing defaults posts NSUserDefaultsDidChangeNotification synchronously,
    // which used to rebuild the sidebar in the middle of this write - the rebuild read
    // the previous folderPaths and re-expanded the node the user had just collapsed,
    // and the write then persisted that re-expanded state. Guard our own writes.
    g_WritingSidebarDefaults = YES;
    [defaults setBool:[_outline isItemExpanded:_workspacesSection] forKey:g_ConfigSidebarExpandedWorkspaces];
    [defaults setBool:[_outline isItemExpanded:_favoritesSection] forKey:g_ConfigSidebarExpandedFavorites];
    [defaults setBool:[_outline isItemExpanded:_recentSection] forKey:g_ConfigSidebarExpandedRecent];
    [defaults setBool:[_outline isItemExpanded:_foldersSection] forKey:g_ConfigSidebarExpandedFolders];
    [defaults setBool:[_outline isItemExpanded:_folderRoot] forKey:g_ConfigSidebarExpandedFolderRoot];

    // 2.1.19: sections are only the top level - the folder tree itself remembers how
    // deep it was opened, otherwise reopening to "Macintosh HD" loses every level.
    // A collapsed section hides the whole tree, so don't let that wipe the record.
    if( [_outline isItemExpanded:_foldersSection] ) {
        NSMutableArray<NSString *> *const expanded_folders = [NSMutableArray array];
        [self collectExpandedFolderPathsFromNode:_folderRoot into:expanded_folders];
        [defaults setObject:expanded_folders forKey:g_ConfigSidebarExpandedFolderPaths];
    }
    g_WritingSidebarDefaults = NO;
}

// Only already-loaded children are walked: an expanded row is always loaded, and
// touching unloaded nodes here would stat the whole disk on every click.
- (void)collectExpandedFolderPathsFromNode:(NCDirectoryTreeNode *)node into:(NSMutableArray<NSString *> *)paths
{
    for( NCDirectoryTreeNode *child in node.children ) {
        if( child.kind != NCSidebarNodeKindDirectory || ![_outline isItemExpanded:child] )
            continue;
        if( child.path.length )
            [paths addObject:child.path];
        [self collectExpandedFolderPathsFromNode:child into:paths];
    }
}

- (void)restoreExpandedFolderPaths
{
    NSArray *const stored = [NSUserDefaults.standardUserDefaults arrayForKey:g_ConfigSidebarExpandedFolderPaths];
    // Restored even while the section is collapsed: AppKit keeps the expansion
    // state of hidden items, so the tree is already at the right depth the moment
    // the user opens the section again.
    if( stored.count == 0 )
        return;
    for( id entry in stored ) {
        if( ![entry isKindOfClass:NSString.class] )
            continue;
        NSString *const path = static_cast<NSString *>(entry);
        if( path.length == 0 )
            continue;
        NCDirectoryTreeNode *node = _folderRoot;
        for( NSString *component in path.pathComponents ) {
            if( [component isEqualToString:@"/"] )
                continue;
            [self loadChildrenForNode:node];
            NCDirectoryTreeNode *match = nil;
            for( NCDirectoryTreeNode *candidate in node.children ) {
                if( [candidate.name isEqualToString:component] ||
                    [candidate.path.lastPathComponent isEqualToString:component] ) {
                    match = candidate;
                    break;
                }
            }
            if( !match )
                break;
            [_outline expandItem:match];
            node = match;
        }
    }
}

- (void)outlineViewItemDidExpand:(NSNotification *) [[maybe_unused]] _notification
{
    [self storeSectionExpansions];
}

- (void)outlineViewItemDidCollapse:(NSNotification *) [[maybe_unused]] _notification
{
    [self storeSectionExpansions];
}

- (NSView *)outlineView:(NSOutlineView *)outline_view viewForTableColumn:(NSTableColumn *)column item:(id)item
{
    NCDirectoryTreeNode *node = item ?: _root;
    NSTableCellView *cell = [outline_view makeViewWithIdentifier:@"NCDirCell" owner:self];
    if( !cell ) {
        cell = [[NSTableCellView alloc] initWithFrame:NSZeroRect];
        cell.identifier = @"NCDirCell";
        NSImageView *image = [[NSImageView alloc] initWithFrame:NSMakeRect(2, 3, 16, 16)];
        NSTextField *label = [[NSTextField alloc] initWithFrame:NSMakeRect(22, 2, 180, 18)];
        label.bezeled = NO;
        label.drawsBackground = NO;
        label.editable = NO;
        label.selectable = NO;
        label.font = [NSFont systemFontOfSize:12];
        label.lineBreakMode = NSLineBreakByTruncatingTail;
        [cell addSubview:image];
        [cell addSubview:label];
        cell.imageView = image;
        cell.textField = label;
    }
    cell.textField.stringValue = node.name;

    // cells are recycled, so both style attributes have to be reset on every pass
    if( node.kind == NCSidebarNodeKindGroup ) {
        cell.textField.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
        cell.textField.textColor = NSColor.secondaryLabelColor;
        cell.imageView.image = node.icon;
        return cell;
    }
    cell.textField.font = [NSFont systemFontOfSize:12];
    cell.textField.textColor = NSColor.labelColor;

    if( !node.icon ) {
        if( node.path.length ) {
            node.icon = [NSWorkspace.sharedWorkspace iconForFile:node.path];
            node.icon.size = NSMakeSize(16, 16);
        }
        else {
            node.icon = NCSidebarSymbolIcon(@"folder");
        }
    }
    cell.imageView.image = node.icon;
    return cell;
}

- (void)onOutlineClicked:(id)sender
{
    const NSInteger row = _outline.selectedRow;
    if( row < 0 )
        return;
    NCDirectoryTreeNode *node = [_outline itemAtRow:row];
    if( !node )
        return;
    const NSEventModifierFlags modifiers = NSApp.currentEvent.modifierFlags;
    switch( node.kind ) {
        case NCSidebarNodeKindBookmark:
        case NCSidebarNodeKindRecent:
            if( node.location )
                [_treeDelegate directoryTreeDidSelectLocation:node.location modifiers:modifiers];
            break;
        case NCSidebarNodeKindDirectory:
            if( node.path.length )
                [_treeDelegate directoryTreeDidSelectPath:node.path modifiers:modifiers];
            break;
        case NCSidebarNodeKindWorkspace:
            if( node.entryIndex >= 0 )
                [_treeDelegate directoryTreeDidApplyWorkspaceAtIndex:node.entryIndex];
            break;
        case NCSidebarNodeKindAction:
            [_treeDelegate directoryTreeDidRequestSaveWorkspace];
            break;
        case NCSidebarNodeKindGroup:
            break;
    }
}

// MARK: sidebar drag & drop (folders -> Favorites)

// Only real, local directories are meaningful here: favorites store a native
// VFS location, so a dropped archive/symlink-to-nothing is rejected.
- (NSArray<NSURL *> *)draggedDirectoryURLs:(id<NSDraggingInfo>)_info
{
    NSArray<NSURL *> *const urls = [_info.draggingPasteboard
        readObjectsForClasses:@[ NSURL.class ]
                      options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    NSMutableArray<NSURL *> *const directories = [NSMutableArray array];
    for( NSURL *url in urls ) {
        if( url.path.length == 0 )
            continue;
        BOOL is_dir = NO;
        if( [NSFileManager.defaultManager fileExistsAtPath:url.path isDirectory:&is_dir] && is_dir )
            [directories addObject:url];
    }
    return directories;
}

- (NSDragOperation)outlineView:(NSOutlineView *) [[maybe_unused]] outline_view
                   validateDrop:(id<NSDraggingInfo>)info
                    proposedItem:(id)item
              proposedChildIndex:(NSInteger)index
{
    // 2.1.29: a dragged section header only reorders the top level - either between two
    // sections, or onto another section, in which case it lands in front of it.
    if( [info.draggingPasteboard stringForType:g_SidebarSectionPBoardType] ) {
        NCDirectoryTreeNode *const target = item ? static_cast<NCDirectoryTreeNode *>(item) : nil;
        NSInteger insert_at = 0;
        if( target == nil )
            insert_at = index == NSOutlineViewDropOnItemIndex ? static_cast<NSInteger>(_root.children.count)
                                                              : index;
        else if( [self sectionTokenForNode:target] != nil )
            insert_at = static_cast<NSInteger>([_root.children indexOfObject:target]);
        else
            return NSDragOperationNone;
        _pendingSectionDropIndex = insert_at;
        [_outline setDropItem:nil dropChildIndex:insert_at];
        return NSDragOperationMove;
    }

    if( _favoritesStorage == nullptr )
        return NSDragOperationNone;

    // only the Favorites section (or one of its rows) accepts drops
    const auto target = item ? static_cast<NCDirectoryTreeNode *>(item) : nil;
    const BOOL over_favorites =
        target == _favoritesSection || (target != nil && target.kind == NCSidebarNodeKindBookmark);
    if( !over_favorites )
        return NSDragOperationNone;
    if( [self draggedDirectoryURLs:info].count == 0 )
        return NSDragOperationNone;

    // always append to the section, never insert between rows
    [_outline setDropItem:_favoritesSection dropChildIndex:NSOutlineViewDropOnItemIndex];
    return NSDragOperationCopy;
}

- (BOOL)outlineView:(NSOutlineView *) [[maybe_unused]] outline_view
         acceptDrop:(id<NSDraggingInfo>)info
               item:(id) [[maybe_unused]] item
         childIndex:(NSInteger) [[maybe_unused]] index
{
    if( NSString *const dragged_token = [info.draggingPasteboard stringForType:g_SidebarSectionPBoardType] ) {
        NCDirectoryTreeNode *const dragged = [self sectionNodeForToken:dragged_token];
        if( dragged == nil )
            return NO;
        NSMutableArray<NCDirectoryTreeNode *> *const order = [NSMutableArray arrayWithArray:_root.children];
        const NSInteger from = static_cast<NSInteger>([order indexOfObject:dragged]);
        if( from == NSNotFound )
            return NO;
        NSInteger to = _pendingSectionDropIndex >= 0 ? _pendingSectionDropIndex : static_cast<NSInteger>(order.count);
        [order removeObjectAtIndex:from];
        if( from < to )
            --to; // removing the source shifted every slot after it one position left
        to = MAX(0, MIN(to, static_cast<NSInteger>(order.count)));
        [order insertObject:dragged atIndex:to];
        _root.children = order;
        [self storeSectionExpansions];
        [self storeSectionOrder];
        [self rebuildSections];
        return YES;
    }

    if( _favoritesStorage == nullptr )
        return NO;

    NSUInteger added = 0;
    for( NSURL *url in [self draggedDirectoryURLs:info] ) {
        if( auto favorite = _favoritesStorage->ComposeFavoriteLocation(
                *nc::bootstrap::NativeVFSHostInstance().SharedPtr(), url.path.fileSystemRepresentation) ) {
            _favoritesStorage->AddFavoriteLocation(std::move(*favorite));
            ++added;
        }
    }
    if( added > 0 )
        [self rebuildSections];
    return added > 0;
}

// MARK: sidebar context menu

- (void)menuNeedsUpdate:(NSMenu *)menu
{
    [menu removeAllItems];
    _contextNode = nil;

    const NSInteger row = _outline.clickedRow;
    if( row < 0 )
        return;
    NCDirectoryTreeNode *const node = [_outline itemAtRow:row];
    if( !node )
        return;
    _contextNode = node;

    if( node.kind == NCSidebarNodeKindGroup ) {
        if( node == _workspacesSection )
            [menu addItem:NCSidebarMenuItem(NSLocalizedString(@"Save Workspace…",
                                                              "Sidebar menu item to save the current layout"),
                                            self,
                                            @selector(onSaveWorkspaceFromSidebar:))];
        else if( node == _favoritesSection )
            [menu addItem:NCSidebarMenuItem(NSLocalizedString(@"Manage Favorites…",
                                                              "Sidebar menu item to open the favorites manager"),
                                            self,
                                            @selector(onManageFavoritesFromSidebar:))];
        else if( node == _recentSection )
            [menu addItem:NCSidebarMenuItem(NSLocalizedString(@"Clear Recents",
                                                              "Sidebar menu item to clear the recent folders list"),
                                            self,
                                            @selector(onClearRecentFromSidebar:))];
        // 2.1.29: a menu fallback for reordering - dragging a header works too, but a
        // two-item menu is what people actually look for.
        const NSUInteger section_index = [_root.children indexOfObject:node];
        [menu addItem:[NSMenuItem separatorItem]];
        NSMenuItem *const move_up = NCSidebarMenuItem(NSLocalizedString(@"Move Section Up",
                                                                        "Sidebar menu item to move a section up"),
                                                       self,
                                                       @selector(onMoveSectionUp:));
        move_up.enabled = section_index != NSNotFound && section_index > 0;
        [menu addItem:move_up];
        NSMenuItem *const move_down = NCSidebarMenuItem(NSLocalizedString(@"Move Section Down",
                                                                          "Sidebar menu item to move a section down"),
                                                         self,
                                                         @selector(onMoveSectionDown:));
        move_down.enabled = section_index != NSNotFound && section_index + 1 < _root.children.count;
        [menu addItem:move_down];
        return;
    }

    if( node.kind == NCSidebarNodeKindWorkspace ) {
        [menu addItem:NCSidebarMenuItem(NSLocalizedString(@"Update Workspace",
                                                          "Sidebar menu item to overwrite a workspace with the current layout"),
                                        self,
                                        @selector(onUpdateWorkspaceFromSidebar:))];
        [menu addItem:NCSidebarMenuItem(NSLocalizedString(@"Delete Workspace",
                                                          "Sidebar menu item to delete a saved workspace"),
                                        self,
                                        @selector(onDeleteWorkspaceFromSidebar:))];
        return;
    }
    if( node.kind == NCSidebarNodeKindAction ) {
        [menu addItem:NCSidebarMenuItem(NSLocalizedString(@"Save Workspace…",
                                                          "Sidebar menu item to save the current layout"),
                                        self,
                                        @selector(onSaveWorkspaceFromSidebar:))];
        return;
    }
    if( node.kind == NCSidebarNodeKindDirectory )
        [menu addItem:NCSidebarMenuItem(NSLocalizedString(@"Add to Favorites",
                                                          "Sidebar menu item to save the folder as a favorite"),
                                        self,
                                        @selector(onAddFolderToFavoritesFromSidebar:))];
    if( node.kind == NCSidebarNodeKindBookmark )
        [menu addItem:NCSidebarMenuItem(NSLocalizedString(@"Remove from Favorites",
                                                          "Sidebar menu item to remove a saved favorite"),
                                        self,
                                        @selector(onRemoveFavoriteFromSidebar:))];
    if( node.location || node.path.length ) {
        [menu addItem:[NSMenuItem separatorItem]];
        [menu addItem:NCSidebarMenuItem(NSLocalizedString(@"Open in Other Pane",
                                                          "Sidebar menu item to open the location in the opposite panel"),
                                        self,
                                        @selector(onOpenInOtherPaneFromSidebar:))];
    }
}

- (void)onAddFolderToFavoritesFromSidebar:(id) [[maybe_unused]] sender
{
    NCDirectoryTreeNode *const node = _contextNode;
    if( !_favoritesStorage || node.kind != NCSidebarNodeKindDirectory || node.path.length == 0 )
        return;
    if( auto favorite = _favoritesStorage->ComposeFavoriteLocation(*nc::bootstrap::NativeVFSHostInstance().SharedPtr(),
                                                                   node.path.UTF8String) )
        _favoritesStorage->AddFavoriteLocation(std::move(*favorite));
}

- (void)onRemoveFavoriteFromSidebar:(id) [[maybe_unused]] sender
{
    NCDirectoryTreeNode *const node = _contextNode;
    if( !_favoritesStorage || node.kind != NCSidebarNodeKindBookmark || node.entryIndex < 0 )
        return;
    auto favorites = _favoritesStorage->Favorites();
    if( node.entryIndex >= static_cast<NSInteger>(favorites.size()) )
        return;
    favorites.erase(favorites.begin() + node.entryIndex);
    _favoritesStorage->SetFavorites(favorites);
}

- (void)onClearRecentFromSidebar:(id) [[maybe_unused]] sender
{
    if( _favoritesStorage )
        _favoritesStorage->ClearVisitedLocations();
}

- (void)onManageFavoritesFromSidebar:(id) [[maybe_unused]] sender
{
    // the action is only implemented in AppDelegate.mm, hence no header declares it
    [NSApp sendAction:NSSelectorFromString(@"onMainMenuPerformShowFavorites:") to:NSApp.delegate from:self];
}

- (void)onSaveWorkspaceFromSidebar:(id) [[maybe_unused]] sender
{
    [_treeDelegate directoryTreeDidRequestSaveWorkspace];
}

- (void)onUpdateWorkspaceFromSidebar:(id) [[maybe_unused]] sender
{
    NCDirectoryTreeNode *const node = _contextNode;
    if( node.kind == NCSidebarNodeKindWorkspace && node.entryIndex >= 0 )
        [_treeDelegate directoryTreeDidRequestOverwriteWorkspaceAtIndex:node.entryIndex];
}

- (void)onDeleteWorkspaceFromSidebar:(id) [[maybe_unused]] sender
{
    NCDirectoryTreeNode *const node = _contextNode;
    if( node.kind == NCSidebarNodeKindWorkspace && node.entryIndex >= 0 )
        [_treeDelegate directoryTreeDidRequestDeleteWorkspaceAtIndex:node.entryIndex];
}

- (void)onOpenInOtherPaneFromSidebar:(id) [[maybe_unused]] sender
{
    NCDirectoryTreeNode *const node = _contextNode;
    if( !node )
        return;
    if( node.location )
        [_treeDelegate directoryTreeDidSelectLocation:node.location modifiers:NSEventModifierFlagOption];
    else if( node.path.length )
        [_treeDelegate directoryTreeDidSelectPath:node.path modifiers:NSEventModifierFlagOption];
}

- (void)revealPath:(NSString *)path
{
    if( !path.length || ![path hasPrefix:@"/"] )
        return;
    [self rebuildSections]; // keeps the recent list in sync with navigation

    // The user collapsed the folder tree - then there's nothing to highlight into,
    // and force-expanding it here would fight the very state they chose.
    if( ![_outline isItemExpanded:_foldersSection] )
        return;

    NSArray<NSString *> *parts = path.pathComponents;
    NSMutableArray<NCDirectoryTreeNode *> *chain = [NSMutableArray array];
    NCDirectoryTreeNode *node = _folderRoot;
    for( NSUInteger i = 1; i < parts.count; ++i ) {
        [self loadChildrenForNode:node];
        NSString *component = parts[i];
        NCDirectoryTreeNode *match = nil;
        for( NCDirectoryTreeNode *candidate in node.children ) {
            if( [candidate.name isEqualToString:component] ||
                [candidate.path.lastPathComponent isEqualToString:component] ) {
                match = candidate;
                break;
            }
        }
        if( !match )
            break;
        [chain addObject:node];
        node = match;
    }
    for( NCDirectoryTreeNode *ancestor in chain )
        [_outline expandItem:ancestor];
    const NSInteger row = [_outline rowForItem:node];
    if( row >= 0 ) {
        [_outline selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
        [_outline scrollRowToVisible:row];
    }
}

@end

@implementation MainWindowFilePanelState

@synthesize splitView = m_SplitView;
@synthesize closedPanelsHistory = m_ClosedPanelsHistory;
@synthesize favoriteLocationsStorage = m_FavoriteLocationsStorage;
@synthesize filePanelsToolsbar;

- (instancetype)initBaseWithFrame:(NSRect)frameRect
                          andPool:(nc::ops::Pool &)_pool
                     panelFactory:(std::function<PanelController *()>)_panel_factory
       controllerStateJSONDecoder:(ControllerStateJSONDecoder &)_controller_json_decoder
                   QLPanelAdaptor:(NCPanelQLPanelAdaptor *)_ql_panel_adaptor
{
    assert(_panel_factory);
    self = [super initWithFrame:frameRect];
    if( self ) {
        m_PanelFactory = std::move(_panel_factory);
        m_ControllerStateJSONDecoder = &_controller_json_decoder;
        m_ClosedPanelsHistory = nullptr;
        m_OperationsPool = _pool.shared_from_this();
        m_OverlappedTerminal = std::make_unique<MainWindowFilePanelState_OverlappedTerminalSupport>();
        m_ShowTabs = GlobalConfig().GetBool(g_ConfigGeneralShowTabs);
        m_QLPanelAdaptor = _ql_panel_adaptor;
        m_CommandHistoryPos = 0;

        m_LeftPanelControllers.emplace_back(m_PanelFactory());
        [self attachPanel:m_LeftPanelControllers.front()];

        m_RightPanelControllers.emplace_back(m_PanelFactory());
        [self attachPanel:m_RightPanelControllers.front()];

        [self CreateControls];

        [self updateTabBarsVisibility];
        [self loadOverlappedTerminalSettingsAndRunIfNecessary];

        [self setupNotificationsCallbacks];
    }
    return self;
}

- (instancetype)initWithFrame:(NSRect)frameRect
                       andPool:(nc::ops::Pool &)_pool
            loadDefaultContent:(bool)_load_content
                  panelFactory:(std::function<PanelController *()>)_panel_factory
    controllerStateJSONDecoder:(ControllerStateJSONDecoder &)_controller_json_decoder
                QLPanelAdaptor:(NCPanelQLPanelAdaptor *)_ql_panel_adaptor
{
    self = [self initBaseWithFrame:frameRect
                           andPool:_pool
                      panelFactory:std::move(_panel_factory)
        controllerStateJSONDecoder:_controller_json_decoder
                    QLPanelAdaptor:_ql_panel_adaptor];
    if( self ) {
        if( _load_content ) {
            [self restoreDefaultPanelOptions];
            [self loadDefaultPanelContent];
        }
    }
    return self;
}

- (void)restoreDefaultPanelOptions
{
    const auto defaults = StateConfig().Get(g_InitialStatePath);
    if( defaults.GetType() != rapidjson::kObjectType )
        return;

    const auto left_it = defaults.FindMember(g_InitialStateLeftDefaults);
    if( left_it != defaults.MemberEnd() )
        m_ControllerStateJSONDecoder->Decode(left_it->value, m_LeftPanelControllers.front());

    const auto right_it = defaults.FindMember(g_InitialStateRightDefaults);
    if( right_it != defaults.MemberEnd() )
        m_ControllerStateJSONDecoder->Decode(right_it->value, m_RightPanelControllers.front());

    [self applyConfiguredLayoutToPanels]; // default layout preference
}

// macOS window restoration (NSCoder archive) and State.json both
// restore layoutIndex. On first run we seed the list layout (index 2), whose
// NSScrollView has a real vertical scroller; afterwards the user's saved
// preference (nc.defaultPanelLayout) wins. The View -> View Mode menu writes
// that preference whenever the user switches layouts, so a deliberate switch
// to brief survives restarts AND app updates.
- (void)applyConfiguredLayoutToPanels
{
    const int layout = nc::panel::DefaultPanelLayout();
    for( PanelController *pc : m_LeftPanelControllers )
        pc.layoutIndex = layout;
    for( PanelController *pc : m_RightPanelControllers )
        pc.layoutIndex = layout;
}

- (void)setupNotificationsCallbacks
{
    m_ConfigTickets.emplace_back(
        GlobalConfig().Observe(g_ConfigGeneralShowTabs, nc::objc_callback(self, @selector(onShowTabsSettingChanged))));
    m_ThemesObservationTicket = NCAppDelegate.me.themesManager.ObserveChanges(
        nc::ThemesManager::Notifications::FilePanelsGeneral, nc::objc_callback(self, @selector(onThemeChanged)));
    // 2.1.21: the sidebar options are plain NSUserDefaults values.
    // 2.1.25: remember the baseline so only a real change triggers a rebuild.
    m_LastSidebarRecentLimit = NCSidebarRecentLimit();
    m_LastSmartDates = nc::panel::ListSmartDatesEnabled();
    m_LastSizeBars = nc::panel::ListSizeBarsEnabled();
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(onUserDefaultsChanged)
                                               name:NSUserDefaultsDidChangeNotification
                                             object:nil];
}

- (void)dealloc
{
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (BOOL)acceptsFirstResponder
{
    return true;
}

- (void)setNextResponder:(NSResponder *)newNextResponder
{
    if( self.attachedResponder ) {
        [self.attachedResponder setNextResponder:newNextResponder];
        return;
    }
    [super setNextResponder:newNextResponder];
}

- (void)setAttachedResponder:(AttachedResponder *)attachedResponder
{
    if( m_AttachedResponder == attachedResponder )
        return;
    m_AttachedResponder = attachedResponder;

    if( m_AttachedResponder ) {
        auto current = self.nextResponder;
        [super setNextResponder:m_AttachedResponder];
        m_AttachedResponder.nextResponder = current;
    }
}

- (AttachedResponder *)attachedResponder
{
    return m_AttachedResponder;
}

- (NSToolbar *)windowStateToolbar
{
    return m_ToolbarDelegate.toolbar;
}

- (NSView *)windowStateContentView
{
    return self;
}

- (BOOL)isOpaque
{
    return true;
}

- (BOOL)wantsUpdateLayer
{
    return true;
}

- (void)updateLayer
{
    self.layer.backgroundColor = nc::CurrentTheme().FilePanelsGeneralOverlayColor().CGColor;
}

- (void)loadDefaultPanelContent
{
    using nc::utility::PathManip;
    auto left_controller = m_LeftPanelControllers.front();
    auto right_controller = m_RightPanelControllers.front();
    std::vector<std::string> left_panel_desired_paths;
    std::vector<std::string> right_panel_desired_paths;

    // 1st attempt - load editable default path from config
    left_panel_desired_paths.emplace_back(EnsureTrailingSlash(
        PathManip::Expand(GlobalConfig().GetString(g_ConfigInitialLeftPath), nc::base::CommonPaths::Home(), {})));
    right_panel_desired_paths.emplace_back(EnsureTrailingSlash(
        PathManip::Expand(GlobalConfig().GetString(g_ConfigInitialRightPath), nc::base::CommonPaths::Home(), {})));

    // 2nd attempt - load home path
    left_panel_desired_paths.emplace_back(nc::base::CommonPaths::Home());
    right_panel_desired_paths.emplace_back(nc::base::CommonPaths::Home());

    // 3rd attempt - load first reachable folder in case of sandboxed environment
    if( nc::base::AmISandboxed() ) {
        left_panel_desired_paths.emplace_back(SandboxManager::Instance().FirstFolderWithAccess());
        right_panel_desired_paths.emplace_back(SandboxManager::Instance().FirstFolderWithAccess());
    }

    // 4rth attempt - load dir at startup cwd
    left_panel_desired_paths.emplace_back(nc::base::CommonPaths::StartupCWD());
    right_panel_desired_paths.emplace_back(nc::base::CommonPaths::StartupCWD());

    const auto try_to_load = [&](const std::vector<std::string> &_paths_to_try, PanelController *_panel) {
        for( auto &p : _paths_to_try ) {
            const auto request = std::make_shared<DirectoryChangeRequest>();
            request->RequestedDirectory = p;
            request->VFS = nc::bootstrap::NativeVFSHostInstance().SharedPtr();
            request->PerformAsynchronous = false;
            const std::expected<void, Error> result = [_panel GoToDirWithContext:request];
            if( result )
                break;
        }
    };

    try_to_load(left_panel_desired_paths, left_controller);
    try_to_load(right_panel_desired_paths, right_controller);
}

- (void)CreateControls
{
    m_SplitView = [[FilePanelMainSplitView alloc] initWithFrame:NSRect()
                                        actionsShortcutsManager:NCAppDelegate.me.actionsShortcutsManager];
    m_SplitView.translatesAutoresizingMaskIntoConstraints = NO;
    [m_SplitView.leftTabbedHolder addPanel:m_LeftPanelControllers.front().view];
    [m_SplitView.rightTabbedHolder addPanel:m_RightPanelControllers.front().view];
    m_SplitView.leftTabbedHolder.tabBar.delegate = self;
    m_SplitView.rightTabbedHolder.tabBar.delegate = self;
    [self addSubview:m_SplitView];

    [self createDirectoryTree];

    m_SeparatorLine = [[ColoredSeparatorLine alloc] initWithFrame:NSRect()];
    m_SeparatorLine.translatesAutoresizingMaskIntoConstraints = NO;
    m_SeparatorLine.borderColor = nc::CurrentTheme().FilePanelsGeneralTopSeparatorColor();
    [self addSubview:m_SeparatorLine];

    m_ToolbarDelegate =
        [[MainWindowFilePanelsStateToolbarDelegate alloc] initWithToolsStorage:NCAppDelegate.me.externalTools
                                                       actionsShortcutsManager:NCAppDelegate.me.actionsShortcutsManager
                                                             andOperationsPool:self.operationsPool];
    m_ToolbarDelegate.treeToggleTarget = self; // v6
    m_ToolbarDelegate.commandPaletteTarget = self; // 2.1.5

    auto views = NSDictionaryOfVariableBindings(m_SeparatorLine, m_SplitView, m_DirectoryTree, m_TreeDivider);
    auto contraints = {@"V:|-(==0@250)-[m_SeparatorLine(==1)]-(==0)-[m_SplitView(>=150@500)]",
                       // tree + 1px divider occupy the left edge; panels start after them.
                       // divider width is an explicit constraint below so the toolbar
                       // toggle can collapse tree AND divider together (no leftover 1px line).
                       @"|-(0)-[m_DirectoryTree]-(0)-[m_TreeDivider]-(0)-[m_SplitView]-(0)-|",
                       @"|-(==0)-[m_SeparatorLine]-(==0)-|"};
    for( auto vis_fmt : contraints )
        [self addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:vis_fmt
                                                                     options:0
                                                                     metrics:nil
                                                                       views:views]];
    // the tree and divider must share the SAME flexible bottom as
    // m_SplitView. Previously they were pinned to the superview bottom at REQUIRED
    // priority, which fixed the content view's height and made the window
    // vertically un-resizable (only width could change). Binding them to the
    // split view's bottom inherits its DragThatCannotResizeWindow priority.
    [self addConstraints:@[
        [NSLayoutConstraint constraintWithItem:m_DirectoryTree
                                     attribute:NSLayoutAttributeTop
                                     relatedBy:NSLayoutRelationEqual
                                        toItem:m_SeparatorLine
                                     attribute:NSLayoutAttributeBottom
                                    multiplier:1 constant:0],
        [NSLayoutConstraint constraintWithItem:m_DirectoryTree
                                     attribute:NSLayoutAttributeBottom
                                     relatedBy:NSLayoutRelationEqual
                                        toItem:m_SplitView
                                     attribute:NSLayoutAttributeBottom
                                    multiplier:1 constant:0],
        [NSLayoutConstraint constraintWithItem:m_TreeDivider
                                     attribute:NSLayoutAttributeTop
                                     relatedBy:NSLayoutRelationEqual
                                        toItem:m_SeparatorLine
                                     attribute:NSLayoutAttributeBottom
                                    multiplier:1 constant:0],
        [NSLayoutConstraint constraintWithItem:m_TreeDivider
                                     attribute:NSLayoutAttributeBottom
                                     relatedBy:NSLayoutRelationEqual
                                        toItem:m_SplitView
                                     attribute:NSLayoutAttributeBottom
                                    multiplier:1 constant:0]
    ]];
    m_MainSplitViewBottomConstraint = [NSLayoutConstraint constraintWithItem:m_SplitView
                                                                   attribute:NSLayoutAttributeBottom
                                                                   relatedBy:NSLayoutRelationEqual
                                                                      toItem:self
                                                                   attribute:NSLayoutAttributeBottom
                                                                  multiplier:1
                                                                    constant:0];
    // keep this LOW (490 = DragThatCannotResizeWindow). Any
    // priority >= WindowSizeStayPut(500) makes the panels' fitting height become
    // the window's fitting height, which locks vertical resizing entirely.
    m_MainSplitViewBottomConstraint.priority = NSLayoutPriorityDragThatCannotResizeWindow;
    m_MainSplitViewBottomConstraint.constant = -kFKeyBarTotalHeight; // reserve room for the bottom bar
    [self addConstraint:m_MainSplitViewBottomConstraint];

    m_LeftTreeWidthConstraint = [NSLayoutConstraint constraintWithItem:m_DirectoryTree
                                                             attribute:NSLayoutAttributeWidth
                                                             relatedBy:NSLayoutRelationEqual
                                                                toItem:nil
                                                             attribute:NSLayoutAttributeNotAnAttribute
                                                            multiplier:1
                                                              constant:kDirectoryTreeWidth];
    [self addConstraint:m_LeftTreeWidthConstraint];

    // explicit divider width, used by the show/hide toggle.
    m_TreeDividerWidthConstraint = [NSLayoutConstraint constraintWithItem:m_TreeDivider
                                                                attribute:NSLayoutAttributeWidth
                                                                relatedBy:NSLayoutRelationEqual
                                                                   toItem:nil
                                                                attribute:NSLayoutAttributeNotAnAttribute
                                                               multiplier:1
                                                                 constant:1];
    [self addConstraint:m_TreeDividerWidthConstraint];

    // restore persisted tree visibility (default: visible).
    m_ShowDirectoryTree = [NSUserDefaults.standardUserDefaults objectForKey:@"nc.showDirectoryTree"] == nil
                              ? YES
                              : [NSUserDefaults.standardUserDefaults boolForKey:@"nc.showDirectoryTree"];
    [self applyDirectoryTreeVisibility];

    if( !nc::base::AmISandboxed() ) {
        m_OverlappedTerminal->terminal = [[FilePanelOverlappedTerminal alloc] initWithFrame:self.bounds];
        m_OverlappedTerminal->terminal.translatesAutoresizingMaskIntoConstraints = false;
        [self addSubview:m_OverlappedTerminal->terminal positioned:NSWindowBelow relativeTo:nil];

        auto terminal = m_OverlappedTerminal->terminal;
        views = NSDictionaryOfVariableBindings(terminal, m_SeparatorLine);
        [self
            addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:[m_SeparatorLine]-(0)-[terminal]-(==30)-|"
                                                                   options:0
                                                                   metrics:nil
                                                                     views:views]];
        [self addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"|-(0)-[terminal]-(0)-|"
                                                                     options:0
                                                                     metrics:nil
                                                                       views:views]];
    }
    else {
        /* Fixing bugs in NSISEngine, kinda */
        NSView *dummy = [[NSView alloc] initWithFrame:self.bounds];
        dummy.translatesAutoresizingMaskIntoConstraints = false;
        [self addSubview:dummy positioned:NSWindowBelow relativeTo:nil];
        views = NSDictionaryOfVariableBindings(dummy);
        [self addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|-(==1)-[dummy(>=100)]-(==0)-|"
                                                                     options:0
                                                                     metrics:nil
                                                                       views:views]];
        [self addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"|-(0)-[dummy(>=100)]-(0)-|"
                                                                     options:0
                                                                     metrics:nil
                                                                       views:views]];
    }

    [self createFKeyBar];
}

// creates the always-visible directory tree on the left edge.
- (void)createDirectoryTree
{
    m_DirectoryTree = [[NCDirectoryTreeView alloc] initWithFrame:NSRect()];
    m_DirectoryTree.translatesAutoresizingMaskIntoConstraints = NO;
    m_DirectoryTree.treeDelegate = self;
    [self addSubview:m_DirectoryTree];

    // 2.1.16: drag the divider to resize the sidebar; double-click restores the default.
    NCSidebarDividerView *const divider = [[NCSidebarDividerView alloc] initWithFrame:NSRect()];
    divider.translatesAutoresizingMaskIntoConstraints = NO;
    divider.lineColor = nc::CurrentTheme().FilePanelsGeneralTopSeparatorColor();
    __weak MainWindowFilePanelState *weak_self = self;
    divider.onDragBegan = ^{
        [weak_self beginDirectoryTreeResize];
    };
    divider.onDragged = ^(CGFloat delta_x) {
        [weak_self resizeDirectoryTreeBy:delta_x];
    };
    divider.onDragEnded = ^{
        [weak_self commitDirectoryTreeWidth];
    };
    divider.onDoubleClicked = ^{
        [weak_self resetDirectoryTreeWidth];
    };
    m_TreeDivider = divider;
    [self addSubview:m_TreeDivider];
}

// 2.1.16: sidebar resize. The drag delta arrives in window coordinates, so the
// starting width has to be remembered - otherwise the moving view would feed
// back into the calculation and the handle would run away from the cursor.
- (void)beginDirectoryTreeResize
{
    m_TreeDragStartWidth = m_LeftTreeWidthConstraint.constant;
}

- (void)resizeDirectoryTreeBy:(CGFloat)_delta_x
{
    [self setDirectoryTreeWidth:m_TreeDragStartWidth + _delta_x commit:NO];
}

- (void)commitDirectoryTreeWidth
{
    [self setDirectoryTreeWidth:m_LeftTreeWidthConstraint.constant commit:YES];
}

- (void)resetDirectoryTreeWidth
{
    [self setDirectoryTreeWidth:kDirectoryTreeWidth commit:YES];
}

- (void)setDirectoryTreeWidth:(double)_width commit:(BOOL)_commit
{
    if( !m_ShowDirectoryTree )
        return;
    const double width = NCClampDirectoryTreeWidth(_width, self.bounds.size.width);
    m_LeftTreeWidthConstraint.constant = width;
    if( _commit )
        [NSUserDefaults.standardUserDefaults setDouble:width forKey:g_ConfigDirectoryTreeWidth];
}

// reflect m_ShowDirectoryTree in the layout. Width constants go to 0
// when hidden so the panels reclaim the space; heights are left untouched
// (see the v5.1 resize fix — never pin new views to the superview bottom).
- (void)applyDirectoryTreeVisibility
{
    m_LeftTreeWidthConstraint.constant = m_ShowDirectoryTree ? NCStoredDirectoryTreeWidth(self.bounds.size.width) : 0.0;
    m_TreeDividerWidthConstraint.constant = m_ShowDirectoryTree ? kTreeDividerHitWidth : 0.0;
    m_DirectoryTree.hidden = !m_ShowDirectoryTree;
    m_TreeDivider.hidden = !m_ShowDirectoryTree;
}

// A persisted width may be too wide for a window that shrank since last launch;
// re-clamp against the current size without overwriting the user's preference.
- (void)viewDidEndLiveResize
{
    [super viewDidEndLiveResize];
    if( m_ShowDirectoryTree )
        [self setDirectoryTreeWidth:m_LeftTreeWidthConstraint.constant commit:NO];
}

// toolbar action, travels through the first-responder chain.
- (IBAction)onToggleDirectoryTree:(id) [[maybe_unused]] _sender
{
    m_ShowDirectoryTree = !m_ShowDirectoryTree;
    [NSUserDefaults.standardUserDefaults setBool:m_ShowDirectoryTree forKey:@"nc.showDirectoryTree"];
    [self applyDirectoryTreeVisibility];
}

// 2.1.5: toolbar Command Palette button. showCommandPalette lives on this
// object (not on the responder chain), so the toolbar item targets it directly.
- (IBAction)onShowCommandPalette:(id) [[maybe_unused]] _sender
{
    [self showCommandPalette];
}

// bottom command line. v4 dropped the F-key row: the real TC/DC
// workflow is tree + tabs + hotkeys, not a cosmetic strip of buttons.
- (void)createFKeyBar
{
    const auto kHeight = kFKeyBarTotalHeight;
    m_FKeyBar = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, kHeight)];
    m_FKeyBar.translatesAutoresizingMaskIntoConstraints = NO;
    m_FKeyBar.wantsLayer = YES;
    m_FKeyBar.layer.backgroundColor = nc::CurrentTheme().FilePanelsGeneralOverlayColor().CGColor;
    [self addSubview:m_FKeyBar positioned:NSWindowAbove relativeTo:nil];

    // TC-style command line sitting above the F-key row.
    m_CommandLine = [[NSTextField alloc] initWithFrame:NSZeroRect];
    [self updateCommandLinePlaceholder];
    m_CommandLine.font = [NSFont systemFontOfSize:11.0];
    m_CommandLine.bezelStyle = NSTextFieldRoundedBezel;
    m_CommandLine.drawsBackground = YES;
    m_CommandLine.translatesAutoresizingMaskIntoConstraints = NO;
    m_CommandLine.target = self;
    m_CommandLine.action = @selector(onCommandLineSubmit:);
    m_CommandLine.delegate = self;
    [m_FKeyBar addSubview:m_CommandLine];
    [m_FKeyBar addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"|-(4)-[cmd]-(4)-|"
                                                                     options:0
                                                                     metrics:nil
                                                                       views:@{@"cmd": m_CommandLine}]];
    [m_FKeyBar addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|-(3)-[cmd(==23)]-(4)-|"
                                                                     options:0
                                                                     metrics:nil
                                                                       views:@{@"cmd": m_CommandLine}]];

    NSDictionary *barViews = @{@"bar": m_FKeyBar};
    [self addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"|-(0)-[bar]-(0)-|"
                                                                 options:0
                                                                 metrics:nil
                                                                   views:barViews]];
    [self addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:[bar(==30)]-(0)-|"
                                                                 options:0
                                                                 metrics:nil
                                                                   views:barViews]];
}

// 2.1.26: one short line instead of the old five-clause sentence, and nothing at
// all when the user turns the hint off in Preferences.
- (void)updateCommandLinePlaceholder
{
    static NSString *const hint = @"输入路径 ↵ 跳转 · ? 命令 · ! 终端 · > 常用";
    m_CommandLine.placeholderString = NCCommandLineHintVisible() ? hint : @"";
}

- (void)onFKeyBarButton:(NSButton *)sender
{
    if( NSMenuItem *item = [NSApp.mainMenu itemWithTagHierarchical:static_cast<NSInteger>(sender.tag)] )
        if( item.isEnabled )
            [NSApp sendAction:item.action to:item.target from:item];
}

// tree navigation semantics borrowed from XYplorer:
//   click                -> navigate the last-focused panel
//   Option-click         -> navigate the opposite panel, keep focus where it is
//   Shift+Option-click   -> open that path in a new tab of the opposite panel
// Resolves the panel a sidebar click should navigate:
//   plain                -> the last-focused panel
//   Option               -> the opposite panel, focus stays where it is
//   Shift+Option         -> a new tab of the opposite panel
// `_should_activate` tells the caller whether the click should return focus to the file list.
- (PanelController *)treeNavigationTargetForModifiers:(NSEventModifierFlags)modifiers
                                          activate:(BOOL *)should_activate
{
    const BOOL option_held = (modifiers & NSEventModifierFlagOption) != 0;
    const BOOL shift_held = (modifiers & NSEventModifierFlagShift) != 0;

    // The tree itself owns firstResponder, so activePanelController is nil here.
    PanelController *focused = m_LastFocusedPanelController ?: self.leftPanelController;
    if( focused == nil )
        return nil;
    const BOOL focus_is_left = [self isLeftController:focused];

    PanelController *target = focused;
    if( option_held ) {
        target = focus_is_left ? self.rightPanelController : self.leftPanelController;
        if( shift_held ) {
            NSTabView *tab_view = focus_is_left ? m_SplitView.rightTabbedHolder.tabView
                                                : m_SplitView.leftTabbedHolder.tabView;
            target = [self spawnNewTabInTabView:tab_view autoDirectoryLoading:NO activateNewPanel:YES];
        }
    }
    if( target == nil )
        return nil;

    [self revealPanel:target];
    if( should_activate )
        *should_activate = !option_held;
    return target;
}

- (void)directoryTreeDidSelectPath:(NSString *)path modifiers:(NSEventModifierFlags)modifiers
{
    if( path.length == 0 || NCSidebarLinkMode() == kSidebarLinkModeNone )
        return;
    BOOL should_activate = NO;
    PanelController *const target = [self treeNavigationTargetForModifiers:modifiers activate:&should_activate];
    if( target == nil )
        return;

    auto request = std::make_shared<DirectoryChangeRequest>();
    request->RequestedDirectory = path.UTF8String;
    request->VFS = nc::bootstrap::NativeVFSHostInstance().SharedPtr();
    request->PerformAsynchronous = true;
    request->InitiatedByUser = true;
    [target GoToDirWithContext:request];

    // A plain click behaves like TC: focus goes back to the file list so
    // F3/F5/... keep acting on the panel we just navigated.
    if( should_activate )
        [self ActivatePanelByController:target];
}

// Favorites and recent folders may live on a non-native VFS (network share, archive),
// so they are restored through the very same machinery the Favorites menu uses.
- (void)directoryTreeDidSelectLocation:(AnyHolder *)location modifiers:(NSEventModifierFlags)modifiers
{
    if( location == nil || NCSidebarLinkMode() == kSidebarLinkModeNone )
        return;
    const auto persistent = std::any_cast<PersistentLocation>(&location.any);
    if( persistent == nullptr )
        return;

    BOOL should_activate = NO;
    PanelController *const target = [self treeNavigationTargetForModifiers:modifiers activate:&should_activate];
    if( target == nil )
        return;

    nc::panel::actions::AsyncPersistentLocationRestorer restorer(
        target, target.vfsInstanceManager, *NCAppDelegate.me.networkConnectionsManager);
    __weak PanelController *weak_target = target;
    const std::string path = persistent->path;
    restorer.Restore(
        *persistent,
        [weak_target, path](VFSHostPtr _host) {
            dispatch_to_main_queue([weak_target, path, _host] {
                PanelController *const panel = weak_target;
                if( panel == nil )
                    return;
                auto request = std::make_shared<DirectoryChangeRequest>();
                request->RequestedDirectory = path;
                request->VFS = _host;
                request->PerformAsynchronous = true;
                request->InitiatedByUser = true;
                [panel GoToDirWithContext:request];
            });
        },
        nullptr);

    if( should_activate )
        [self ActivatePanelByController:target];
}

- (void)onCommandLineSubmit:(NSTextField *)sender
{
    const auto raw = [sender.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if( raw.length == 0 )
        return;

    const std::string input = raw.UTF8String;
    m_CommandHistory.emplace_back(input);
    m_CommandHistoryPos = m_CommandHistory.size();
    sender.stringValue = @"";
    [self.window makeFirstResponder:m_LastFocusedPanelController ? m_LastFocusedPanelController.view : nil];

    if( input == "?" || input == "？" ) {
        [self showCommandPalette];
        return;
    }
    if( input == ">" || input == "》" ) {
        [self showFrecencyJump];
        return;
    }
    if( input.front() == '!' ) {
        auto command = input.substr(1);
        while( !command.empty() && (command.front() == ' ' || command.front() == '\t') )
            command.erase(command.begin());
        if( !command.empty() )
            [self executeCommandLineInTerminal:command];
        return;
    }

    // The command line owns the first responder while typing, so
    // activePanelController would be nil here. Use the last focused panel.
    PanelController *panel = m_LastFocusedPanelController;
    if( panel == nil )
        panel = self.leftPanelController;
    if( panel == nil )
        return;
    const auto request = std::make_shared<DirectoryChangeRequest>();
    request->RequestedDirectory = [panel expandPath:input];
    request->VFS = nc::bootstrap::NativeVFSHostInstance().SharedPtr();
    request->PerformAsynchronous = true;
    request->InitiatedByUser = true;
    [panel GoToDirWithContext:request];
    // Hand focus back so F3/F5/... keep acting on the panel, just like TC.
    dispatch_async(dispatch_get_main_queue(), ^{ [self.window makeFirstResponder:panel.view]; });
}

// Runs a "!command" in the existing overlapped terminal so its output stays
// visible, the same way Total Commander's command line hands off to the shell.
- (void)executeCommandLineInTerminal:(const std::string &)_command
{
    if( m_OverlappedTerminal->terminal == nullptr )
        return;
    if( ![self overlappedTerminalVisible] )
        [self activateOverlappedTerminal];
    // activateOverlappedTerminal reads activePanelController for its cwd, which
    // is nil while the command line has focus - set the panel cwd explicitly.
    if( PanelController *panel = m_LastFocusedPanelController )
        [m_OverlappedTerminal->terminal changeWorkingDirectory:panel.currentDirectoryPath];

    const auto feed = [self, command = _command] {
        if( m_OverlappedTerminal->terminal.state == nc::term::ShellTask::TaskState::Shell ) {
            [m_OverlappedTerminal->terminal feedShellWithInput:command];
            [m_OverlappedTerminal->terminal commitShell];
        }
    };
    feed();
    if( m_OverlappedTerminal->terminal.state != nc::term::ShellTask::TaskState::Shell ) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(0.4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), feed);
    }
}

// VSCode/TC-style command palette. Summoned by typing "?" in the
// command line. Reuses NCCommandPopover and the real menu items so that every
// action, title, shortcut and enablement stays in sync with the app itself.
- (void)showCommandPalette
{
    if( m_CommandPalette ) {
        [m_CommandPalette close];
        return;
    }

    NCCommandPopover *const palette = [[NCCommandPopover alloc] initWithTitle:@"Command palette — type to filter"];
    palette.delegate = self;
    palette.fuzzyFiltering = true; // subsequence match, like VSCode/Marta
    // 2.1.7: spread the many menu commands over a multi-column grid instead of
    // one long strip. The popover clamps this by the screen width and item count.
    palette.columns = 3;

    struct Section {
        const char *prefix;
        const char *title;
    };
    static const Section sections[] = {
        {"menu.file.",     "File"},
        {"menu.edit.",     "Edit"},
        {"menu.view.",     "View"},
        {"menu.go.",       "Go"},
        {"menu.command.",  "Command"},
        {"menu.window.",   "Window"},
        {"menu.nimble_commander.", "Application"},
    };
    static const size_t section_count = sizeof(sections) / sizeof(sections[0]);
    const auto action_count = sizeof(nc::bootstrap::g_ActionsTags) / sizeof(nc::bootstrap::g_ActionsTags[0]);

    // One pass per section keeps the list grouped like the real menus.
    for( size_t s = 0; s < section_count; ++s ) {
        bool header_added = false;
        for( size_t i = 0; i < action_count; ++i ) {
            const auto &action = nc::bootstrap::g_ActionsTags[i];
            if( strncmp(action.first, sections[s].prefix, strlen(sections[s].prefix)) != 0 )
                continue;
            NSMenuItem *const menu_item = [NSApp.mainMenu itemWithTagHierarchical:action.second];
            if( menu_item == nil || menu_item.hidden || menu_item.isSeparatorItem || menu_item.submenu != nil ||
                menu_item.action == nil || menu_item.title.length == 0 )
                continue;
            if( !header_added ) {
                [palette addItem:[NCCommandPopoverItem sectionHeaderWithTitle:@(sections[s].title)]];
                header_added = true;
            }
            NCCommandPopoverItem *const item = [NCCommandPopoverItem new];
            item.title = menu_item.title;
            NSString *const key = menu_item.keyEquivalent.length ? menu_item.keyEquivalent : @"";
            item.toolTip = [NSString stringWithFormat:@"%@  ·  %s", key, action.first];
            item.image = menu_item.image;
            item.target = self;
            item.action = @selector(onCommandPaletteItemSelected:);
            item.representedObject = menu_item;
            [palette addItem:item];
        }
    }

    m_CommandPalette = palette;
    // 2.1.6: pin the palette to the TOP of the content area (just under the
    // toolbar), so it drops down aligned with the app window like VSCode's
    // command palette — instead of floating in the middle/lower part.
    const NSRect anchor = NSMakeRect(NSMidX(self.bounds), NSMaxY(self.bounds) - 1.0, 1, 1);
    [palette showRelativeToRect:anchor ofView:self alignment:NCCommandPopoverAlignment::Center];
}

// zoxide-style smart jump: summoned by typing ">" in the command line.
// Lists NC's built-in frecent locations (frequency + recency over 14 days)
// so a frequently used directory is one keystroke away. Reuses the same
// NCCommandPopover UI as the command palette; tag 100 marks a jump item.
- (void)showFrecencyJump
{
    if( m_CommandPalette ) {
        [m_CommandPalette close];
        return;
    }

    NCCommandPopover *const palette =
        [[NCCommandPopover alloc] initWithTitle:@"Frequent locations — type to filter"];
    palette.delegate = self;
    // 2.1.7: paths are wide, so ask for 2 columns; the popover clamps by screen.
    palette.columns = 2;

    const auto frequent = NCAppDelegate.me.favoriteLocationsStorage->FrecentlyUsed(30);
    bool header_added = false;
    for( const auto &location : frequent ) {
        const auto &hosts_stack = location->hosts_stack;
        if( !hosts_stack.is_native() || hosts_stack.path.empty() )
            continue; // only plain local paths in this version; VFS/network handled by the native GoTo list
        if( !header_added ) {
            [palette addItem:[NCCommandPopoverItem sectionHeaderWithTitle:@"Frequently visited"]];
            header_added = true;
        }
        NCCommandPopoverItem *const item = [NCCommandPopoverItem new];
        item.title = [NSString stringWithUTF8String:location->verbose_path.c_str()];
        item.toolTip = [NSString stringWithUTF8String:hosts_stack.path.c_str()];
        item.tag = 100; // frecency jump marker
        item.target = self;
        item.action = @selector(onCommandPaletteItemSelected:);
        item.representedObject = [NSString stringWithUTF8String:hosts_stack.path.c_str()];
        [palette addItem:item];
    }

    if( !header_added ) {
        // Nothing visited recently - show a single hint row.
        NCCommandPopoverItem *const hint = [NCCommandPopoverItem new];
        hint.title = @"No frequently visited locations yet";
        [palette addItem:hint];
    }

    m_CommandPalette = palette;
    // 2.1.6: same top-aligned placement as the command palette.
    const NSRect anchor = NSMakeRect(NSMidX(self.bounds), NSMaxY(self.bounds) - 1.0, 1, 1);
    [palette showRelativeToRect:anchor ofView:self alignment:NCCommandPopoverAlignment::Center];
}

- (void)onCommandPaletteItemSelected:(NCCommandPopoverItem *)sender
{
    [m_CommandPalette close];
    if( sender.tag == 100 ) {
        // Frecency jump: representedObject is the native directory path.
        NSString *const path = nc::objc_cast<NSString>(sender.representedObject);
        if( path.length == 0 )
            return;
        PanelController *panel = m_LastFocusedPanelController ? m_LastFocusedPanelController : self.leftPanelController;
        if( panel == nil )
            return;
        const auto request = std::make_shared<DirectoryChangeRequest>();
        request->RequestedDirectory = [panel expandPath:path.UTF8String];
        request->VFS = nc::bootstrap::NativeVFSHostInstance().SharedPtr();
        request->PerformAsynchronous = true;
        request->InitiatedByUser = true;
        [panel GoToDirWithContext:request];
        dispatch_async(dispatch_get_main_queue(), ^{ [self.window makeFirstResponder:panel.view]; });
        return;
    }
    NSMenuItem *const menu_item = nc::objc_cast<NSMenuItem>(sender.representedObject);
    if( menu_item != nil )
        [NSApp sendAction:menu_item.action to:menu_item.target from:menu_item];
}

- (void)commandPopoverDidClose:(NCCommandPopover *)_popover
{
    (void)_popover;
    m_CommandPalette = nil;
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)commandSelector
{
    (void)textView;
    if( commandSelector == @selector(moveUp:) ) {
        if( !m_CommandHistory.empty() && m_CommandHistoryPos > 0 ) {
            --m_CommandHistoryPos;
            control.stringValue = [NSString stringWithUTF8String:m_CommandHistory[m_CommandHistoryPos].c_str()];
        }
        return YES;
    }
    if( commandSelector == @selector(moveDown:) ) {
        if( m_CommandHistoryPos < m_CommandHistory.size() ) {
            ++m_CommandHistoryPos;
            control.stringValue = m_CommandHistoryPos == m_CommandHistory.size()
                                      ? @""
                                      : [NSString stringWithUTF8String:m_CommandHistory[m_CommandHistoryPos].c_str()];
        }
        return YES;
    }
    return NO;
}

- (void)windowStateDidBecomeAssigned
{
    NSLayoutConstraint *c = [NSLayoutConstraint constraintWithItem:m_SeparatorLine
                                                         attribute:NSLayoutAttributeTop
                                                         relatedBy:NSLayoutRelationEqual
                                                            toItem:self.window.contentLayoutGuide
                                                         attribute:NSLayoutAttributeTop
                                                        multiplier:1
                                                          constant:0];
    c.active = true;

    if( m_LastResponder ) {
        // if we already were active and have some focused view - restore it
        [self.window makeFirstResponder:m_LastResponder];
        m_LastResponder = nil;
    }
    else {
        // if we don't know which view should be active - make left panel a first responder
        [self.window makeFirstResponder:m_SplitView.leftTabbedHolder.current];
    }

    [self updateTitle];
}

- (void)layout
{
    [super layout];
    if( m_OverlappedTerminal->terminal ) {
        [m_OverlappedTerminal->terminal layout];
        [self updateBottomConstraint];
        [super layout];
    }
}

- (void)viewWillMoveToWindow:(NSWindow *)_wnd
{
    if( _wnd == nil ) {
        m_LastResponder = nil;
        if( auto resp = nc::objc_cast<NSView>(self.window.firstResponder) )
            if( [resp isDescendantOf:self] )
                m_LastResponder = resp;
    }
}

- (bool)isPanelActive
{
    return self.activePanelController != nil;
}

- (PanelView *)activePanelView
{
    PanelController *pc = self.activePanelController;
    return pc ? pc.view : nil;
}

- (const data::Model *)activePanelData
{
    PanelController *pc = self.activePanelController;
    return pc ? &pc.data : nullptr;
}

- (PanelController *)activePanelController
{
    if( NSResponder *r = self.window.firstResponder ) {
        for( auto &pc : m_LeftPanelControllers )
            if( r == pc.view )
                return pc;
        for( auto &pc : m_RightPanelControllers )
            if( r == pc.view )
                return pc;
    }
    return nil;
}

- (PanelController *)oppositePanelController
{
    PanelController *act = self.activePanelController;
    if( !act )
        return nil;
    if( act == self.leftPanelController )
        return self.rightPanelController;
    return self.leftPanelController;
}

- (const data::Model *)oppositePanelData
{
    PanelController *pc = self.oppositePanelController;
    return pc ? &pc.data : nullptr;
}

- (PanelView *)oppositePanelView
{
    PanelController *pc = self.oppositePanelController;
    return pc ? pc.view : nil;
}

- (PanelController *)leftPanelController
{
    return nc::objc_cast<PanelController>(m_SplitView.leftTabbedHolder.current.delegate);
}

- (PanelController *)rightPanelController
{
    return nc::objc_cast<PanelController>(m_SplitView.rightTabbedHolder.current.delegate);
}

- (const std::vector<PanelController *> &)leftControllers
{
    return m_LeftPanelControllers;
}

- (const std::vector<PanelController *> &)rightControllers
{
    return m_RightPanelControllers;
}

static bool Has(std::span<PanelController *> _c, PanelController *_p) noexcept
{
    // this is called very often, so in order to help optimizer I manually removed all
    // Objective-C / ARC related semantics by casting everything to raw void*.
    // the difference between assembly outputs is huge.
    // NOLINTBEGIN(bugprone-bitwise-pointer-cast)
    const void *const *first = std::bit_cast<const void *const *>(_c.data());
    // NOLINTEND(bugprone-bitwise-pointer-cast)
    const void *const *last = first + _c.size();
    const void *value = (__bridge const void *)_p;
    return std::find(first, last, value) != last;
}

- (bool)isLeftController:(PanelController *)_controller
{
    return Has(m_LeftPanelControllers, _controller);
}

- (bool)isRightController:(PanelController *)_controller
{
    return Has(m_RightPanelControllers, _controller);
}

- (void)changeFocusedSide
{
    if( m_SplitView.anyCollapsedOrOverlayed )
        return;
    if( auto cur = self.activePanelController ) {
        if( [self isLeftController:cur] )
            [self.window makeFirstResponder:m_SplitView.rightTabbedHolder.current];
        else
            [self.window makeFirstResponder:m_SplitView.leftTabbedHolder.current];
    }
}

- (void)ActivatePanelByController:(PanelController *)controller
{
    if( [self isLeftController:controller] ) {
        if( m_SplitView.leftTabbedHolder.current == controller.view ) {
            [self.window makeFirstResponder:m_SplitView.leftTabbedHolder.current];
            return;
        }
        for( NSTabViewItem *it in m_SplitView.leftTabbedHolder.tabView.tabViewItems )
            if( it.view == controller.view ) {
                [m_SplitView.leftTabbedHolder.tabView selectTabViewItem:it];
                [self.window makeFirstResponder:controller.view];
                return;
            }
    }
    else if( [self isRightController:controller] ) {
        if( m_SplitView.rightTabbedHolder.current == controller.view ) {
            [self.window makeFirstResponder:m_SplitView.rightTabbedHolder.current];
            return;
        }
        for( NSTabViewItem *it in m_SplitView.rightTabbedHolder.tabView.tabViewItems )
            if( it.view == controller.view ) {
                [m_SplitView.rightTabbedHolder.tabView selectTabViewItem:it];
                [self.window makeFirstResponder:controller.view];
                return;
            }
    }
}

- (void)activePanelChangedTo:(PanelController *)controller
{
    [self updateTitle];
    m_LastFocusedPanelController = controller;
    [self synchronizeOverlappedTerminalWithPanel:controller];
    [self markRestorableStateAsInvalid];
}

- (void)updateTitle
{
    self.window.title = TrimmedTitleForWindow(TitleForData(self.activePanelData), self.window);
}

static nc::config::Value EncodePanelsStates(const std::vector<PanelController *> &_left,
                                            const std::vector<PanelController *> &_right)
{
    using namespace rapidjson;
    nc::config::Value json{kArrayType};
    nc::config::Value left{kArrayType};
    nc::config::Value right{kArrayType};

    const auto encoding_opts = ControllerStateEncoding::EncodeEverything;
    PanelDataPersistency persistency(*NCAppDelegate.me.networkConnectionsManager); // TODO: evil, fix

    // NOLINTBEGIN(misc-const-correctness)

    for( PanelController *pc : _left )
        if( auto v = ControllerStateJSONEncoder{pc, persistency}.Encode(encoding_opts); v.GetType() != kNullType )
            left.PushBack(std::move(v), nc::config::g_CrtAllocator);

    for( PanelController *pc : _right )
        if( auto v = ControllerStateJSONEncoder{pc, persistency}.Encode(encoding_opts); v.GetType() != kNullType )
            right.PushBack(std::move(v), nc::config::g_CrtAllocator);

    // NOLINTEND(misc-const-correctness)

    json.PushBack(std::move(left), nc::config::g_CrtAllocator);
    json.PushBack(std::move(right), nc::config::g_CrtAllocator);

    return json;
}

static nc::config::Value EncodeUIState(MainWindowFilePanelState *_state)
{
    using namespace rapidjson;
    using namespace nc::config;
    nc::config::Value ui{kObjectType};

    ui.AddMember(MakeStandaloneString(g_ResorationUISelectedLeftTab),
                 nc::config::Value(_state.leftTabbedHolder.selectedIndex),
                 g_CrtAllocator);

    ui.AddMember(MakeStandaloneString(g_ResorationUISelectedRightTab),
                 nc::config::Value(_state.rightTabbedHolder.selectedIndex),
                 g_CrtAllocator);

    const auto right_side_selected = [_state isRightController:_state.activePanelController];
    ui.AddMember(MakeStandaloneString(g_ResorationUIFocusedSide),
                 MakeStandaloneString(right_side_selected ? "right" : "left"),
                 g_CrtAllocator);

    return ui;
}

- (nc::config::Value)encodeRestorableState
{
    using namespace rapidjson;
    nc::config::Value json{kObjectType};

    json.AddMember(nc::config::MakeStandaloneString(g_ResorationPanelsKey),
                   EncodePanelsStates(m_LeftPanelControllers, m_RightPanelControllers),
                   nc::config::g_CrtAllocator);
    json.AddMember(
        nc::config::MakeStandaloneString(g_ResorationUIKey), EncodeUIState(self), nc::config::g_CrtAllocator);

    return json;
}

- (bool)decodeRestorableState:(const nc::config::Value &)_state
{
    using namespace nc::config;

    if( !_state.IsObject() )
        return false;

    // Directory listings are loaded in streaming chunks, and even the
    // "synchronous" path applies the patched listing via dispatch_async to the main queue.
    // Therefore data.IsLoaded() is still false right after Decode() below. The old success
    // check made restoreDefaultWindowStateFromConfig believe restoration had failed and call
    // loadDefaultPanelContent, which navigated both first panels back to the home directory
    // and wiped the restored paths. Track whether we actually decoded saved panels instead.
    bool did_restore_saved_panels = false;

    if( _state.HasMember(g_ResorationPanelsKey) ) {
        const auto &json_panels = _state[g_ResorationPanelsKey];
        if( json_panels.IsArray() && json_panels.Size() == 2 ) {
            const auto &left = json_panels[0];
            if( left.IsArray() && left.Size() > 0 )
                did_restore_saved_panels = true;
            if( left.IsArray() )
                for( auto i = left.Begin(), e = left.End(); i != e; ++i ) {
                    if( i != left.Begin() ) {
                        auto pc = m_PanelFactory();
                        [self attachPanel:pc];
                        [self addNewControllerOnLeftPane:pc];
                        m_ControllerStateJSONDecoder->Decode(*i, pc);
                    }
                    else
                        m_ControllerStateJSONDecoder->Decode(*i, m_LeftPanelControllers.front());
                }

            const auto &right = json_panels[1];
            if( right.IsArray() && right.Size() > 0 )
                did_restore_saved_panels = true;
            if( right.IsArray() )
                for( auto i = right.Begin(), e = right.End(); i != e; ++i ) {
                    if( i != right.Begin() ) {
                        auto pc = m_PanelFactory();
                        [self attachPanel:pc];
                        [self addNewControllerOnRightPane:pc];
                        m_ControllerStateJSONDecoder->Decode(*i, pc);
                    }
                    else
                        m_ControllerStateJSONDecoder->Decode(*i, m_RightPanelControllers.front());
                }
        }
    }
    if( _state.HasMember(g_ResorationUIKey) ) {
        const auto &json_ui = _state[g_ResorationUIKey];
        if( json_ui.IsObject() ) {
            // invalid indeces are ok here, they will be discarded by FilePanelsTabbedHolder
            if( auto sel_left = GetOptionalIntFromObject(json_ui, g_ResorationUISelectedLeftTab) )
                [self.leftTabbedHolder selectTabAtIndex:*sel_left];
            if( auto sel_right = GetOptionalIntFromObject(json_ui, g_ResorationUISelectedRightTab) )
                [self.rightTabbedHolder selectTabAtIndex:*sel_right];
            if( auto side = GetOptionalStringFromObject(json_ui, g_ResorationUIFocusedSide) ) {
                const auto focus = [&]() -> PanelController * {
                    if( *side == "right"s )
                        return self.rightPanelController;
                    else if( *side == "left"s )
                        return self.leftPanelController;
                    return nil;
                }();
                if( focus ) {
                    // if we're already assigned to window - set first responder
                    if( self.window )
                        [self ActivatePanelByController:focus];
                    // if not - memorize it, will set on Assigned
                    else
                        m_LastResponder = focus.view;
                }
            }
        }
    }

    [self applyConfiguredLayoutToPanels]; // default layout preference overrides saved layout

    // if we decoded saved panels, consider restoration successful even though
    // the streamed listing has not landed in the model yet. Only fall back to default content
    // when there was no usable saved panel state at all.
    if( did_restore_saved_panels )
        return true;

    return (m_LeftPanelControllers.front().data.IsLoaded() ||
            m_LeftPanelControllers.front().isDoingBackgroundLoading) &&
           (m_RightPanelControllers.front().data.IsLoaded() ||
            m_RightPanelControllers.front().isDoingBackgroundLoading);
}

// MARK: workspaces

// A pane must keep one tab, and a workspace replaces the whole layout instead of
// stacking on top of it - hence the trim before decoding the stored state.
- (void)trimTabsToSingleTabOnSide:(BOOL)_left
{
    FilePanelsTabbedHolder *const holder = _left ? m_SplitView.leftTabbedHolder : m_SplitView.rightTabbedHolder;
    NSTabView *const tab_view = holder.tabView;
    NSArray<NSTabViewItem *> *const items = tab_view.tabViewItems;
    for( NSUInteger i = items.count; i > 1; --i ) {
        NSTabViewItem *const item = items[i - 1];
        [tab_view removeTabViewItem:item];
        // same cleanup the tab bar's close button performs
        [self tabView:tab_view didCloseTabViewItem:item];
    }
}

- (void)applyWorkspaceAtIndex:(NSInteger)_index
{
    const auto stored = GlobalConfig().Get(g_ConfigWorkspaces);
    if( !stored.IsArray() || _index < 0 || _index >= static_cast<NSInteger>(stored.Size()) )
        return;
    const auto &entry = stored[static_cast<rapidjson::SizeType>(_index)];
    if( !entry.IsObject() || !entry.HasMember("state") )
        return;

    [self trimTabsToSingleTabOnSide:YES];
    [self trimTabsToSingleTabOnSide:NO];
    [self decodeRestorableState:entry["state"]];
    [self updateTabBarsVisibility];

    if( self.window && entry.HasMember("frame") && entry["frame"].IsString() ) {
        const NSRect frame = NSRectFromString([NSString stringWithUTF8StdString:entry["frame"].GetString()]);
        if( frame.size.width > 100 && frame.size.height > 100 )
            [self.window setFrame:frame display:YES];
    }
}

- (void)saveCurrentLayoutAsWorkspaceNamed:(NSString *)_name
{
    NSString *const name = [_name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if( name.length == 0 )
        return;

    using namespace rapidjson;
    auto &allocator = nc::config::g_CrtAllocator;

    nc::config::Value updated{kArrayType};
    const auto stored = GlobalConfig().Get(g_ConfigWorkspaces);
    if( stored.IsArray() ) {
        for( const auto &existing : stored.GetArray() ) {
            // saving under an existing name replaces that workspace
            if( existing.IsObject() && existing.HasMember("name") && existing["name"].IsString() &&
                std::string_view(existing["name"].GetString()) == std::string_view(name.UTF8String) )
                continue;
            updated.PushBack(nc::config::Value(existing, allocator), allocator);
        }
    }

    nc::config::Value entry{kObjectType};
    entry.AddMember(nc::config::MakeStandaloneString("name"),
                    nc::config::MakeStandaloneString(name.UTF8String),
                    allocator);
    if( self.window )
        entry.AddMember(nc::config::MakeStandaloneString("frame"),
                        nc::config::MakeStandaloneString(NSStringFromRect(self.window.frame).UTF8String),
                        allocator);
    entry.AddMember(nc::config::MakeStandaloneString("state"), [self encodeRestorableState], allocator);
    updated.PushBack(std::move(entry), allocator);

    GlobalConfig().Set(g_ConfigWorkspaces, updated);
    [m_DirectoryTree rebuildSections];
}

- (void)deleteWorkspaceAtIndex:(NSInteger)_index
{
    const auto stored = GlobalConfig().Get(g_ConfigWorkspaces);
    if( !stored.IsArray() )
        return;

    nc::config::Value updated{rapidjson::kArrayType};
    NSInteger position = 0;
    for( const auto &existing : stored.GetArray() ) {
        if( position++ != _index )
            updated.PushBack(nc::config::Value(existing, nc::config::g_CrtAllocator), nc::config::g_CrtAllocator);
    }
    GlobalConfig().Set(g_ConfigWorkspaces, updated);
    [m_DirectoryTree rebuildSections];
}

- (NSString *)workspaceNameAtIndex:(NSInteger)_index
{
    const auto stored = GlobalConfig().Get(g_ConfigWorkspaces);
    if( !stored.IsArray() || _index < 0 || _index >= static_cast<NSInteger>(stored.Size()) )
        return nil;
    const auto &entry = stored[static_cast<rapidjson::SizeType>(_index)];
    if( !entry.IsObject() || !entry.HasMember("name") || !entry["name"].IsString() )
        return nil;
    return [NSString stringWithUTF8StdString:entry["name"].GetString()];
}

- (void)promptToSaveWorkspace
{
    NSAlert *const alert = [[NSAlert alloc] init];
    alert.messageText = NSLocalizedString(@"Save Workspace", "Alert title for saving a workspace");
    alert.informativeText =
        NSLocalizedString(@"The current tabs, folders and window size will be stored under this name.",
                          "Alert body for saving a workspace");
    [alert addButtonWithTitle:NSLocalizedString(@"Save", "User action to save")];
    [alert addButtonWithTitle:NSLocalizedString(@"Cancel", "")];

    NSTextField *const field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 280, 24)];
    field.stringValue = NSLocalizedString(@"New Workspace", "Default name of a new workspace");
    alert.accessoryView = field;

    __weak MainWindowFilePanelState *weak_self = self;
    void (^handler)(NSModalResponse) = ^(NSModalResponse _response) {
        if( _response != NSAlertFirstButtonReturn )
            return;
        MainWindowFilePanelState *const state = weak_self;
        if( state == nil )
            return;
        [state saveCurrentLayoutAsWorkspaceNamed:field.stringValue];
    };

    NSWindow *const window = self.window;
    if( window ) {
        [alert beginSheetModalForWindow:window completionHandler:handler];
        alert.window.initialFirstResponder = field;
    }
    else {
        handler([alert runModal]);
    }
}

- (void)directoryTreeDidApplyWorkspaceAtIndex:(NSInteger)_index
{
    [self applyWorkspaceAtIndex:_index];
}

- (void)directoryTreeDidRequestSaveWorkspace
{
    [self promptToSaveWorkspace];
}

- (void)directoryTreeDidRequestOverwriteWorkspaceAtIndex:(NSInteger)_index
{
    NSString *const name = [self workspaceNameAtIndex:_index];
    if( name.length )
        [self saveCurrentLayoutAsWorkspaceNamed:name];
}

- (void)directoryTreeDidRequestDeleteWorkspaceAtIndex:(NSInteger)_index
{
    [self deleteWorkspaceAtIndex:_index];
}

- (void)markRestorableStateAsInvalid
{
    if( auto wc = nc::objc_cast<NCMainWindowController>(self.window.delegate) )
        [wc invalidateRestorableState];
}

- (void)saveDefaultInitialState
{
    const auto left_panel = self.leftPanelController;
    if( !left_panel )
        return;

    const auto right_panel = self.rightPanelController;
    if( !right_panel )
        return;

    const auto to_encode = static_cast<ControllerStateEncoding::Options>(ControllerStateEncoding::EncodeDataOptions |
                                                                         ControllerStateEncoding::EncodeViewOptions);

    PanelDataPersistency persistency(*NCAppDelegate.me.networkConnectionsManager); // TODO: evil, fix

    auto left_panel_options = ControllerStateJSONEncoder{left_panel, persistency}.Encode(to_encode);
    if( left_panel_options.GetType() == rapidjson::kNullType )
        return;

    auto right_panel_options = ControllerStateJSONEncoder{right_panel, persistency}.Encode(to_encode);
    if( right_panel_options.GetType() == rapidjson::kNullType )
        return;

    using namespace rapidjson;
    using namespace nc::config;
    nc::config::Value json{kObjectType};
    json.AddMember(MakeStandaloneString(g_InitialStateLeftDefaults), std::move(left_panel_options), g_CrtAllocator);
    json.AddMember(MakeStandaloneString(g_InitialStateRightDefaults), std::move(right_panel_options), g_CrtAllocator);

    StateConfig().Set(g_InitialStatePath, json);
}

- (void)PanelPathChanged:(PanelController *)_panel
{
    if( _panel == nil )
        return;

    if( _panel == self.activePanelController ) {
        [self updateTitle];
        [self synchronizeOverlappedTerminalWithPanel:_panel];
    }

    [self updateTabNameForController:_panel];

    if( _panel.isUniform ) {
        if( m_FavoriteLocationsStorage )
            m_FavoriteLocationsStorage->ReportLocationVisit(*_panel.vfs, _panel.currentDirectoryPath);
        // 2.1.21: panel -> tree highlighting is opt-in (bidirectional mode only).
        // The default stays tree -> panel, which is what the user wants.
        if( _panel == m_LastFocusedPanelController && NCSidebarLinkMode() == kSidebarLinkModeBoth )
            [m_DirectoryTree revealPath:@(_panel.currentDirectoryPath.c_str())];
    }
}

- (void)viewDidMoveToWindow
{
    if( self.window ) {
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(windowDidResize)
                                                   name:NSWindowDidResizeNotification
                                                 object:self.window];
    }
    else {
        [NSNotificationCenter.defaultCenter removeObserver:self name:NSWindowDidResizeNotification object:nil];
    }
}

- (void)windowDidResize
{
    [self updateTitle];
}

- (void)windowStateWillClose
{
    [self saveOverlappedTerminalSettings];

    for( auto pc : m_LeftPanelControllers )
        [self panelWillBeClosed:pc];
    for( auto pc : m_RightPanelControllers )
        [self panelWillBeClosed:pc];
}

static void AskAboutStoppingRunningOperations(NSWindow *_window, std::function<void(NSModalResponse)> _handler)
{
    assert(_window && _handler);
    Alert *const dialog = [[Alert alloc] init];
    [dialog addButtonWithTitle:NSLocalizedString(@"Stop and Close",
                                                 "User action to stop running actions and close window")];
    [dialog addButtonWithTitle:NSLocalizedString(@"Cancel", "")];
    dialog.messageText =
        NSLocalizedString(@"The window has running operations. Do you want to stop them and close the window?",
                          "Asking user to close window with some operations running");
    [dialog beginSheetModalForWindow:_window
                   completionHandler:^(NSModalResponse result) {
                     _handler(result);
                   }];
}

- (bool)windowStateShouldClose:(NCMainWindowController *) [[maybe_unused]] _sender
{
    const auto ops_pool_nonempty = !self.operationsPool.Empty();
    const auto overlapped_term_busy = self.isAnythingRunningInOverlappedTerminal;
    if( ops_pool_nonempty || overlapped_term_busy ) {
        auto ops_stop_callback = [=](NSModalResponse result) {
            if( result != NSAlertFirstButtonReturn )
                return;
            dispatch_to_main_queue([=] {
                self.operationsPool.StopAndWaitForShutdown();
                // reroute request again to trigger consequent checks
                [self.window performClose:nil];
            });
        };
        AskAboutStoppingRunningOperations(self.window, ops_stop_callback);
        return false;
    }

    return true;
}

- (std::vector<std::tuple<std::string, VFSHostPtr>>)filePanelsCurrentPaths
{
    std::vector<std::tuple<std::string, VFSHostPtr>> r;
    for( auto c : {&m_LeftPanelControllers, &m_RightPanelControllers} )
        for( auto p : *c )
            if( p.isUniform )
                r.emplace_back(p.currentDirectoryPath, p.vfs);
    return r;
}

- (id<NCPanelPreview>)quickLookForPanel:(PanelController *)_panel make:(bool)_make_if_absent
{
    if( ShowQuickLookAsFloatingPanel() ) {
        if( !_panel.isActive )
            return nil;

        if( QLPreviewPanel.sharedPreviewPanelExists && QLPreviewPanel.sharedPreviewPanel.isVisible ) {
            if( m_QLPanelAdaptor.owner == self )
                return m_QLPanelAdaptor;
        }

        if( !_make_if_absent )
            return nil;

        [QLPreviewPanel.sharedPreviewPanel makeKeyAndOrderFront:nil];
        return m_QLPanelAdaptor.owner == self ? m_QLPanelAdaptor : nil;
    }
    else {
        if( [self isLeftController:_panel] )
            if( const auto ql = nc::objc_cast<NCPanelQLOverlay>(m_SplitView.rightOverlay) )
                return ql;

        if( [self isRightController:_panel] )
            if( const auto ql = nc::objc_cast<NCPanelQLOverlay>(m_SplitView.leftOverlay) )
                return ql;

        if( _make_if_absent ) {
            if( m_SplitView.anyCollapsed )
                return nil;

            const auto rc = NSMakeRect(0, 0, 100, 100);
            const auto view = [[NCPanelQLOverlay alloc] initWithFrame:rc
                                                               bridge:m_QLPanelAdaptor.bridge
                                                               config:GlobalConfig()];

            if( [self isLeftController:_panel] )
                m_SplitView.rightOverlay = view;
            else if( [self isRightController:_panel] )
                m_SplitView.leftOverlay = view;
            else
                return nil;

            return view;
        }

        return nil;
    }
}

- (BriefSystemOverview *)briefSystemOverviewForPanel:(PanelController *)_panel make:(bool)_make_if_absent
{
    if( [self isLeftController:_panel] )
        if( const auto bso = nc::objc_cast<BriefSystemOverview>(m_SplitView.rightOverlay) )
            return bso;

    if( [self isRightController:_panel] )
        if( const auto bso = nc::objc_cast<BriefSystemOverview>(m_SplitView.leftOverlay) )
            return bso;

    if( _make_if_absent ) {
        if( m_SplitView.anyCollapsed )
            return nil;

        const auto rc = NSMakeRect(0, 0, 100, 100);
        const auto view = [[BriefSystemOverview alloc] initWithFrame:rc];

        if( [self isLeftController:_panel] )
            m_SplitView.rightOverlay = view;
        else if( [self isRightController:_panel] )
            m_SplitView.leftOverlay = view;
        else
            return nil;

        return view;
    }

    return nil;
}

- (void)closeAttachedUI:(PanelController *)_panel
{
    if( [self isLeftController:_panel] )
        m_SplitView.rightOverlay = nil;
    else if( [self isRightController:_panel] )
        m_SplitView.leftOverlay = nil;

    if( QLPreviewPanel.sharedPreviewPanelExists && QLPreviewPanel.sharedPreviewPanel.isVisible )
        [QLPreviewPanel.sharedPreviewPanel orderOut:nil];
}

- (void)onShowTabsSettingChanged
{
    bool show = GlobalConfig().GetBool(g_ConfigGeneralShowTabs);
    if( show != m_ShowTabs )
        dispatch_to_main_queue_after(1ms, [=] {
            m_ShowTabs = show;
            [self updateTabBarsVisibility];
        });
}

// 2.1.21: the sidebar options live in NSUserDefaults - refresh the tree right away
// when they change instead of waiting for the next navigation to rebuild it.
- (void)onUserDefaultsChanged
{
    // 2.1.25: only a changed recent-limit needs a rebuild. Rebuilding on every
    // defaults write meant our own expansion bookkeeping (and unrelated app settings)
    // kept re-applying the tree, which made collapsed nodes pop back open.
    if( g_WritingSidebarDefaults )
        return;
    // 2.1.26: the command-line hint switch takes effect immediately, no tree rebuild.
    [self updateCommandLinePlaceholder];
    // 2.1.28: the list-view polish switches only take effect on a reload - both panels are
    // cheap enough here and this only runs when one of the two values actually changed.
    const BOOL smart_dates = nc::panel::ListSmartDatesEnabled();
    const BOOL size_bars = nc::panel::ListSizeBarsEnabled();
    if( smart_dates != m_LastSmartDates || size_bars != m_LastSizeBars ) {
        m_LastSmartDates = smart_dates;
        m_LastSizeBars = size_bars;
        [self.leftPanelController refreshPanel];
        [self.rightPanelController refreshPanel];
    }
    const int recent_limit = NCSidebarRecentLimit();
    if( recent_limit == m_LastSidebarRecentLimit )
        return;
    m_LastSidebarRecentLimit = recent_limit;
    [m_DirectoryTree rebuildSections];
}

- (void)onThemeChanged
{
    m_SeparatorLine.borderColor = nc::CurrentTheme().FilePanelsGeneralTopSeparatorColor();
    static_cast<NCSidebarDividerView *>(m_TreeDivider).lineColor =
        nc::CurrentTheme().FilePanelsGeneralTopSeparatorColor();
    [self setNeedsDisplay:true];
}

- (void)updateBottomConstraint
{
    if( m_OverlappedTerminal->terminal == nullptr )
        return;

    const double gap = [m_OverlappedTerminal->terminal bottomGapForLines:m_OverlappedTerminal->bottom_gap] +
                       kFKeyBarTotalHeight; // keep the bottom bar visible below a terminal
    m_MainSplitViewBottomConstraint.constant = -gap;

    [self updateOverlappedTerminalVisibility];
}

- (bool)isPanelsSplitViewHidden
{
    return m_SplitView.hidden;
}

- (bool)anyPanelCollapsed
{
    return m_SplitView.anyCollapsed;
}

- (bool)bothPanelsAreVisible
{
    return !m_SplitView.hidden && !m_SplitView.anyCollapsedOrOverlayed;
}

- (void)requestTerminalExecution:(const std::string &)_filename at:(const std::string &)_cwd
{
    if( ![self executeInOverlappedTerminalIfPossible:_filename at:_cwd] ) {
        const auto ctrl = static_cast<NCMainWindowController *>(self.window.delegate);
        [ctrl requestTerminalExecution:_filename.c_str() at:_cwd.c_str()];
    }
}

- (void)addNewControllerOnLeftPane:(PanelController *)_pc
{
    _pc.layoutIndex = nc::panel::DefaultPanelLayout(); // new tabs honor the saved default view
    m_LeftPanelControllers.emplace_back(_pc);
    [m_SplitView.leftTabbedHolder addPanel:_pc.view];
}

- (void)addNewControllerOnRightPane:(PanelController *)_pc
{
    _pc.layoutIndex = nc::panel::DefaultPanelLayout(); // v7
    m_RightPanelControllers.emplace_back(_pc);
    [m_SplitView.rightTabbedHolder addPanel:_pc.view];
}

- (void)revealPanel:(PanelController *)panel
{
    if( [self isRightController:panel] ) {
        if( m_SplitView.isRightCollapsed )
            [m_SplitView expandRightView];
        m_SplitView.rightOverlay = nil; // may cause bad situations with weak pointers inside panel controller here
    }
    else if( [self isLeftController:panel] ) {

        if( m_SplitView.isLeftCollapsed )
            [m_SplitView expandLeftView];

        m_SplitView.leftOverlay = nil; // may cause bad situations with weak pointers inside panel controller here
    }
}

- (void)panelWillBeClosed:(PanelController *)_pc
{
    if( m_ClosedPanelsHistory ) {
        if( auto *listing_promise = _pc.history.MostRecent() )
            m_ClosedPanelsHistory->AddListing(*listing_promise);
    }
}

- (bool)goToForcesPanelActivation
{
    return GoToForcesPanelActivation();
}

- (nc::ops::Pool &)operationsPool
{
    return *m_OperationsPool;
}

- (NCMainWindowController *)mainWindowController
{
    return static_cast<NCMainWindowController *>(self.window.delegate);
}

- (void)swapPanels
{
    if( m_SplitView.anyCollapsedOrOverlayed )
        return;

    swap(m_LeftPanelControllers, m_RightPanelControllers);
    [m_SplitView swapViews];
    [self markRestorableStateAsInvalid];
}

- (BOOL)acceptsPreviewPanelControl:(QLPreviewPanel *) [[maybe_unused]] _panel
{
    return ShowQuickLookAsFloatingPanel();
}

- (void)beginPreviewPanelControl:(QLPreviewPanel *) [[maybe_unused]] _panel
{
    if( [m_QLPanelAdaptor registerExistingQLPreviewPanelFor:self] ) {
        if( auto pc = self.activePanelController )
            [pc updateAttachedQuickLook];
    }
}

- (void)endPreviewPanelControl:(QLPreviewPanel *) [[maybe_unused]] _panel
{
    [m_QLPanelAdaptor unregisterExistingQLPreviewPanelFor:self];
}

- (void)attachPanel:(PanelController *)_pc
{
    _pc.state = self;
    [_pc.view addKeystrokeSink:self];
}

static bool RouteKeyboardInputIntoTerminal()
{
    static bool route = GlobalConfig().GetBool(g_ConfigRouteKeyboardInputIntoTerminal);
    [[clang::no_destroy]] static const auto observe_ticket =
        GlobalConfig().Observe(g_ConfigRouteKeyboardInputIntoTerminal,
                               [] { route = GlobalConfig().GetBool(g_ConfigRouteKeyboardInputIntoTerminal); });
    return route;
}

- (int)bidForHandlingKeyDown:(NSEvent *)_event forPanelView:(PanelView *) [[maybe_unused]] _panel_view
{
    const auto character = _event.charactersIgnoringModifiers;
    if( character.length == 0 )
        return nc::panel::view::BiddingPriority::Skip;
    const auto unicode = [character characterAtIndex:0];

    if( unicode == NSTabCharacter ) {
        return nc::panel::view::BiddingPriority::High;
    }

    if( RouteKeyboardInputIntoTerminal() ) {
        const auto terminal_bid = [self bidForHandlingRoutedIntoOTKeyDown:_event];
        if( terminal_bid > nc::panel::view::BiddingPriority::Skip )
            return terminal_bid;
    }

    return nc::panel::view::BiddingPriority::Skip;
}

- (void)handleKeyDown:(NSEvent *)_event forPanelView:(PanelView *) [[maybe_unused]] _panel_view
{
    const auto character = _event.charactersIgnoringModifiers;
    if( character.length == 0 )
        return;
    const auto unicode = [character characterAtIndex:0];

    if( unicode == NSTabCharacter ) {
        [self changeFocusedSide];
        return;
    }

    if( RouteKeyboardInputIntoTerminal() ) {
        [self handleRoutedIntoOTKeyDown:_event];
        return;
    }
}

- (BOOL)performKeyEquivalent:(NSEvent *)theEvent
{
    // ⌘⇧P opens the full action palette (VSCode/Marta style). Upstream binds
    // this chord to page setup and dual/single mode; those remain reachable
    // from the menus, but the chord now drives the command palette.
    if( (theEvent.modifierFlags & NSEventModifierFlagCommand) &&
        (theEvent.modifierFlags & NSEventModifierFlagShift) &&
        !(theEvent.modifierFlags & NSEventModifierFlagOption) &&
        !(theEvent.modifierFlags & NSEventModifierFlagControl) &&
        [theEvent.charactersIgnoringModifiers isEqualToString:@"P"] ) {
        [self showCommandPalette];
        return true;
    }

    if( m_AttachedResponder && [m_AttachedResponder performKeyEquivalent:theEvent] )
        return true;

    return [super performKeyEquivalent:theEvent];
}

@end

static NSString *TrimmedTitleForWindow(NSString *_title, NSWindow *_window)
{
    static const auto attributes = @{NSFontAttributeName: [NSFont titleBarFontOfSize:0]};

    const auto left = NSMaxX([_window standardWindowButton:NSWindowZoomButton].frame);
    const auto right = _window.frame.size.width;
    const auto padding = 8.;
    const auto width = right - left - (2 * padding);
    return StringByTruncatingToWidth(_title, static_cast<float>(width), kTruncateAtStart, attributes);
}

static NSString *TitleForData(const data::Model *_data)
{
    if( !_data )
        return @"";

    const auto path = [NSString stringWithUTF8StdString:_data->VerboseDirectoryFullPath()];
    if( !path )
        return @"...";

    return path;
}
