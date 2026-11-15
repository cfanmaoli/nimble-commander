// Copyright (C) 2026 Michael Kazakov. Subject to GNU General Public License version 3.
#pragma once

#include <optional>
#include <string>

namespace nc::vfs::rar {

// Controls the optional RAR support component (ncrar-helper.app). While disabled the helper is
// never looked up, so FindHelper() doesn't touch the filesystem at all. The lookup result is
// cached for the whole enable/disable cycle: it is performed at most once after every transition.
void SetHelperEnabled(bool _enabled) noexcept;

// Returns whether the RAR support component is allowed to be used.
[[nodiscard]] bool IsHelperEnabled() noexcept;

// Returns the path of the installed helper executable, or nullopt when the component is disabled
// or not installed. Uses the cached lookup; it never triggers a new filesystem search beyond the
// one already performed for the current enable/disable cycle.
[[nodiscard]] std::optional<std::string> HelperPath();

} // namespace nc::vfs::rar
