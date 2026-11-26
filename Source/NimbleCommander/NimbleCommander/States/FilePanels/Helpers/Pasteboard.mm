// Copyright (C) 2017-2026 Michael Kazakov. Subject to GNU General Public License version 3.
#include "Pasteboard.h"
#include <VFS/VFS.h>
#include <Utility/StringExtras.h>

namespace nc::panel {

bool PasteboardSupport::WriteURLSPBoard(const std::vector<VFSListingItem> &_items, NSPasteboard *_pasteboard)
{
    if( !_pasteboard )
        return false;

    const auto urls = [[NSMutableArray alloc] initWithCapacity:_items.size()];
    for( auto &i : _items )
        if( i.Host()->IsNativeFS() )
            if( const auto path = [NSString stringWithUTF8StdString:i.Path()] )
                if( const auto url = [NSURL fileURLWithPath:path] )
                    [urls addObject:url];

    if( urls.count == 0 )
        return false;

    [_pasteboard clearContents];
    return [_pasteboard writeObjects:urls];
}

} // namespace nc::panel
