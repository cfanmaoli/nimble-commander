// Copyright (C) 2017-2024 Michael Kazakov. Subject to GNU General Public License version 3.
#include "Interactions.h"
#include <Base/CommonPaths.h>
#include <NimbleCommander/Core/Alert.h>
#include <RoutedIO/RoutedIO.h>
#include <Utility/StringExtras.h>

namespace nc::bootstrap {

bool AskUserToResetDefaults()
{
    const auto msg = NSLocalizedString(@"Are you sure you want to reset settings to defaults?",
                                       "Asking user for confirmation on erasing custom settings - message");
    const auto info = NSLocalizedString(@"This will erase all your custom settings.",
                                        "Asking user for confirmation on erasing custom settings - informative text");

    Alert *const alert = [[Alert alloc] init];
    alert.messageText = msg;
    alert.informativeText = info;
    [alert addButtonWithTitle:NSLocalizedString(@"OK", "")];
    [alert addButtonWithTitle:NSLocalizedString(@"Cancel", "")];
    [alert.buttons objectAtIndex:0].keyEquivalent = @"";
    return [alert runModal] == NSAlertFirstButtonReturn;
}

bool AskToExitWithRunningOperations()
{
    const auto msg =
        NSLocalizedString(@"The application has running operations. Do you want to stop all operations and quit?",
                          "Asking user for quitting app with activity");

    Alert *const alert = [[Alert alloc] init];
    alert.messageText = msg;
    [alert addButtonWithTitle:NSLocalizedString(@"Stop and Quit",
                                                "Asking user for quitting app with activity - confirmation")];
    [alert addButtonWithTitle:NSLocalizedString(@"Cancel", "")];
    const NSInteger result = [alert runModal];

    return result == NSAlertFirstButtonReturn;
}

void WarnAboutFailingToAccessPrivilegedHelper()
{
    const auto msg = NSLocalizedString(@"Failed to access the privileged helper.",
                                       "Information that toggling admin mode on has failed");

    Alert *const alert = [[Alert alloc] init];
    alert.messageText = msg;
    [alert addButtonWithTitle:NSLocalizedString(@"OK", "")];
    [alert runModal];
}

void InformAboutPrivilegedHelperApprovalRequired()
{
    const auto msg = NSLocalizedString(@"Approval Required for Admin Mode",
                                       "Alert title when SMAppService privileged daemon requires approval");
    const auto info = NSLocalizedString(
        @"Enable Nimble Commander-Fork in System Settings \u2192 General \u2192 Login Items & Extensions, then turn "
        @"Admin Mode on again.",
        "Alert text explaining how to approve the privileged helper daemon in System Settings");

    Alert *const alert = [[Alert alloc] init];
    alert.messageText = msg;
    alert.informativeText = info;
    [alert addButtonWithTitle:NSLocalizedString(@"Open System Settings",
                                                "Button to open System Settings Login Items for daemon approval")];
    [alert addButtonWithTitle:NSLocalizedString(@"Cancel", "")];
    if( [alert runModal] == NSAlertFirstButtonReturn )
        nc::routedio::RoutedIO::OpenSystemSettingsLoginItems();
}

} // namespace nc::bootstrap
