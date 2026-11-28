// Copyright (C) 2017-2025 Michael Kazakov. Subject to GNU General Public License version 3.
#include "TabsManagement.h"
#include "../MainWindowFilePanelState.h"
#include "../MainWindowFilePanelState+TabsSupport.h"
#include "../PanelController.h"
#include "../Views/FilePanelMainSplitView.h"
#include <NimbleCommander/Core/Alert.h>
#include <Panel/PanelData.h>
#include <Utility/ObjCpp.h>

namespace nc::panel::actions {

static const auto g_CloseTab = NSLocalizedString(@"Close Tab", "Menu item title for closing current tab");
static const auto g_CloseWindow = NSLocalizedString(@"Close Window", "Menu item title for closing current window");

bool ShowNextTab::Predicate(MainWindowFilePanelState *_target) const
{
    return _target.currentSideTabsCount > 1;
}

bool ShowNextTab::ValidateMenuItem(MainWindowFilePanelState *_target, NSMenuItem * /*_item*/) const
{
    return Predicate(_target);
}

void ShowNextTab::Perform(MainWindowFilePanelState *_target, id /*_sender*/) const
{
    [_target selectNextFilePanelTab];
}

bool ShowPreviousTab::Predicate(MainWindowFilePanelState *_target) const
{
    return _target.currentSideTabsCount > 1;
}

bool ShowPreviousTab::ValidateMenuItem(MainWindowFilePanelState *_target, NSMenuItem * /*_item*/) const
{
    return Predicate(_target);
}

void ShowPreviousTab::Perform(MainWindowFilePanelState *_target, id /*_sender*/) const
{
    [_target selectPreviousFilePanelTab];
}

bool CloseTab::ValidateMenuItem(MainWindowFilePanelState *_target, NSMenuItem *_item) const
{
    const auto tabs = _target.currentSideTabsCount;
    if( tabs == 0 ) {
        // in this case (no other adequate responders) - pass validation  up
        NSResponder *resp = _target.nextResponder;
        while( objc_cast<AttachedResponder>(resp) != nil )
            resp = resp.nextResponder;
        while( resp != nil ) {
            if( [resp respondsToSelector:_item.action] && [resp respondsToSelector:@selector(validateMenuItem:)] ) {
                [static_cast<id<NSMenuItemValidation>>(resp) validateMenuItem:_item];
            }
            resp = resp.nextResponder;
        }
        return true;
    }
    _item.title = tabs > 1 ? g_CloseTab : g_CloseWindow;
    return Predicate(_target);
}

static void
AskAboutClosingWindowWithExtraTabs(int _amount, NSWindow *_window, std::function<void(NSModalResponse)> _handler)
{
    assert(_window && _handler);
    Alert *const dialog = [[Alert alloc] init];
    [dialog addButtonWithTitle:NSLocalizedString(@"Close", "User action to close a window")];
    [dialog addButtonWithTitle:NSLocalizedString(@"Cancel", "")];
    const auto fmt = NSLocalizedString(@"The window has %@ tabs. Are you sure you want to close this window?",
                                       "Asking user to close window with additional tabs");
    const auto msg = [NSString localizedStringWithFormat:fmt, [NSNumber numberWithInt:_amount]];
    dialog.messageText = msg;
    [dialog beginSheetModalForWindow:_window
                   completionHandler:^(NSModalResponse result) {
                     _handler(result);
                   }];
}

void CloseTab::Perform(MainWindowFilePanelState *_target, id _sender) const
{
    const auto act_pc = _target.activePanelController;
    int tabs_on_current_side = 0;
    if( [_target isLeftController:act_pc] )
        tabs_on_current_side = _target.splitView.leftTabbedHolder.tabsCount;
    else if( [_target isRightController:act_pc] )
        tabs_on_current_side = _target.splitView.rightTabbedHolder.tabsCount;

    if( tabs_on_current_side > 1 ) {
        [_target closeTabForController:act_pc];
    }
    else {
        const int total_tabs = static_cast<int>(_target.leftControllers.size() + _target.rightControllers.size());
        if( total_tabs > 2 ) {
            const auto window = _target.window;
            const auto close_callback = [=](NSModalResponse result) {
                if( result != NSAlertFirstButtonReturn )
                    return;
                dispatch_to_main_queue([=] { [window close]; });
            };
            AskAboutClosingWindowWithExtraTabs(total_tabs, window, close_callback);
        }
        else {
            [_target.window performClose:_sender];
        }
    }
}

bool CloseOtherTabs::Predicate(MainWindowFilePanelState *_target) const
{
    const auto active_controller = _target.activePanelController;
    if( active_controller == nil )
        return false;

    const auto amount_of_tab_on_this_side = [&]() -> size_t {
        if( [_target isLeftController:active_controller] )
            return _target.leftControllers.size();
        if( [_target isRightController:active_controller] )
            return _target.rightControllers.size();
        return 0;
    }();

    return amount_of_tab_on_this_side > 1;
}

void CloseOtherTabs::Perform(MainWindowFilePanelState *_target, id /*_sender*/) const
{
    if( !Predicate(_target) )
        return;
    [_target closeOtherTabsForController:_target.activePanelController];
}

bool CloseWindow::ValidateMenuItem(MainWindowFilePanelState *_target, NSMenuItem *_item) const
{
    _item.hidden = _target.currentSideTabsCount < 2;
    return Predicate(_target);
}

void CloseWindow::Perform(MainWindowFilePanelState *_target, id _sender) const
{
    [_target.window performClose:_sender];
}

void AddNewTab::Perform(MainWindowFilePanelState *_target, id /*_sender*/) const
{
    const auto active_pc = _target.activePanelController;
    if( !active_pc )
        return;

    NSTabView *target_tab_view = nil;

    if( active_pc == _target.leftPanelController )
        target_tab_view = _target.splitView.leftTabbedHolder.tabView;
    else if( active_pc == _target.rightPanelController )
        target_tab_view = _target.splitView.rightTabbedHolder.tabView;

    if( !target_tab_view )
        return;

    [_target addNewTabToTabView:target_tab_view];
}

context::AddNewTab::AddNewTab(PanelController *_current_pc) : m_CurrentPC(_current_pc)
{
}

void context::AddNewTab::Perform(MainWindowFilePanelState *_target, id /*_sender*/) const
{
    NSTabView *target_tab_view = nil;

    if( [_target isLeftController:m_CurrentPC] )
        target_tab_view = _target.splitView.leftTabbedHolder.tabView;
    else if( [_target isRightController:m_CurrentPC] )
        target_tab_view = _target.splitView.rightTabbedHolder.tabView;

    if( !target_tab_view )
        return;

    [_target addNewTabToTabView:target_tab_view];
}

context::CloseTab::CloseTab(PanelController *_current_pc) : m_CurrentPC(_current_pc)
{
}

bool context::CloseTab::Predicate(MainWindowFilePanelState *_target) const
{
    if( [_target isLeftController:m_CurrentPC] )
        return _target.leftControllers.size() > 1;
    if( [_target isRightController:m_CurrentPC] )
        return _target.rightControllers.size() > 1;
    return false;
}

void context::CloseTab::Perform(MainWindowFilePanelState *_target, id /*_sender*/) const
{
    [_target closeTabForController:m_CurrentPC];
}

context::CloseOtherTabs::CloseOtherTabs(PanelController *_current_pc) : m_CurrentPC(_current_pc)
{
}

bool context::CloseOtherTabs::Predicate(MainWindowFilePanelState *_target) const
{
    if( [_target isLeftController:m_CurrentPC] )
        return _target.leftControllers.size() > 1;
    if( [_target isRightController:m_CurrentPC] )
        return _target.rightControllers.size() > 1;
    return false;
}

void context::CloseOtherTabs::Perform(MainWindowFilePanelState *_target, id /*_sender*/) const
{
    [_target closeOtherTabsForController:m_CurrentPC];
}

namespace {

unsigned TabsCountOnSideOf(MainWindowFilePanelState *_target, PanelController *_pc)
{
    if( [_target isLeftController:_pc] )
        return static_cast<unsigned>(_target.leftControllers.size());
    if( [_target isRightController:_pc] )
        return static_cast<unsigned>(_target.rightControllers.size());
    return 0;
}

/**
 * Spawns a new tab either next to the given one (duplicate) or in the opposite pane (copy/send),
 * recreating that tab's location, listing and view options. Returns the new controller.
 */
PanelController *ReplicateTabInTabView(MainWindowFilePanelState *_target,
                                       PanelController *_source,
                                       bool _to_opposite_side)
{
    if( _source == nil )
        return nil;

    const bool source_on_left = [_target isLeftController:_source];
    const bool source_on_right = [_target isRightController:_source];
    if( source_on_left == source_on_right )
        return nil;

    const bool destination_on_left = _to_opposite_side ? source_on_right : source_on_left;
    NSTabView *const destination_tab_view = destination_on_left
                                                 ? _target.splitView.leftTabbedHolder.tabView
                                                 : _target.splitView.rightTabbedHolder.tabView;
    if( destination_tab_view == nil )
        return nil;

    PanelController *const replica = [_target spawnNewTabInTabView:destination_tab_view
                                             autoDirectoryLoading:false
                                                 activateNewPanel:true];
    if( replica == nil )
        return nil;

    // spawnNewTabInTabView inherits options from whichever panel is currently selected on that side
    // and doesn't load anything, so replace the options with the requested tab's ones and load its
    // listing as-is - archives, flat views and temporary listings then carry over unchanged.
    [replica copyOptionsFromController:_source];
    [replica loadListing:_source.data.ListingPtr()];
    return replica;
}

} // namespace

context::DuplicateTab::DuplicateTab(PanelController *_current_pc) : m_CurrentPC(_current_pc)
{
}

void context::DuplicateTab::Perform(MainWindowFilePanelState *_target, id /*_sender*/) const
{
    ReplicateTabInTabView(_target, m_CurrentPC, false);
}

context::CopyTabToOtherPanel::CopyTabToOtherPanel(PanelController *_current_pc) : m_CurrentPC(_current_pc)
{
}

bool context::CopyTabToOtherPanel::Predicate(MainWindowFilePanelState *_target) const
{
    if( [_target isLeftController:m_CurrentPC] )
        return !_target.rightControllers.empty();
    if( [_target isRightController:m_CurrentPC] )
        return !_target.leftControllers.empty();
    return false;
}

void context::CopyTabToOtherPanel::Perform(MainWindowFilePanelState *_target, id /*_sender*/) const
{
    ReplicateTabInTabView(_target, m_CurrentPC, true);
}

context::SendTabToOtherPanel::SendTabToOtherPanel(PanelController *_current_pc) : m_CurrentPC(_current_pc)
{
}

bool context::SendTabToOtherPanel::Predicate(MainWindowFilePanelState *_target) const
{
    if( [_target isLeftController:m_CurrentPC] )
        return !_target.rightControllers.empty();
    if( [_target isRightController:m_CurrentPC] )
        return !_target.leftControllers.empty();
    return false;
}

void context::SendTabToOtherPanel::Perform(MainWindowFilePanelState *_target, id /*_sender*/) const
{
    if( ReplicateTabInTabView(_target, m_CurrentPC, true) == nil )
        return;

    // A pane must always keep at least one tab, so a lone tab stays where it is - the action then
    // ends up behaving like a copy.
    if( TabsCountOnSideOf(_target, m_CurrentPC) > 1 )
        [_target closeTabForController:m_CurrentPC];
}

} // namespace nc::panel::actions
