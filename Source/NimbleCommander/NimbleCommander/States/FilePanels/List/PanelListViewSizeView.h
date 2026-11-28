// Copyright (C) 2016-2020 Michael Kazakov. Subject to GNU General Public License version 3.
#pragma once

#include <Cocoa/Cocoa.h>
#include <Panel/PanelDataItemVolatileData.h>

@interface PanelListViewSizeView : NSView

// 2.1.28: biggest regular file in the listing, used as the scale of the proportion bar.
// zero disables the bar.
@property(nonatomic) uint64_t sizeScaleMax;

- (void)buildPresentation;

// PanelListViewSizeView has no right to store listing item and hold a reference to it!
- (void)setSizeWithItem:(const VFSListingItem &)_dirent andVD:(const nc::panel::data::ItemVolatileData &)_vd;

@end
