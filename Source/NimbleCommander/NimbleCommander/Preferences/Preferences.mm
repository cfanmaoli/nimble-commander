// Copyright (C) 2016-2025 Michael Kazakov. Subject to GNU General Public License version 3.
#include <NimbleCommander/Bootstrap/AppDelegate.h>
#include "PreferencesWindowGeneralTab.h"
#include "PreferencesWindowPanelsTab.h"
#include "PreferencesWindowViewerTab.h"
#include "PreferencesWindowExternalEditorsTab.h"
#include "PreferencesWindowTerminalTab.h"
#include "PreferencesWindowCompressionTab.h"
#include "PreferencesWindowHotkeysTab.h"
#include "PreferencesWindowToolsTab.h"
#include "PreferencesWindowThemesTab.h"
#include "PreferencesWindowLanguageTab.h"
#include "Preferences.h"
#include <NimbleCommanderCommon-Swift.h>

// 2.1.21: sidebar settings tab. Implemented here instead of a new file so the Xcode
// project needs no surgery - the whole view is built in code, no nib involved.
// 2.1.22: the protocol conformance is not cosmetic. PreferencesWindowController
// bridges the ObjC array into a Swift array of existentials; an element that does
// not conform leaves a bogus slot, and the toolbar setup loop then traps on it.
@interface PreferencesWindowSidebarTab : NSViewController <PreferencesViewControllerProtocol>
@end

@implementation PreferencesWindowSidebarTab

- (NSString *)identifier
{
    return @"sidebar";
}

- (NSImage *)toolbarItemImage
{
    NSImage *const symbol = [NSImage imageWithSystemSymbolName:@"sidebar.left" accessibilityDescription:@"Sidebar"];
    if( symbol )
        return symbol;
    // Must never return nil - on the Swift side this is typed as a non-optional.
    NSImage *const fallback = [NSImage imageNamed:NSImageNamePreferencesGeneral];
    return fallback ?: [[NSImage alloc] init];
}

- (NSString *)toolbarItemLabel
{
    return @"侧栏";
}

- (void)loadView
{
    // 2.1.23: the root view size IS the window size - PreferencesWindowController
    // resizes the window to controller.view.bounds on every tab switch. Every other
    // tab uses 730pt wide, so a smaller view here makes the window jump when this
    // tab is selected.
    NSView *const root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 730, 420)];

    NSTextField *const recent_label = [NSTextField labelWithString:@"「最近」最多显示"];
    NSTextField *const link_label = [NSTextField labelWithString:@"目录树联动"];

    NSPopUpButton *const recent_popup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    for( int i = 1; i <= 20; ++i )
        [recent_popup addItemWithTitle:[NSString stringWithFormat:@"%d 个", i]];
    recent_popup.target = self;
    recent_popup.action = @selector(onRecentLimitChanged:);

    NSPopUpButton *const link_popup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [link_popup addItemWithTitle:@"树 → 面板（默认）"];
    [link_popup addItemWithTitle:@"双向（树 ↔ 面板）"];
    [link_popup addItemWithTitle:@"不联动"];
    link_popup.target = self;
    link_popup.action = @selector(onLinkModeChanged:);

    NSUserDefaults *const defaults = NSUserDefaults.standardUserDefaults;
    const NSInteger stored_limit =
        [defaults objectForKey:@"nc.sidebar.recentLimit"] ? [defaults integerForKey:@"nc.sidebar.recentLimit"] : 5;
    const NSInteger limit = stored_limit < 1 ? 1 : (stored_limit > 20 ? 20 : stored_limit);
    [recent_popup selectItemAtIndex:limit - 1];
    const NSInteger stored_mode =
        [defaults objectForKey:@"nc.sidebar.linkMode"] ? [defaults integerForKey:@"nc.sidebar.linkMode"] : 0;
    [link_popup selectItemAtIndex:( stored_mode >= 0 && stored_mode <= 2 ) ? stored_mode : 0];

    NSGridView *const grid = [NSGridView gridViewWithViews:@[ @[ recent_label, recent_popup ],
                                                              @[ link_label, link_popup ] ]];
    grid.translatesAutoresizingMaskIntoConstraints = NO;
    grid.rowSpacing = 12;
    grid.columnSpacing = 12;
    [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    [root addSubview:grid];
    [NSLayoutConstraint activateConstraints:@[
        [grid.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:20],
        [grid.topAnchor constraintEqualToAnchor:root.topAnchor constant:20],
    ]];
    self.view = root;
}

- (void)onRecentLimitChanged:(NSPopUpButton *)sender
{
    [NSUserDefaults.standardUserDefaults setInteger:sender.indexOfSelectedItem + 1
                                            forKey:@"nc.sidebar.recentLimit"];
}

- (void)onLinkModeChanged:(NSPopUpButton *)sender
{
    [NSUserDefaults.standardUserDefaults setInteger:sender.indexOfSelectedItem
                                            forKey:@"nc.sidebar.linkMode"];
}

@end

static PreferencesWindowController *CreatePrefWindow()
{
    const auto tools_storage = []() -> nc::panel::ExternalToolsStorage & { return NCAppDelegate.me.externalTools; };
    const auto app_del = NCAppDelegate.me;
    const auto tabs = @[
        [PreferencesWindowGeneralTab new],
        [PreferencesWindowThemesTab new],
        [PreferencesWindowPanelsTab new],
        [PreferencesWindowSidebarTab new],
        [[PreferencesWindowViewerTab alloc] initWithHistory:app_del.internalViewerHistory],
        [[PreferencesWindowExternalEditorsTab alloc] initWithEditorsStorage:app_del.externalEditorsStorage],
        [PreferencesWindowTerminalTab new],
        [PreferencesWindowCompressionTab new],
        [[PreferencesWindowHotkeysTab alloc] initWithToolsStorage:tools_storage
                                          actionsShortcutsManager:app_del.actionsShortcutsManager],
        [[PreferencesWindowToolsTab alloc] initWithToolsStorage:tools_storage],
        [PreferencesWindowLanguageTab new]
    ];
    return [[PreferencesWindowController alloc] initWithControllers:tabs title:@"Preferences"];
}

void ShowPreferencesWindow()
{
    static const auto preferences = CreatePrefWindow();
    [preferences showWindow:nil];
}
