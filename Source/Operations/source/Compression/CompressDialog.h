// Copyright (C) 2019 Michael Kazakov. Subject to GNU General Public License version 3.
#pragma once

#include <Cocoa/Cocoa.h>
#include <VFS/VFS.h>

@interface NCOpsCompressDialog : NSWindowController <NSTextFieldDelegate>

// '_allows_password' is false when the configured archive format can't encrypt its payload (only
// the zip container can) - the dialog then disables the password controls instead of silently
// dropping the password when the operation starts.
- (instancetype)initWithItems:(const std::vector<VFSListingItem> &)_source_items
               destinationVFS:(const VFSHostPtr &)_destination_host
           initialDestination:(const std::string &)_initial_destination
               allowsPassword:(bool)_allows_password;

@property(readonly, nonatomic) const std::string &destination;
@property(readonly, nonatomic) const std::string &password;

@end
