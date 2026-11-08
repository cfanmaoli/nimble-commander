// Copyright (C) 2025 Michael Kazakov. Subject to GNU General Public License version 3.
#pragma once

#include <Cocoa/Cocoa.h>
#include <VFS/VFS.h>
#include <Panel/PanelDataItemVolatileData.h>
#include "Layout.h"

@class NCPanelGalleryView;
@class NCPanelViewFieldEditor;

@interface NCPanelGalleryCollectionViewItem : NSCollectionViewItem

@property(nonatomic) VFSListingItem item;

// Index of this item within the collection view, i.e. its sorted index.
// -1 denotes invalid index.
@property(nonatomic, readonly) int itemIndex;

@property(nonatomic) nc::panel::data::ItemVolatileData vd;

// The highlighted segments during a quick search, kept next to (not inside) the volatile data.
@property(nonatomic) nc::panel::data::QuickSearchHighlight qsHighlight;

@property(nonatomic) nc::panel::gallery::ItemLayout itemLayout;

@property(nonatomic) bool panelActive;

@property(nonatomic) NSImage *icon;

@property(nonatomic, readonly) NCPanelGalleryView *galleryView;

- (void)setupFieldEditor:(NCPanelViewFieldEditor *)_editor;

@end
