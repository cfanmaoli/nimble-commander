// Copyright (C) 2017-2024 Michael Kazakov. Subject to GNU General Public License version 3.
#include "Delete.h"
#include "../PanelController.h"
#include "../MainWindowFilePanelState.h"
#include <Utility/NativeFSManager.h>
#include <Base/algo.h>
#include <Panel/PanelData.h>
#include "../PanelView.h"
#include <Operations/Deletion.h>
#include <Operations/DeletionDialog.h>
#include "../../MainWindowController.h"
#include <ankerl/unordered_dense.h>
#include <Base/dispatch_cpp.h>
#include <RoutedIO/Trash.h>
#include <NimbleCommander/Bootstrap/NativeVFSHostInstance.h>

#include <AppKit/AppKit.h>
#include <algorithm>
#include <atomic>
#include <filesystem>
#include <memory>

namespace nc::panel::actions {

static bool CommonDeletePredicate(PanelController *_target);
static bool AllAreNative(const std::vector<VFSListingItem> &_c);
static ankerl::unordered_dense::set<std::string> ExtractDirectories(const std::vector<VFSListingItem> &_c);
static bool TryTrash(const std::vector<VFSListingItem> &_c, utility::NativeFSManager &_fsman);
static void AddPanelRefreshEpilog(PanelController *_target, nc::ops::Operation &_operation);

Delete::Delete(nc::utility::NativeFSManager &_nat_fsman, bool _permanently)
    : m_NativeFSManager{_nat_fsman}, m_Permanently(_permanently)
{
}

bool Delete::Predicate(PanelController *_target) const
{
    return CommonDeletePredicate(_target);
}

void Delete::Perform(PanelController *_target, id /*_sender*/) const
{
    const auto items = to_shared_ptr(_target.selectedEntriesOrFocusedEntry);
    if( items->empty() )
        return;

    const auto sheet = [[NCOpsDeletionDialog alloc] initWithItems:items];
    if( AllAreNative(*items) ) {
        const auto try_trash = TryTrash(*items, m_NativeFSManager);
        sheet.allowMoveToTrash = try_trash;
        sheet.defaultType = [&] {
            if( m_Permanently )
                return nc::ops::DeletionType::Permanent;
            else
                return try_trash ? nc::ops::DeletionType::Trash : nc::ops::DeletionType::Permanent;
        }();
    }
    else {
        sheet.allowMoveToTrash = false;
        sheet.defaultType = nc::ops::DeletionType::Permanent;
    }

    const auto sheet_handler = ^(NSModalResponse returnCode) {
      if( returnCode == NSModalResponseOK ) {
          const auto operation = std::make_shared<nc::ops::Deletion>(std::move(*items), sheet.resultType);
          AddPanelRefreshEpilog(_target, *operation);
          [_target.mainWindowController enqueueOperation:operation];
      }
    };

    [_target.mainWindowController beginSheet:sheet.window completionHandler:sheet_handler];
}

MoveToTrash::MoveToTrash(nc::utility::NativeFSManager &_nat_fsman) : m_NativeFSManager{_nat_fsman}
{
}

bool MoveToTrash::Predicate(PanelController *_target) const
{
    return CommonDeletePredicate(_target);
}

void MoveToTrash::Perform(PanelController *_target, id _sender) const
{
    auto items = _target.selectedEntriesOrFocusedEntry;

    if( !AllAreNative(items) ) {
        // instead of trying to silently reap files on VFS like FTP
        // (that means we'll erase it, not move to trash),
        // forward the request as a regular F8 delete
        Delete{m_NativeFSManager, false}.Perform(_target, _sender);
        return;
    }

    if( !TryTrash(items, m_NativeFSManager) ) {
        // if user called MoveToTrash by cmd+backspace but there's no trash on this volume:
        // show a dialog and ask him to delete a file permanently
        Delete{m_NativeFSManager, true}.Perform(_target, _sender);
        return;
    }

    const auto operation = std::make_shared<nc::ops::Deletion>(std::move(items), nc::ops::DeletionType::Trash);
    AddPanelRefreshEpilog(_target, *operation);
    [_target.mainWindowController enqueueOperation:operation];
}

context::MoveToTrash::MoveToTrash(const std::vector<VFSListingItem> &_items) : m_Items(_items)
{
    m_AllAreNative = AllAreNative(m_Items);
}

bool context::MoveToTrash::Predicate(PanelController * /*_target*/) const
{
    return m_AllAreNative;
}

void context::MoveToTrash::Perform(PanelController *_target, id /*_sender*/) const
{
    const auto operation = std::make_shared<nc::ops::Deletion>(m_Items, nc::ops::DeletionType::Trash);
    AddPanelRefreshEpilog(_target, *operation);
    [_target.mainWindowController enqueueOperation:operation];
}

context::DeletePermanently::DeletePermanently(const std::vector<VFSListingItem> &_items) : m_Items(_items)
{
    m_AllWriteable = std::ranges::all_of(m_Items, [](const auto &i) { return i.Host()->IsWritable(); });
}

bool context::DeletePermanently::Predicate(PanelController * /*_target*/) const
{
    return m_AllWriteable;
}

void context::DeletePermanently::Perform(PanelController *_target, id /*_sender*/) const
{
    const auto operation = std::make_shared<nc::ops::Deletion>(m_Items, nc::ops::DeletionType::Permanent);
    AddPanelRefreshEpilog(_target, *operation);
    [_target.mainWindowController enqueueOperation:operation];
}

static bool CommonDeletePredicate(PanelController *_target)
{
    const auto i = _target.view.item;
    if( !i || !i.Host()->IsWritable() )
        return false;
    return !i.IsDotDot() || _target.data.Stats().selected_entries_amount > 0;
}

static bool AllAreNative(const std::vector<VFSListingItem> &_c)
{
    return std::ranges::all_of(_c, [&](auto &i) { return i.Host()->IsNativeFS(); });
}

static ankerl::unordered_dense::set<std::string> ExtractDirectories(const std::vector<VFSListingItem> &_c)
{
    ankerl::unordered_dense::set<std::string> directories;
    for( const auto &i : _c )
        directories.emplace(i.Directory());
    return directories;
}

static bool TryTrash(const std::vector<VFSListingItem> &_c, utility::NativeFSManager &_fsman)
{
    const auto directories = ExtractDirectories(_c);

    const bool all_have_trash = std::ranges::all_of(directories, [&](const std::string &dir) {
        if( const auto vol = _fsman.VolumeFromPath(dir); vol && vol->interfaces.has_trash )
            return true;
        return false;
    });

    // if we already know that each volume have a trash folder - just say yes
    if( all_have_trash )
        return true;

    // otherwise, speculate a bit and try doing trash on locally-mounted volumes as well
    const bool all_are_local = std::ranges::all_of(directories, [&](const std::string &dir) {
        if( const auto vol = _fsman.VolumeFromPath(dir); vol && vol->mount_flags.local )
            return true;
        return false;
    });
    return all_are_local;
}

static void AddPanelRefreshEpilog(PanelController *_target, nc::ops::Operation &_operation)
{
    __weak PanelController *weak_panel = _target;
    _operation.ObserveUnticketed(nc::ops::Operation::NotifyAboutFinish, [=] {
        dispatch_to_main_queue([=] {
            if( PanelController *const strong_pc = weak_panel )
                [strong_pc hintAboutFilesystemChange];
        });
    });
}

namespace {

NSString *TrashLocalizedText(NSString *_key)
{
    return NSLocalizedString(_key, nil);
}

void OpenFullDiskAccessSettings()
{
    NSURL *const url =
        [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"];
    [NSWorkspace.sharedWorkspace openURL:url];
}

void ShowTrashErrorAlert(PanelController *_target, NSString *_message, NSString *_informative)
{
    NSAlert *const alert = [NSAlert new];
    alert.messageText = _message;
    if( _informative != nil )
        alert.informativeText = _informative;
    [alert addButtonWithTitle:TrashLocalizedText(@"OK")];
    [alert beginSheetModalForWindow:_target.window completionHandler:nil];
}

void ShowTrashAccessDeniedAlert(PanelController *_target)
{
    NSAlert *const alert = [NSAlert new];
    alert.messageText = TrashLocalizedText(@"Nimble Commander-Fork needs Full Disk Access to work with the Trash.");
    alert.informativeText =
        TrashLocalizedText(@"Grant access in System Settings → Privacy & Security → Full Disk Access and try again.");
    [alert addButtonWithTitle:TrashLocalizedText(@"Open System Settings")];
    [alert addButtonWithTitle:TrashLocalizedText(@"Cancel")];
    [alert beginSheetModalForWindow:_target.window
                  completionHandler:^(NSModalResponse _response) {
                    if( _response == NSAlertFirstButtonReturn )
                        OpenFullDiskAccessSettings();
                  }];
}

bool EnsureTrashIsAccessible(PanelController *_target, const std::string &_directory)
{
    int error = 0;
    nc::routedio::ListTrashDirectory(_directory, error);
    if( error == 0 )
        return true;
    if( error == EPERM || error == EACCES )
        ShowTrashAccessDeniedAlert(_target);
    else
        ShowTrashErrorAlert(_target, TrashLocalizedText(@"Failed to access the Trash."), nil);
    return false;
}

std::string WithoutTrailingSlash(std::string _path)
{
    while( _path.size() > 1 && _path.back() == '/' )
        _path.pop_back();
    return _path;
}

} // namespace

void GoToTrash::Perform(PanelController *_target, id /*_sender*/) const
{
    // Prefer the trash of the volume that the panel is currently on, so that items deleted from
    // an external drive can be reached from there. Fall back to the boot volume's trash.
    std::string trash = nc::routedio::TrashForVolumeOf(WithoutTrailingSlash(_target.currentDirectoryPath));
    if( trash.empty() )
        trash = nc::routedio::TrashDirectory();

    if( !EnsureTrashIsAccessible(_target, trash) )
        return;

    const auto request = std::make_shared<DirectoryChangeRequest>();
    request->RequestedDirectory = trash;
    request->VFS = nc::bootstrap::NativeVFSHostInstance().SharedPtr();
    request->PerformAsynchronous = true;
    request->InitiatedByUser = true;
    [_target GoToDirWithContext:request];
}

bool PutBack::Predicate(PanelController *_target) const
{
    if( _target.vfs == nullptr || !_target.vfs->IsNativeFS() )
        return false;
    const std::string directory = WithoutTrailingSlash(_target.currentDirectoryPath);
    if( !nc::routedio::IsTrashDirectory(directory) && !nc::routedio::IsInsideTrash(directory) )
        return false;
    return !_target.selectedEntriesOrFocusedEntry.empty();
}

void PutBack::Perform(PanelController *_target, id /*_sender*/) const
{
    std::vector<std::string> paths;
    for( const VFSListingItem &item : _target.selectedEntriesOrFocusedEntry )
        if( item.Host()->IsNativeFS() )
            paths.emplace_back(item.Path());
    if( paths.empty() )
        return;

    // A put-back across volumes copies the whole tree, so it must not run on the main thread. The
    // sheet below shows the progress and offers to cancel; same-volume restores are a single rename
    // and finish long before the sheet would appear.
    auto cancelled = std::make_shared<std::atomic_bool>(false);
    auto finished = std::make_shared<std::atomic_bool>(false);

    NSAlert *const progress = [NSAlert new];
    progress.messageText = TrashLocalizedText(@"Restoring items…");
    progress.informativeText = TrashLocalizedText(@"The items are being moved back to their original locations.");
    NSProgressIndicator *const spinner = [[NSProgressIndicator alloc] init];
    spinner.style = NSProgressIndicatorStyleSpinning;
    spinner.indeterminate = YES;
    spinner.controlSize = NSControlSizeSmall;
    spinner.frame = NSMakeRect(0, 0, 24, 24);
    [spinner startAnimation:nil];
    progress.accessoryView = spinner;
    [progress addButtonWithTitle:TrashLocalizedText(@"Cancel")];

    __weak PanelController *weak_target = _target;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
      PanelController *const target = weak_target;
      if( target == nil || finished->load() )
          return;
      [progress beginSheetModalForWindow:target.window
                       completionHandler:^(NSModalResponse _response) {
                         // The work closes the sheet once it stops - pressing Cancel only raises the
                         // flag, otherwise the window would be gone while the copy is still running.
                         if( _response == NSAlertFirstButtonReturn )
                             cancelled->store(true);
                       }];
    });

    dispatch_to_default([paths = std::move(paths), cancelled, finished, weak_target, progress] {
        int failures = 0;
        int leftovers = 0;
        bool was_cancelled = false;
        for( const std::string &path : paths ) {
            if( cancelled->load() ) {
                was_cancelled = true;
                break;
            }
            const nc::routedio::PutBackResult outcome =
                nc::routedio::PutBackTrashedItem(path, [&cancelled] { return cancelled->load(); });
            if( outcome.error == ECANCELED ) {
                was_cancelled = true;
                break;
            }
            if( !outcome.restored )
                ++failures;
            else if( outcome.source_remains )
                ++leftovers;
        }
        finished->store(true);
        dispatch_to_main_queue([weak_target, progress, failures, leftovers, was_cancelled] {
            if( progress.window.sheetParent != nil )
                [progress.window.sheetParent endSheet:progress.window];
            PanelController *const target = weak_target;
            if( target == nil )
                return;
            [target hintAboutFilesystemChange];
            if( was_cancelled && failures == 0 && leftovers == 0 ) {
                NSAlert *const alert = [[NSAlert alloc] init];
                alert.messageText = TrashLocalizedText(@"The put back was cancelled.");
                [alert addButtonWithTitle:TrashLocalizedText(@"OK")];
                [alert beginSheetModalForWindow:target.window completionHandler:nil];
                return;
            }
            if( failures > 0 ) {
                NSAlert *const alert = [[NSAlert alloc] init];
                alert.messageText = failures == 1 ? TrashLocalizedText(@"Failed to put back an item.")
                                                  : TrashLocalizedText(@"Failed to put back some of the items.");
                [alert addButtonWithTitle:TrashLocalizedText(@"OK")];
                [alert beginSheetModalForWindow:target.window completionHandler:nil];
            }
            else if( leftovers > 0 ) {
                NSAlert *const alert = [[NSAlert alloc] init];
                alert.messageText =
                    leftovers == 1
                        ? TrashLocalizedText(@"The item was restored, but the copy in the Trash couldn't be removed.")
                        : TrashLocalizedText(
                              @"Some items were restored, but the copies in the Trash couldn't be removed.");
                [alert addButtonWithTitle:TrashLocalizedText(@"OK")];
                [alert beginSheetModalForWindow:target.window completionHandler:nil];
            }
        });
    });
}

} // namespace nc::panel::actions
