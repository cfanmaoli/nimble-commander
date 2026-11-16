// Copyright (C) 2026 Michael Kazakov. Subject to GNU General Public License version 3.
#pragma once

#include <VFS/VFSDeclarations.h>
#include <VFS/VFSFactory.h>
#include <optional>
#include <string>
#include <string_view>

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

// The tag the read-only RAR VFS is registered under, used when persisting panel state.
[[nodiscard]] std::string_view RarHelperHostTag() noexcept;

// The metadata of that VFS, for VFSFactory::RegisterVFS().
[[nodiscard]] VFSMeta RarHelperHostMeta();

// Creates a read-only VFS over the RAR archive at '_path'. Throws nc::ErrorException when the
// archive can't be opened - e.g. when the optional component is disabled or the archive needs a
// password (which is never persisted). Used to restore persisted panel state.
[[nodiscard]] VFSHostPtr
CreateRarHelperHost(std::string_view _path, const VFSHostPtr &_parent, VFSCancelChecker _cancel_checker = {});

} // namespace nc::vfs::rar
