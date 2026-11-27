// Copyright (C) 2021 Michael Kazakov. Subject to GNU General Public License version 3.
#pragma once

#ifdef __OBJC__
#include <Cocoa/Cocoa.h>
#endif

#include <cstdint>
#include <string>

namespace nc::routedio {

#ifdef __OBJC__
NSBundle *Bundle() noexcept;

#undef NSLocalizedString
NSString *NSLocalizedString(NSString *_key, const char *_comment) noexcept;

#endif

enum class DaemonServiceStatus : uint8_t {
    NotRegistered,
    Enabled,
    RequiresApproval,
    NotFound,
};

struct DaemonServiceResult {
    bool ok = false;
    DaemonServiceStatus status = DaemonServiceStatus::NotFound;
    std::string error;
};

DaemonServiceStatus QueryDaemonServiceStatus(const char *_plist_name) noexcept;
DaemonServiceResult RegisterDaemonService(const char *_plist_name) noexcept;
DaemonServiceResult UnregisterDaemonService(const char *_plist_name) noexcept;
void OpenSystemSettingsLoginItems() noexcept;

std::string MessageAuthAsAdmin() noexcept;

} // namespace nc::routedio
