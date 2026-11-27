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
#include <Config/RapidJSON.h>
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

@interface NCDirectoryTreeNode : NSObject
@property(nonatomic, copy) NSString *path;
@property(nonatomic, copy) NSString *name;
@property(nonatomic, strong) NSImage *icon;
@property(nonatomic, strong) NSMutableArray<NCDirectoryTreeNode *> *children;
@property(nonatomic, assign) BOOL childrenLoaded;
- (instancetype)initWithPath:(NSString *)path;
@end

@implementation NCDirectoryTreeNode
@synthesize path = _path;
@synthesize name = _name;
@synthesize icon = _icon;
@synthesize children = _children;
@synthesize childrenLoaded = _childrenLoaded;

- (instancetype)initWithPath:(NSString *)path_
{
    self = [super init];
    if( self ) {
        _path = [path_ copy];
        NSString *display = [NSFileManager.defaultManager displayNameAtPath:path_];
        _name = [display.length ? display : path_.lastPathComponent copy];
        _children = [NSMutableArray array];
        _childrenLoaded = NO;
    }
    return self;
}
@end

@interface NCDirectoryTreeView : NSView <NSOutlineViewDataSource, NSOutlineViewDelegate>
@property(nonatomic, weak) id<NCDirectoryTreeDelegate> treeDelegate;
- (void)revealPath:(NSString *)path;
@end

@implementation NCDirectoryTreeView {
    NSOutlineView *_outline;
    NSScrollView *_scroll; // MUST wrap the outline, else its full row count becomes
                           // the intrinsic height and blows up the whole split view (no scroll).
    NCDirectoryTreeNode *_root;
}
@synthesize treeDelegate = _treeDelegate;

- (instancetype)initWithFrame:(NSRect)frameRect
{
    self = [super initWithFrame:frameRect];
    if( !self )
        return nil;

    _root = [[NCDirectoryTreeNode alloc] initWithPath:@"/"];

    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    column.title = @"Folders";
    column.minWidth = 120;

    _outline = [[NSOutlineView alloc] initWithFrame:NSZeroRect];
    _outline.translatesAutoresizingMaskIntoConstraints = NO;
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
    [self loadChildrenForNode:node];
    return node.children.count;
}

- (id)outlineView:(NSOutlineView *)outline_view child:(NSInteger)index ofItem:(id)item
{
    NCDirectoryTreeNode *node = item ?: _root;
    [self loadChildrenForNode:node];
    return index >= 0 && index < static_cast<NSInteger>(node.children.count) ? node.children[index] : nil;
}

- (BOOL)outlineView:(NSOutlineView *)outline_view isItemExpandable:(id)item
{
    NCDirectoryTreeNode *node = item ?: _root;
    BOOL is_dir = NO;
    return [NSFileManager.defaultManager fileExistsAtPath:node.path isDirectory:&is_dir] && is_dir;
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
    if( !node.icon ) {
        node.icon = [NSWorkspace.sharedWorkspace iconForFile:node.path];
        node.icon.size = NSMakeSize(16, 16);
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
    [_treeDelegate directoryTreeDidSelectPath:node.path modifiers:NSApp.currentEvent.modifierFlags];
}

- (void)revealPath:(NSString *)path
{
    if( !path.length || ![path hasPrefix:@"/"] )
        return;
    NSArray<NSString *> *parts = path.pathComponents;
    NSMutableArray<NCDirectoryTreeNode *> *chain = [NSMutableArray array];
    NCDirectoryTreeNode *node = _root;
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
    [_outline reloadData];
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

    m_TreeDivider = [[ColoredSeparatorLine alloc] initWithFrame:NSRect()];
    m_TreeDivider.translatesAutoresizingMaskIntoConstraints = NO;
    m_TreeDivider.borderColor = nc::CurrentTheme().FilePanelsGeneralTopSeparatorColor();
    [self addSubview:m_TreeDivider];
}

// reflect m_ShowDirectoryTree in the layout. Width constants go to 0
// when hidden so the panels reclaim the space; heights are left untouched
// (see the v5.1 resize fix — never pin new views to the superview bottom).
- (void)applyDirectoryTreeVisibility
{
    m_LeftTreeWidthConstraint.constant = m_ShowDirectoryTree ? kDirectoryTreeWidth : 0.0;
    m_TreeDividerWidthConstraint.constant = m_ShowDirectoryTree ? 1.0 : 0.0;
    m_DirectoryTree.hidden = !m_ShowDirectoryTree;
    m_TreeDivider.hidden = !m_ShowDirectoryTree;
}

// toolbar action, travels through the first-responder chain.
- (IBAction)onToggleDirectoryTree:(id) [[maybe_unused]] _sender
{
    m_ShowDirectoryTree = !m_ShowDirectoryTree;
    [NSUserDefaults.standardUserDefaults setBool:m_ShowDirectoryTree forKey:@"nc.showDirectoryTree"];
    [self applyDirectoryTreeVisibility];
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
    m_CommandLine.placeholderString = @"path↵go  ·  !cmd↵run in terminal  ·  ?↵command palette  ·  ↑↓history";
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
- (void)directoryTreeDidSelectPath:(NSString *)path modifiers:(NSEventModifierFlags)modifiers
{
    if( path.length == 0 )
        return;
    const std::string directory = path.UTF8String;
    const BOOL option_held = (modifiers & NSEventModifierFlagOption) != 0;
    const BOOL shift_held = (modifiers & NSEventModifierFlagShift) != 0;

    // The tree itself owns firstResponder, so activePanelController is nil here.
    PanelController *focused = m_LastFocusedPanelController ?: self.leftPanelController;
    if( focused == nil )
        return;
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
        return;

    [self revealPanel:target];
    auto request = std::make_shared<DirectoryChangeRequest>();
    request->RequestedDirectory = directory;
    request->VFS = nc::bootstrap::NativeVFSHostInstance().SharedPtr();
    request->PerformAsynchronous = true;
    request->InitiatedByUser = true;
    [target GoToDirWithContext:request];

    // A plain click behaves like TC: focus goes back to the file list so
    // F3/F5/... keep acting on the panel we just navigated.
    if( !option_held )
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
    // Anchor near the middle of the window so the palette reads as a modal-ish
    // action list, not a corner popup (closer to VSCode/TC command palette).
    const NSRect anchor = NSMakeRect(NSMidX(self.bounds), NSMidY(self.bounds) + 40, 1, 1);
    [palette showRelativeToRect:anchor ofView:self alignment:NCCommandPopoverAlignment::Center];
}

- (void)onCommandPaletteItemSelected:(NCCommandPopoverItem *)sender
{
    NSMenuItem *const menu_item = nc::objc_cast<NSMenuItem>(sender.representedObject);
    [m_CommandPalette close];
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
        // keep the tree's highlighted node in sync with the focused panel.
        if( _panel == m_LastFocusedPanelController )
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

- (void)onThemeChanged
{
    m_SeparatorLine.borderColor = nc::CurrentTheme().FilePanelsGeneralTopSeparatorColor();
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
