// Copyright (C) 2017-2024 Michael Kazakov. Subject to GNU General Public License version 3.

#include "TabContextMenu.h"
#include "Actions/TabsManagement.h"
#include <NimbleCommander/Core/Alert.h>
#include <Base/UnorderedUtil.h>
#include <iostream>

using namespace nc::panel;
using ActionsT = ankerl::unordered_dense::map<SEL, std::unique_ptr<actions::StateAction>>;

static const actions::StateAction *ActionBySelector(const ActionsT &_actions, SEL _sel);
static void Perform(const ActionsT &_actions, SEL _sel, MainWindowFilePanelState *_target, id _sender);

@implementation NCPanelTabContextMenu {
    ActionsT m_Actions;
    MainWindowFilePanelState *m_State;
    PanelController *m_CurrentPanel;
}

- (instancetype)initWithPanel:(PanelController *)_panel ofState:(MainWindowFilePanelState *)_state
{
    self = [super init];
    if( self ) {
        m_State = _state;
        m_CurrentPanel = _panel;

        [self buildActions];
        [self buildMenuItems];
    }
    return self;
}

- (void)buildActions
{
    using namespace actions::context;
    m_Actions[@selector(onAddNewTab:)] = std::make_unique<AddNewTab>(m_CurrentPanel);
    m_Actions[@selector(onCloseTab:)] = std::make_unique<CloseTab>(m_CurrentPanel);
    m_Actions[@selector(onCloseOtherTabs:)] = std::make_unique<CloseOtherTabs>(m_CurrentPanel);
    m_Actions[@selector(onSendTabToOtherPanel:)] = std::make_unique<SendTabToOtherPanel>(m_CurrentPanel);
    m_Actions[@selector(onCopyTabToOtherPanel:)] = std::make_unique<CopyTabToOtherPanel>(m_CurrentPanel);
    m_Actions[@selector(onDuplicateTab:)] = std::make_unique<DuplicateTab>(m_CurrentPanel);
}

- (void)buildMenuItems
{
    const auto new_tab = [[NSMenuItem alloc] init];
    new_tab.title = NSLocalizedString(@"New Tab", "");
    new_tab.target = self;
    new_tab.action = @selector(onAddNewTab:);
    [self addItem:new_tab];

    const auto close_tab = [[NSMenuItem alloc] init];
    close_tab.title = NSLocalizedString(@"Close Tab", "");
    close_tab.target = self;
    close_tab.action = @selector(onCloseTab:);
    [self addItem:close_tab];

    const auto close_other_tabs = [[NSMenuItem alloc] init];
    close_other_tabs.title = NSLocalizedString(@"Close Other Tabs", "");
    close_other_tabs.target = self;
    close_other_tabs.action = @selector(onCloseOtherTabs:);
    [self addItem:close_other_tabs];

    [self addItem:[NSMenuItem separatorItem]];

    const auto send_to_other_panel = [[NSMenuItem alloc] init];
    send_to_other_panel.title = NSLocalizedString(@"Send Tab to Other Panel", "");
    send_to_other_panel.target = self;
    send_to_other_panel.action = @selector(onSendTabToOtherPanel:);
    [self addItem:send_to_other_panel];

    const auto copy_to_other_panel = [[NSMenuItem alloc] init];
    copy_to_other_panel.title = NSLocalizedString(@"Copy Tab to Other Panel", "");
    copy_to_other_panel.target = self;
    copy_to_other_panel.action = @selector(onCopyTabToOtherPanel:);
    [self addItem:copy_to_other_panel];

    const auto duplicate_tab = [[NSMenuItem alloc] init];
    duplicate_tab.title = NSLocalizedString(@"Duplicate Tab", "");
    duplicate_tab.target = self;
    duplicate_tab.action = @selector(onDuplicateTab:);
    [self addItem:duplicate_tab];
}

- (IBAction)onAddNewTab:(id)sender
{ [self perform:_cmd for:sender];
}
- (IBAction)onCloseTab:(id)sender
{ [self perform:_cmd for:sender];
}
- (IBAction)onCloseOtherTabs:(id)sender
{ [self perform:_cmd for:sender];
}
- (IBAction)onSendTabToOtherPanel:(id)sender
{ [self perform:_cmd for:sender];
}
- (IBAction)onCopyTabToOtherPanel:(id)sender
{ [self perform:_cmd for:sender];
}
- (IBAction)onDuplicateTab:(id)sender
{ [self perform:_cmd for:sender];
}

- (void)perform:(SEL)_sel for:(id)_sender
{
    Perform(m_Actions, _sel, m_State, _sender);
}

- (BOOL)validateMenuItem:(NSMenuItem *)item
{
    try {
        if( const auto action = ActionBySelector(m_Actions, item.action) )
            return action->ValidateMenuItem(m_State, item);
        return true;
    } catch( std::exception &e ) {
        std::cout << "Exception caught: " << e.what() << '\n';
    } catch( ... ) {
        std::cout << "Caught an unhandled exception!" << '\n';
    }
    return false;
}

@end

static const actions::StateAction *ActionBySelector(const ActionsT &_actions, SEL _sel)
{
    if( const auto action = _actions.find(_sel); action != end(_actions) )
        return action->second.get();

    return nullptr;
}

static void Perform(const ActionsT &_actions, SEL _sel, MainWindowFilePanelState *_target, id _sender)
{
    if( const auto action = _actions.find(_sel); action != end(_actions) ) {
        try {
            action->second->Perform(_target, _sender);
        } catch( std::exception &e ) {
            nc::core::ShowExceptionAlert(e);
        } catch( ... ) {
            nc::core::ShowExceptionAlert();
        }
    }
    else {
        std::cerr << "warning - unrecognized selector: " << NSStringFromSelector(_sel).UTF8String << '\n';
    }
}
