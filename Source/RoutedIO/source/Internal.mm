// Copyright (C) 2021 Michael Kazakov. Subject to GNU General Public License version 3.
#include "Internal.h"
#include <Base/CommonPaths.h>
#include <Base/dispatch_cpp.h>
#import <ServiceManagement/ServiceManagement.h>
#include <filesystem>
#include <memory>

namespace nc::routedio {

static DaemonServiceStatus ToDaemonServiceStatus(SMAppServiceStatus _status) noexcept
{
    switch( _status ) {
        case SMAppServiceStatusNotRegistered:
            return DaemonServiceStatus::NotRegistered;
        case SMAppServiceStatusEnabled:
            return DaemonServiceStatus::Enabled;
        case SMAppServiceStatusRequiresApproval:
            return DaemonServiceStatus::RequiresApproval;
        case SMAppServiceStatusNotFound:
            return DaemonServiceStatus::NotFound;
    }
    return DaemonServiceStatus::NotFound;
}

static std::string DescribeNSError(NSError *_error) noexcept
{
    if( _error == nil )
        return {};
    NSString *const desc = [NSString stringWithFormat:@"%@ (%@:%ld)",
                                                      _error.localizedDescription ?: @"",
                                                      _error.domain ?: @"",
                                                      static_cast<long>(_error.code)];
    return desc.UTF8String != nullptr ? std::string{desc.UTF8String} : std::string{};
}

static SMAppService *DaemonService(const char *_plist_name) noexcept
{
    if( _plist_name == nullptr )
        return nil;
    NSString *const name = [NSString stringWithUTF8String:_plist_name];
    if( name == nil )
        return nil;
    return [SMAppService daemonServiceWithPlistName:name];
}

DaemonServiceStatus QueryDaemonServiceStatus(const char *_plist_name) noexcept
{
    @autoreleasepool {
        SMAppService *const service = DaemonService(_plist_name);
        if( service == nil )
            return DaemonServiceStatus::NotFound;
        return ToDaemonServiceStatus(service.status);
    }
}

DaemonServiceResult RegisterDaemonService(const char *_plist_name) noexcept
{
    @autoreleasepool {
        DaemonServiceResult result;
        SMAppService *const service = DaemonService(_plist_name);
        if( service == nil ) {
            result.error = "Invalid daemon plist name";
            return result;
        }
        NSError *error = nil;
        result.ok = [service registerAndReturnError:&error];
        result.status = ToDaemonServiceStatus(service.status);
        if( !result.ok )
            result.error = DescribeNSError(error);
        return result;
    }
}

DaemonServiceResult UnregisterDaemonService(const char *_plist_name) noexcept
{
    @autoreleasepool {
        DaemonServiceResult result;
        SMAppService *const service = DaemonService(_plist_name);
        if( service == nil ) {
            result.error = "Invalid daemon plist name";
            return result;
        }

        const dispatch_semaphore_t done = dispatch_semaphore_create(0);
        const auto callback_error = std::make_shared<std::string>();
        const auto callback_ok = std::make_shared<bool>(false);
        [service unregisterWithCompletionHandler:^(NSError *_Nullable error) {
          if( error == nil ) {
              *callback_ok = true;
          }
          else {
              *callback_error = DescribeNSError(error);
          }
          dispatch_semaphore_signal(done);
        }];

        if( dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) == 0 ) {
            result.ok = *callback_ok;
            result.error = *callback_error;
        }
        else {
            result.error = "Timed out waiting for SMAppService unregister";
        }
        result.status = ToDaemonServiceStatus(service.status);
        return result;
    }
}

void OpenSystemSettingsLoginItems() noexcept
{
    dispatch_or_run_in_main_queue([] { [SMAppService openSystemSettingsLoginItems]; });
}

NSBundle *Bundle() noexcept
{
    static NSBundle *const bundle = []() -> NSBundle * {
        const std::filesystem::path packaged = "Contents/Resources/RoutedIOResources.bundle";
        const std::filesystem::path non_packaged = "RoutedIOResources.bundle";
        const std::filesystem::path base = nc::base::CommonPaths::AppBundle();

        if( const auto path = base / packaged; std::filesystem::is_directory(path) ) {
            // packaged structure
            NSString *const ns_path = [NSString stringWithUTF8String:path.c_str()];
            return [NSBundle bundleWithPath:ns_path];
        }
        if( const auto path = base / non_packaged; std::filesystem::is_directory(path) ) {
            // non-packaged structure
            NSString *const ns_path = [NSString stringWithUTF8String:path.c_str()];
            return [NSBundle bundleWithPath:ns_path];
        }
        return nil;
    }();
    assert(bundle != nil);
    return bundle;
}

NSString *NSLocalizedString(NSString *_key, [[maybe_unused]] const char *_comment) noexcept
{
    return [Bundle() localizedStringForKey:_key value:@"" table:@"Localizable"];
}

std::string MessageAuthAsAdmin() noexcept
{
    return NSLocalizedString(@"AUTH_AS_ADMIN_PROMPT", "Prompt used when asking user to show they have admin rights")
        .UTF8String;
}

} // namespace nc::routedio
