// Copyright (C) 2018 Michael Kazakov. Subject to GNU General Public License version 3.
#include <VFSIcon/IconBuilder.h>

namespace nc::vfsicon {

void IconBuilder::BuildRealIconAsync(const VFSListingItem &_item,
                                     int _icon_px_size,
                                     BuildCallback _callback,
                                     const CancelChecker &_cancel_checker)
{
    if( !_callback )
        return;
    _callback(BuildRealIcon(_item, _icon_px_size, _cancel_checker));
}

} // namespace nc::vfsicon
