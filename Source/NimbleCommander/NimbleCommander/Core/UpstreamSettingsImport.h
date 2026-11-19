// Copyright (C) 2026 cfanmaoli. Subject to GNU General Public License version 3.
#pragma once

#include <filesystem>
#include <optional>
#include <string>
#include <vector>

// Support for migrating settings from the original Nimble Commander app, whose support directory is
// "~/Library/Application Support/Nimble Commander" (the fork uses ".../Nimble Commander-Fork").
//
// The running app cannot copy the files directly into its own Config/State directories: the old
// process commits its in-memory defaults on termination and would overwrite them. Instead the data
// is staged next to them and applied by the next launch *before* the config objects are created.
namespace nc::upstream {

struct ImportPlan {
    std::filesystem::path source_root;
    std::vector<std::filesystem::path> relative_paths;
};

// Locates the original app's settings (non-sandboxed and App Store container locations).
std::optional<ImportPlan> Discover(const std::filesystem::path &_fork_support_dir);
std::optional<ImportPlan> DiscoverIn(const std::filesystem::path &_home,
                                     const std::filesystem::path &_fork_support_dir);

bool HasPendingImport(const std::filesystem::path &_fork_support_dir);
// Validates the JSON files and copies them below <fork_support>/.pending-upstream-import.
bool StagePendingImport(const ImportPlan &_plan, const std::filesystem::path &_fork_support_dir, std::string &_error);
// Applies a staged import. Must be called before the Config/State objects are created.
bool ApplyPendingImport(const std::filesystem::path &_fork_support_dir, std::string &_error);

bool ShouldOfferImport(const std::filesystem::path &_fork_support_dir);
bool ShouldOfferImportIn(const std::filesystem::path &_home, const std::filesystem::path &_fork_support_dir);
// Records that the first-launch question was answered, so it is not asked again; the menu item
// stays available for a later import.
void MarkImportOffered(const std::filesystem::path &_fork_support_dir);

// AppKit entry points. The first one shows the question only on a fresh install; the second one is
// the menu action and always asks before touching anything.
void OfferImportOnFirstLaunch(const std::filesystem::path &_fork_support_dir);
void PromptToImport(const std::filesystem::path &_fork_support_dir);

} // namespace nc::upstream
