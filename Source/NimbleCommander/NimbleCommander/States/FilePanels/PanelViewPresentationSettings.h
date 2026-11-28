// Copyright (C) 2017 Michael Kazakov. Subject to GNU General Public License version 3.
#pragma once

#include <Utility/ByteCountFormatter.h>
#include "PanelViewTypes.h"

namespace nc::panel {

PanelViewFilenameTrimming GetCurrentFilenamesTrimmingMode() noexcept;
ByteCountFormatter::Type GetFileSizeFormat() noexcept;
ByteCountFormatter::Type GetSelectionSizeFormat() noexcept;

// 2.1.28: list-view polish switches, kept in NSUserDefaults so the panels preferences tab
// can flip them without going through the config machinery.
bool ListSmartDatesEnabled() noexcept;
bool ListSizeBarsEnabled() noexcept;

} // namespace nc::panel
