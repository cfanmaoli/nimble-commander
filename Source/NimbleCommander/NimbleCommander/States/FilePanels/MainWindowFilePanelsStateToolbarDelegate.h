// Copyright (C) 2016-2025 Michael Kazakov. Subject to GNU General Public License version 3.
#pragma once

@class NCOpsPoolViewController;

namespace nc::panel {
class ExternalToolsStorage;
}
namespace nc::utility {
class ActionsShortcutsManager;
}
namespace nc::ops {
class Pool;
}

@interface MainWindowFilePanelsStateToolbarDelegate : NSObject <NSToolbarDelegate>

- (instancetype)initWithToolsStorage:(nc::panel::ExternalToolsStorage &)_storage
             actionsShortcutsManager:(const nc::utility::ActionsShortcutsManager &)_actions_shortcuts_manager
                   andOperationsPool:(nc::ops::Pool &)_pool;

@property(nonatomic, readonly) NSToolbar *toolbar;
@property(nonatomic, readonly) NSButton *leftPanelGoToButton;
@property(nonatomic, readonly) NSButton *rightPanelGoToButton;
@property(nonatomic, readonly) NCOpsPoolViewController *operationsPoolViewController;
// explicit target for the tree-toggle item. The toggle lives on
// MainWindowFilePanelState, which is NOT on the file panel's responder chain
// once the command line / toolbar owns first responder. Weak to avoid a cycle.
@property(nonatomic, weak) id treeToggleTarget;

@end
