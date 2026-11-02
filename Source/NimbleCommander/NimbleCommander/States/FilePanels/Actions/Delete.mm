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
#include <filesystem>

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

bool EmptyTrash::Predicate(PanelController * /*_target*/) const
{
    return true;
}

void EmptyTrash::Perform(PanelController *_target, id /*_sender*/) const
{
    // Like the Finder, empty the trashes of all mounted volumes, not just the boot one.
    std::vector<std::string> items;
    int first_error = 0;
    for( const std::string &location : nc::routedio::TrashLocations() ) {
        int error = 0;
        std::vector<std::string> children = nc::routedio::ListTrashDirectory(location, error);
        if( error != 0 ) {
            if( first_error == 0 )
                first_error = error;
            continue;
        }
        items.insert(items.end(), children.begin(), children.end());
    }
    if( first_error != 0 && items.empty() ) {
        if( first_error == EPERM || first_error == EACCES )
            ShowTrashAccessDeniedAlert(_target);
        else
            ShowTrashErrorAlert(_target, TrashLocalizedText(@"Failed to access the Trash."), nil);
        return;
    }
    if( items.empty() ) {
        ShowTrashErrorAlert(_target, TrashLocalizedText(@"The Trash is empty."), nil);
        return;
    }

    NSAlert *const alert = [NSAlert new];
    alert.alertStyle = NSAlertStyleCritical;
    alert.messageText = TrashLocalizedText(@"Are you sure you want to permanently delete all items in the Trash?");
    [alert addButtonWithTitle:TrashLocalizedText(@"Empty Trash")];
    [alert addButtonWithTitle:TrashLocalizedText(@"Cancel")];
    __weak PanelController *weak_target = _target;
    [alert beginSheetModalForWindow:_target.window
                  completionHandler:^(NSModalResponse _response) {
                    if( _response != NSAlertFirstButtonReturn )
                        return;
                    // Obj-C blocks capture 'items' as a const copy, so moving it out is pointless.
                    dispatch_to_default([paths = items, weak_target] {
                        int failures = 0;
                        for( const std::string &path : paths ) {
                            std::error_code ec;
                            std::filesystem::remove_all(path, ec);
                            if( ec )
                                ++failures;
                        }
                        dispatch_to_main_queue([failures, weak_target] {
                            PanelController *const target = weak_target;
                            if( target == nil )
                                return;
                            [target hintAboutFilesystemChange];
                            if( failures > 0 )
                                ShowTrashErrorAlert(target, TrashLocalizedText(@"Failed to empty the Trash."), nil);
                        });
                    });
                  }];
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
    const std::vector<VFSListingItem> items = _target.selectedEntriesOrFocusedEntry;
    int failures = 0;
    for( const VFSListingItem &item : items ) {
        if( !item.Host()->IsNativeFS() )
            continue;
        std::string resulting_path;
        if( nc::routedio::PutBackTrashedItem(item.Path(), resulting_path) != 0 )
            ++failures;
    }

    [_target hintAboutFilesystemChange];

    if( failures > 0 ) {
        NSAlert *const alert = [NSAlert new];
        alert.messageText = failures == 1 ? TrashLocalizedText(@"Failed to put back an item.")
                                          : TrashLocalizedText(@"Failed to put back some of the items.");
        [alert addButtonWithTitle:TrashLocalizedText(@"OK")];
        [alert beginSheetModalForWindow:_target.window completionHandler:nil];
    }
}

} // namespace nc::panel::actions
