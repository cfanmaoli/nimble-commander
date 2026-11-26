// Copyright (C) 2026 cfanmaoli. Subject to GNU General Public License version 3.
#include "UpstreamSettingsImport.h"
#include "LanguagePack.h"

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

#include <algorithm>
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <array>
#include <cstdint>
#include <ctime>
#include <fstream>
#include <string_view>
#include <string>
#include <system_error>
#include <unistd.h>
#include <utility>
#include <vector>

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

struct ImportFile {
    fs::path relative;
    fs::path destination;
    fs::path temporary;
    fs::path backup;
    bool had_destination = false;
    bool committed = false;
};

bool IsImportableRelativePath(const fs::path &_relative)
{
    if( _relative.empty() || _relative.is_absolute() )
        return false;
    for( const auto &part : _relative )
        if( part == ".." || part == "." )
            return false;

    const std::string relative = _relative.generic_string();
    for( const std::string_view root : kImportableRelativePaths ) {
        if( relative == root )
            return true;
        if( relative.size() > root.size() && relative.starts_with(root) && relative[root.size()] == '/' )
            return true;
    }
    return false;
}

fs::path MakeSiblingPath(const fs::path &_path, std::string_view _tag)
{
    for( int attempt = 0;; ++attempt ) {
        fs::path candidate = _path;
        candidate += "."s;
        candidate += std::string(_tag);
        if( attempt != 0 )
            candidate += "." + std::to_string(attempt);

        std::error_code ec;
        if( !fs::exists(candidate, ec) )
            return candidate;
    }
}

bool SyncFile(const fs::path &_path, std::string &_error)
{
    const int fd = ::open(_path.c_str(), O_RDONLY);
    if( fd < 0 ) {
        _error = "unable to open "s + _path.string() + " for syncing";
        return false;
    }
    const int sync_rc = ::fsync(fd);
    const int saved_errno = errno;
    ::close(fd);
    if( sync_rc != 0 ) {
        _error = "unable to flush "s + _path.string() + ": " + std::strerror(saved_errno);
        return false;
    }
    return true;
}

void SyncDirectory(const fs::path &_directory)
{
    const int fd = ::open(_directory.c_str(), O_RDONLY);
    if( fd < 0 )
        return;
    std::ignore = ::fsync(fd);
    ::close(fd);
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

    std::vector<fs::path> relatives;
    for( fs::recursive_directory_iterator it(pending, fs::directory_options::skip_permission_denied, ec), end;
         !ec && it != end;
         it.increment(ec) ) {
        if( !it->is_regular_file(ec) || it->is_symlink(ec) )
            continue;
        const fs::path relative = fs::relative(it->path(), pending, ec);
        if( ec ) {
            _error = "unable to inspect the staged settings";
            return false;
        }
        if( !IsImportableRelativePath(relative) ) {
            _error = "unexpected file "s + relative.generic_string();
            return false;
        }
        relatives.push_back(relative);
    }
    if( ec ) {
        _error = "unable to read the staged settings";
        return false;
    }
    if( relatives.empty() )
        return true;

    const std::string stamp = std::to_string(std::time(nullptr));
    std::uintmax_t total_size = 0;
    std::vector<ImportFile> files;
    files.reserve(relatives.size());

    const auto cleanup_temporary_files = [&files] {
        for( const ImportFile &file : files ) {
            std::error_code ignored;
            if( !file.temporary.empty() )
                fs::remove(file.temporary, ignored);
        }
    };
    const auto cleanup_backups = [&files] {
        for( const ImportFile &file : files ) {
            std::error_code ignored;
            if( !file.backup.empty() )
                fs::remove(file.backup, ignored);
        }
    };

    for( size_t index = 0; index != relatives.size(); ++index ) {
        const fs::path &relative = relatives[index];
        const fs::path source = pending / relative;
        if( IsJSONConfig(relative.generic_string()) && !ValidateJSONFile(source, _error) ) {
            cleanup_temporary_files();
            return false;
        }

        const auto size = fs::file_size(source, ec);
        if( ec ) {
            _error = "unable to read "s + source.string();
            cleanup_temporary_files();
            return false;
        }
        total_size += size;
        if( total_size > kMaxImportSize ) {
            _error = "the settings are too large to import";
            cleanup_temporary_files();
            return false;
        }

        const fs::path destination = _fork_support_directory / relative;
        if( fs::is_directory(destination, ec) ) {
            _error = "unable to replace the directory "s + destination.string();
            cleanup_temporary_files();
            return false;
        }
        ec.clear();
        fs::create_directories(destination.parent_path(), ec);
        if( ec ) {
            _error = "unable to create "s + destination.parent_path().string();
            cleanup_temporary_files();
            return false;
        }

        ImportFile file;
        file.relative = relative;
        file.destination = destination;
        file.temporary = MakeSiblingPath(destination, "upstream-import-" + stamp + "-" + std::to_string(index));
        files.push_back(file);

        fs::copy_file(source, file.temporary, fs::copy_options::overwrite_existing, ec);
        if( ec ) {
            _error = "unable to stage "s + destination.string();
            cleanup_temporary_files();
            return false;
        }
        if( !SyncFile(file.temporary, _error) ) {
            cleanup_temporary_files();
            return false;
        }
    }

    // Back up all original files before touching any destination.
    for( size_t index = 0; index != files.size(); ++index ) {
        ImportFile &file = files[index];
        if( !fs::exists(file.destination, ec) ) {
            ec.clear();
            continue;
        }
        if( fs::is_directory(file.destination, ec) ) {
            _error = "unable to replace the directory "s + file.destination.string();
            cleanup_temporary_files();
            cleanup_backups();
            return false;
        }
        file.had_destination = true;
        file.backup = MakeSiblingPath(file.destination, "pre-upstream-import-" + stamp + "-" + std::to_string(index));
        fs::copy_file(file.destination, file.backup, fs::copy_options::overwrite_existing, ec);
        if( ec ) {
            _error = "unable to back up "s + file.destination.string();
            cleanup_temporary_files();
            cleanup_backups();
            return false;
        }
    }

    // Commit with rename; if any rename fails, restore every already-replaced destination.
    for( ImportFile &file : files ) {
        std::error_code rename_ec;
        fs::rename(file.temporary, file.destination, rename_ec);
        if( rename_ec ) {
            _error = "unable to write "s + file.destination.string();
            for( auto it = files.rbegin(); it != files.rend(); ++it ) {
                ImportFile &rollback = *it;
                if( rollback.committed ) {
                    std::error_code restore_ec;
                    if( rollback.had_destination ) {
                        fs::rename(rollback.backup, rollback.destination, restore_ec);
                        if( restore_ec ) {
                            restore_ec.clear();
                            std::error_code copy_ec;
                            fs::copy_file(
                                rollback.backup, rollback.destination, fs::copy_options::overwrite_existing, copy_ec);
                        }
                    }
                    else {
                        std::error_code remove_ec;
                        fs::remove(rollback.destination, remove_ec);
                    }
                }
                else {
                    std::error_code remove_ec;
                    fs::remove(rollback.temporary, remove_ec);
                }
            }
            cleanup_backups();
            return false;
        }
        file.committed = true;
        SyncDirectory(file.destination.parent_path());
    }

    fs::remove_all(pending, ec);
    if( ec ) {
        _error = "unable to remove the staged settings";
        return false;
    }
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
