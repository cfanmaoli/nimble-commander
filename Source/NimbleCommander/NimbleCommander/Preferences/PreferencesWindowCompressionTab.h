// Copyright (C) 2026 Michael Kazakov. Subject to GNU General Public License version 3.
#pragma once

#include <Cocoa/Cocoa.h>
#include <swiftToCxx/_SwiftCxxInteroperability.h>
#include <NimbleCommanderCommon-Swift.h>

@interface PreferencesWindowCompressionTab : NSViewController <PreferencesViewControllerProtocol>

- (instancetype)init;

@end
