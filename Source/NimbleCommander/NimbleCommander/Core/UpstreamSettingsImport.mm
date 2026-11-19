// Copyright (C) 2026 cfanmaoli. Subject to GNU General Public License version 3.
#include "UpstreamSettingsImport.h"
#include "LanguagePack.h"

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

#include <algorithm>
#include <array>
#include <cstdint>
#include <ctime>
#include <fstream>
#include <string_view>
#include <system_error>

namespace {

using namespace std::string_literals;
namespace fs = std::filesystem;

constexpr auto kPendingDirectoryName = ".pending-upstream-import";
constexpr auto kOriginalSupportDirectoryName = "Nimble Commander";
constexpr auto kMASContainerSuffix = "Library/Containers/info.filesmanager.Files/Data/Library/Application Support";
constexpr std::uintmax_t kMaxJSONFileSize = 64ull * 1024 * 1024;
constexpr std::uintmax_t kMaxImportSize = 512ull * 1024 * 1024;

constexpr std::array<std::string_view, 5> kImportableRelativePaths = {
    "Config/Config.json",
    "Config/NetworkConnections.json",
    "State/State.json",
    "LanguagePacks",
    "SyntaxHighlighting",
};

bool IsJSONConfig(std::string_view _relative_path)
{
    return _relative_path == "Config/Config.json" || _relative_path == "Config/NetworkConnections.json" ||
           _relative_path == "State/State.json";
}

NSString *FromPath(const fs::path &_path)
{
    const std::string s = _path.string();
    return [NSString stringWithUTF8String:s.c_str()] ?: @"";
}

bool ValidateJSONFile(const fs::path &_path, std::string &_error)
{
    std::error_code ec;
    const auto size = fs::file_size(_path, ec);
    if( ec ) {
        _error = "unable to read "s + _path.filename().string();
        return false;
    }
    if( size > kMaxJSONFileSize ) {
        _error = _path.filename().string() + " is too large to be a settings file";
        return false;
    }
    NSData *const data = [NSData dataWithContentsOfFile:FromPath(_path)];
    if( data.length == 0 ) {
        _error = "unable to read "s + _path.filename().string();
        return false;
    }
    const id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if( ![root isKindOfClass:NSDictionary.class] ) {
        _error = _path.filename().string() + " is not a valid settings file";
        return false;
    }
    return true;
}

bool CopyTree(const fs::path &_source, const fs::path &_destination, std::uintmax_t &_total, std::string &_error)
{
    std::error_code ec;
    for( fs::recursive_directory_iterator it(_source, fs::directory_options::skip_permission_denied, ec), end;
         !ec && it != end;
         it.increment(ec) ) {
        const fs::path &source_path = it->path();
        if( it->is_symlink(ec) || ec )
            continue;
        const fs::path relative = fs::relative(source_path, _source, ec);
        if( ec ) {
            _error = "unable to inspect "s + _source.string();
            return false;
        }
        const fs::path destination_path = _destination / relative;
        if( it->is_directory(ec) ) {
            fs::create_directories(destination_path, ec);
            if( ec ) {
                _error = "unable to create "s + destination_path.string();
                return false;
            }
        }
        else if( it->is_regular_file(ec) ) {
            const auto size = it->file_size(ec);
            if( ec ) {
                _error = "unable to read "s + source_path.string();
                return false;
            }
            _total += size;
            if( _total > kMaxImportSize ) {
                _error = "the settings are too large to import";
                return false;
            }
            fs::create_directories(destination_path.parent_path(), ec);
            if( ec ) {
                _error = "unable to create "s + destination_path.parent_path().string();
                return false;
            }
            fs::copy_file(source_path, destination_path, fs::copy_options::overwrite_existing, ec);
            if( ec ) {
                _error = "unable to copy "s + source_path.string();
                return false;
            }
        }
    }
    if( ec ) {
        _error = "unable to read "s + _source.string();
        return false;
    }
    return true;
}

void ScheduleRelaunch(const nc::upstream::ImportPlan &_plan, const fs::path &_fork_support_directory)
{
    std::string error;
    if( !nc::upstream::StagePendingImport(_plan, _fork_support_directory, error) ) {
        NSAlert *const alert = [[NSAlert alloc] init];
        alert.alertStyle = NSAlertStyleWarning;
        alert.messageText =
            NSLocalizedString(@"Couldn't import the settings",
                              "Alert title when importing settings from the original Nimble Commander app failed");
        alert.informativeText = [NSString stringWithFormat:@"%@", [NSString stringWithUTF8String:error.c_str()]];
        [alert addButtonWithTitle:NSLocalizedString(@"OK", "Generic OK button")];
        [alert runModal];
        return;
    }
    nc::lang::RelaunchApplication();
}

bool HasCoreSettings(const fs::path &_root)
{
    std::error_code ec;
    return fs::exists(_root / "Config/Config.json", ec) || fs::exists(_root / "State/State.json", ec);
}

} // namespace

namespace nc::upstream {

std::optional<ImportPlan> DiscoverIn(const fs::path &_home, const fs::path &_fork_support_directory)
{
    std::error_code ec;
    const fs::path candidates[] = {
        _home / "Library/Application Support" / kOriginalSupportDirectoryName,
        _home / kMASContainerSuffix / kOriginalSupportDirectoryName,
    };

    for( const fs::path &candidate : candidates ) {
        if( !fs::is_directory(candidate, ec) || ec )
            continue;
        if( fs::equivalent(candidate, _fork_support_directory, ec) )
            continue;
        ec.clear();
        if( !HasCoreSettings(candidate) )
            continue;

        ImportPlan plan;
        plan.source_root = candidate;
        for( std::string_view relative : kImportableRelativePaths )
            if( fs::exists(candidate / fs::path(relative), ec) )
                plan.relative_paths.emplace_back(relative);
        if( !plan.relative_paths.empty() )
            return plan;
    }
    return std::nullopt;
}

std::optional<ImportPlan> Discover(const fs::path &_fork_support_directory)
{
    NSString *const home = NSHomeDirectory();
    if( home == nil )
        return std::nullopt;
    return DiscoverIn(fs::path(home.fileSystemRepresentation), _fork_support_directory);
}

bool HasPendingImport(const fs::path &_fork_support_directory)
{
    std::error_code ec;
    return fs::is_directory(_fork_support_directory / kPendingDirectoryName, ec);
}

bool StagePendingImport(const ImportPlan &_plan, const fs::path &_fork_support_directory, std::string &_error)
{
    _error.clear();
    if( _plan.source_root.empty() ) {
        _error = "no source directory";
        return false;
    }

    std::error_code ec;
    const fs::path pending = _fork_support_directory / kPendingDirectoryName;
    fs::remove_all(pending, ec);
    fs::create_directories(pending, ec);
    if( ec ) {
        _error = "unable to create "s + pending.string();
        return false;
    }

    std::uintmax_t total_size = 0;
    for( const fs::path &relative : _plan.relative_paths ) {
        const fs::path source = _plan.source_root / relative;
        if( !fs::exists(source, ec) ) {
            ec.clear();
            continue;
        }
        const fs::path destination = pending / relative;
        if( fs::is_regular_file(source, ec) ) {
            if( !IsJSONConfig(relative.string()) ) {
                _error = "unexpected file "s + relative.string();
                fs::remove_all(pending, ec);
                return false;
            }
            if( !ValidateJSONFile(source, _error) ) {
                fs::remove_all(pending, ec);
                return false;
            }
            fs::create_directories(destination.parent_path(), ec);
            fs::copy_file(source, destination, fs::copy_options::overwrite_existing, ec);
            if( ec ) {
                _error = "unable to copy "s + source.string();
                fs::remove_all(pending, ec);
                return false;
            }
        }
        else if( fs::is_directory(source, ec) ) {
            if( !CopyTree(source, destination, total_size, _error) ) {
                fs::remove_all(pending, ec);
                return false;
            }
        }
    }

    ec.clear();
    if( fs::is_empty(pending, ec) || ec ) {
        fs::remove_all(pending, ec);
        _error = "there is nothing to import";
        return false;
    }
    return true;
}

bool ApplyPendingImport(const fs::path &_fork_support_directory, std::string &_error)
{
    _error.clear();
    std::error_code ec;
    const fs::path pending = _fork_support_directory / kPendingDirectoryName;
    if( !fs::is_directory(pending, ec) )
        return true;

    std::vector<fs::path> files;
    for( fs::recursive_directory_iterator it(pending, fs::directory_options::skip_permission_denied, ec), end;
         !ec && it != end;
         it.increment(ec) ) {
        if( it->is_regular_file(ec) && !it->is_symlink(ec) )
            files.push_back(fs::relative(it->path(), pending, ec));
    }
    if( ec ) {
        _error = "unable to read the staged settings";
        return false;
    }

    const std::string stamp = std::to_string(std::time(nullptr));
    for( const fs::path &relative : files ) {
        const fs::path source = pending / relative;
        const fs::path destination = _fork_support_directory / relative;
        if( fs::exists(destination, ec) ) {
            if( fs::is_directory(destination, ec) ) {
                _error = "unable to replace the directory "s + destination.string();
                return false;
            }
            const fs::path backup = destination.string() + ".pre-upstream-import-" + stamp;
            fs::copy_file(destination, backup, fs::copy_options::overwrite_existing, ec);
            if( ec ) {
                _error = "unable to back up "s + destination.string();
                return false;
            }
        }
        fs::create_directories(destination.parent_path(), ec);
        fs::copy_file(source, destination, fs::copy_options::overwrite_existing, ec);
        if( ec ) {
            _error = "unable to write "s + destination.string();
            return false;
        }
    }

    fs::remove_all(pending, ec);
    return true;
}

void PromptToImport(const fs::path &_fork_support_directory)
{
    const std::optional<ImportPlan> plan = Discover(_fork_support_directory);
    if( !plan ) {
        NSAlert *const alert = [[NSAlert alloc] init];
        alert.messageText = NSLocalizedString(@"No Nimble Commander settings found",
                                              "Alert title when the original app's settings cannot be located");
        alert.informativeText = NSLocalizedString(
            @"Nimble Commander-Fork looked for the settings of the original Nimble Commander app but didn't "
            @"find any.",
            "Alert text when the original app's settings cannot be located");
        [alert addButtonWithTitle:NSLocalizedString(@"OK", "Generic OK button")];
        [alert runModal];
        return;
    }

    NSAlert *const alert = [[NSAlert alloc] init];
    alert.messageText =
        NSLocalizedString(@"Import settings from Nimble Commander?",
                          "Menu action question offering to import the settings of the original Nimble Commander app");
    alert.informativeText = [NSString
        stringWithFormat:NSLocalizedString(@"Settings were found at:\n"
                                           @"%@\n\n"
                                           @"Importing replaces the current preferences and saved tabs; they are "
                                           @"backed up first. Nimble Commander-Fork then restarts.",
                                           "Settings import explanation, %@ is the source path"),
                         FromPath(plan->source_root)];
    [alert
        addButtonWithTitle:NSLocalizedString(
                               @"Import and Restart",
                               "Button that imports the settings of the original Nimble Commander app and restarts")];
    [alert addButtonWithTitle:NSLocalizedString(@"Cancel", "Generic cancel button")];
    const NSModalResponse response = [alert runModal];
    if( response == NSAlertFirstButtonReturn )
        ScheduleRelaunch(*plan, _fork_support_directory);
}

} // namespace nc::upstream
