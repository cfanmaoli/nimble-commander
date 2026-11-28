// Copyright (C) 2013-2024 Michael Kazakov. Subject to GNU General Public License version 3.
#pragma once

#include <VFS/VFS.h>
#include <Panel/UI/PanelTabBarView.h>
#include "../MainWindowStateProtocol.h"
#include <Config/Config.h>
#include <Panel/PanelViewKeystrokeSink.h>
#include "PanelPreview.h"
#include "PanelControllerPersistency.h"
#include <Utility/MIMResponder.h>
#include <Base/Observable.h>

namespace nc::ops {
class Pool;
}

namespace nc::panel {
class FavoriteLocationsStorage;
class ClosedPanelsHistory;
class ExternalToolsStorage;
namespace data {
class Model;
}
} // namespace nc::panel

@class NCMainWindowController;
@class Operation;
@class PanelView;
@class PanelController;
@class BriefSystemOverview;
@class FilePanelMainSplitView;
@class FilePanelOverlappedTerminal;
@class MainWindowFilePanelsStateToolbarDelegate;
@class ColoredSeparatorLine;
@class NCPanelQLPanelAdaptor;
@class NCDirectoryTreeView;
@class AnyHolder;
#include <CUI/CommandPopover.h>

struct MainWindowFilePanelState_OverlappedTerminalSupport;

@protocol NCDirectoryTreeDelegate <NSObject>
- (void)directoryTreeDidSelectPath:(NSString *)path modifiers:(NSEventModifierFlags)modifiers;
// Favorites/recents may point outside the native filesystem, so they travel as a
// PersistentLocation wrapped into an AnyHolder.
- (void)directoryTreeDidSelectLocation:(AnyHolder *)location modifiers:(NSEventModifierFlags)modifiers;
// Workspaces: apply the stored layout, or ask for the save/overwrite/delete flow.
- (void)directoryTreeDidApplyWorkspaceAtIndex:(NSInteger)index;
- (void)directoryTreeDidRequestSaveWorkspace;
- (void)directoryTreeDidRequestOverwriteWorkspaceAtIndex:(NSInteger)index;
- (void)directoryTreeDidRequestDeleteWorkspaceAtIndex:(NSInteger)index;
@end

@interface MainWindowFilePanelState : NSView <NCMainWindowState, NCPanelViewKeystrokeSink, NCPanelTabBarViewDelegate, NSTextFieldDelegate, NCCommandPopoverDelegate, NCDirectoryTreeDelegate> {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-interface-ivars"
    std::function<PanelController *()> m_PanelFactory;
    std::vector<PanelController *> m_LeftPanelControllers;
    std::vector<PanelController *> m_RightPanelControllers;
    __weak PanelController *m_LastFocusedPanelController;

    AttachedResponder *m_AttachedResponder;

    FilePanelMainSplitView *m_SplitView;
    NCDirectoryTreeView *m_DirectoryTree; // always-visible directory tree on the left
    NSView *m_TreeDivider; // 2.1.16: drag handle, a hairline inside a wider hit area
    NSLayoutConstraint *m_LeftTreeWidthConstraint;
    NSLayoutConstraint *m_TreeDividerWidthConstraint; // collapse divider together with the tree
    BOOL m_ShowDirectoryTree; // toolbar-toggleable tree visibility
    double m_TreeDragStartWidth; // sidebar width when the divider drag began
    int m_LastSidebarRecentLimit;
    BOOL m_LastSmartDates;
    BOOL m_LastSizeBars; // last seen nc.sidebar.recentLimit, for change detection
    NSView *m_FKeyBar; // bottom bar (command line)
    NSTextField *m_CommandLine; // TC-style bottom command line
    NCCommandPopover *m_CommandPalette; // searchable action palette, summoned with "?"
    std::vector<std::string> m_CommandHistory;
    size_t m_CommandHistoryPos;
    NSLayoutConstraint *m_MainSplitViewBottomConstraint;

    std::unique_ptr<MainWindowFilePanelState_OverlappedTerminalSupport> m_OverlappedTerminal;

    ColoredSeparatorLine *m_SeparatorLine;
    MainWindowFilePanelsStateToolbarDelegate *m_ToolbarDelegate;
    __weak NSResponder *m_LastResponder;
    NCCommandPopover *m_CommandPopover;

    bool m_ShowTabs;

    std::vector<nc::config::Token> m_ConfigTickets;
    std::shared_ptr<nc::ops::Pool> m_OperationsPool;
    std::shared_ptr<nc::panel::ClosedPanelsHistory> m_ClosedPanelsHistory;
    std::shared_ptr<nc::panel::FavoriteLocationsStorage> m_FavoriteLocationsStorage;
    nc::panel::ControllerStateJSONDecoder *m_ControllerStateJSONDecoder;
    NCPanelQLPanelAdaptor *m_QLPanelAdaptor;
    nc::base::ObservableBase::ObservationTicket m_ThemesObservationTicket;
#pragma clang diagnostic pop
}

@property(nonatomic, readonly) NCMainWindowController *mainWindowController;
@property(nonatomic, readonly) FilePanelMainSplitView *splitView;
@property(nonatomic, readonly) nc::ops::Pool &operationsPool;
@property(nonatomic, readonly) bool isPanelActive;
@property(nonatomic, readonly) bool goToForcesPanelActivation;
@property(nonatomic, readwrite) std::shared_ptr<nc::panel::ClosedPanelsHistory> closedPanelsHistory;
@property(nonatomic, readwrite) std::shared_ptr<nc::panel::FavoriteLocationsStorage> favoriteLocationsStorage;
@property(nonatomic, readwrite) AttachedResponder *attachedResponder;

- (instancetype)initWithFrame:(NSRect)frameRect
                       andPool:(nc::ops::Pool &)_pool
            loadDefaultContent:(bool)_load_content
                  panelFactory:(std::function<PanelController *()>)_panel_factory
    controllerStateJSONDecoder:(nc::panel::ControllerStateJSONDecoder &)_controller_json_decoder
                QLPanelAdaptor:(NCPanelQLPanelAdaptor *)_ql_panel_adaptor;

- (void)loadDefaultPanelContent;

- (void)ActivatePanelByController:(PanelController *)controller;
- (void)activePanelChangedTo:(PanelController *)controller;

/**
 * Ensures that this panel is not collapsed and is not overlaid.
 */
- (void)revealPanel:(PanelController *)panel;

/**
 * Called by panel controller when it sucessfuly changes it's current path
 */
- (void)PanelPathChanged:(PanelController *)_panel;

// toggle the left directory tree from the toolbar.
- (IBAction)onToggleDirectoryTree:(id)sender;
// 2.1.5: open the full command palette from the toolbar button.
- (IBAction)onShowCommandPalette:(id)sender;

/**
 * result may contain duplicates
 */
@property(nonatomic, readonly) std::vector<std::tuple<std::string, VFSHostPtr>> filePanelsCurrentPaths;

- (id<NCPanelPreview>)quickLookForPanel:(PanelController *)_panel make:(bool)_make_if_absent;
- (BriefSystemOverview *)briefSystemOverviewForPanel:(PanelController *)_panel make:(bool)_make_if_absent;

- (void)requestTerminalExecution:(const std::string &)_filename at:(const std::string &)_cwd;
- (void)closeAttachedUI:(PanelController *)_panel;

- (nc::config::Value)encodeRestorableState;
- (bool)decodeRestorableState:(const nc::config::Value &)_state;
- (void)markRestorableStateAsInvalid;

- (void)saveDefaultInitialState;

- (void)swapPanels;

/**
 * Return currently active file panel if any.
 */
@property(nonatomic, readonly) PanelController *activePanelController;
@property(nonatomic, readonly) const nc::panel::data::Model *activePanelData; // based on .ActivePanelController
@property(nonatomic, readonly) PanelView *activePanelView;                    // based on .ActivePanelController

/**
 * If current active panel controller is left - return .rightPanelController,
 * If current active panel controller is right - return .leftPanelController,
 * If there's no active panel controller (no focus) - return nil
 * (regardless if this panel is collapsed or overlayed)
 */
@property(nonatomic, readonly) PanelController *oppositePanelController;
@property(nonatomic, readonly) const nc::panel::data::Model *oppositePanelData; // based on oppositePanelController
@property(nonatomic, readonly) PanelView *oppositePanelView;                    // based on oppositePanelController

/**
 * Pick one of a controllers in left side tabbed bar, which is currently selected (regardless if it
 * is active or not). May return nil in init/shutdown period or in invalid state.
 */
@property(nonatomic, readonly) PanelController *leftPanelController;
@property(nonatomic, readonly) const std::vector<PanelController *> &leftControllers;

/**
 * Pick one of a controllers in right side tabbed bar, which is currently selected (regardless if it
 * is active or not). May return nil in init/shutdown period or in invalid state.
 */
@property(nonatomic, readonly) PanelController *rightPanelController;
@property(nonatomic, readonly) const std::vector<PanelController *> &rightControllers;

/**
 * Checks if this controller is one of a state's left-side controllers set.
 */
- (bool)isLeftController:(PanelController *)_controller;

/**
 * Checks if this controller is one of a state's right-side controllers set.
 */
- (bool)isRightController:(PanelController *)_controller;

/**
 * Panels split view may be hidden to fully show overlapped terminal contents
 */
@property(nonatomic, readonly) bool isPanelsSplitViewHidden;

@property(nonatomic, readonly) bool anyPanelCollapsed;

@property(nonatomic, readonly) bool bothPanelsAreVisible;

/**
 * Process Tab button - change focus from left panel to right and vice versa.
 */
- (void)changeFocusedSide;

@end

@interface MainWindowFilePanelState ()

- (void)updateBottomConstraint;
- (void)createFKeyBar; // function key bar + command line
- (void)onFKeyBarButton:(NSButton *)sender;
- (void)onCommandLineSubmit:(NSTextField *)sender;
- (void)executeCommandLineInTerminal:(const std::string &)_command;
- (void)showCommandPalette;
- (void)showFrecencyJump;
- (void)onCommandPaletteItemSelected:(NCCommandPopoverItem *)sender;
- (void)createDirectoryTree; // v4
- (void)applyDirectoryTreeVisibility; // v6
- (void)applyConfiguredLayoutToPanels; // honor nc.defaultPanelLayout (default = list)
- (void)directoryTreeDidSelectPath:(NSString *)path modifiers:(NSEventModifierFlags)modifiers;

- (void)addNewControllerOnLeftPane:(PanelController *)_pc;
- (void)addNewControllerOnRightPane:(PanelController *)_pc;
- (void)panelWillBeClosed:(PanelController *)_pc;

- (void)attachPanel:(PanelController *)_pc; // +detach in the future

@property(nonatomic) IBOutlet NSToolbar *filePanelsToolsbar;

@end
