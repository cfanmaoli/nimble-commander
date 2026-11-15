// Copyright (C) 2021-2026 Michael Kazakov. Subject to GNU General Public License version 3.

#pragma once

#include <optional>
#include <string>
#include <vector>

namespace nc::routedio {

int TrashItemAtPath(const char *_path) noexcept;

// Absolute path of the user's Trash folder on the boot volume, e.g. '/Users/john/.Trash'.
std::string TrashDirectory();

// Absolute paths of the trash folders that currently exist: the one on the boot volume and the
// per-user ones on mounted local volumes, e.g. '/Volumes/External/.Trashes/501'.
std::vector<std::string> TrashLocations();

// Returns the trash folder that contains the given path, or an empty string if there is none.
std::string TrashContaining(const std::string &_path);

// Returns the trash folder of the volume that the given path belongs to. Returns the boot
// volume's trash when the path is on the boot volume, and an empty string when the volume has
// no trash folder yet.
std::string TrashForVolumeOf(const std::string &_path);

// Checks whether the path denotes one of the trash folders.
bool IsTrashDirectory(const std::string &_path);

// Checks whether the path is located inside any of the trash folders.
bool IsInsideTrash(const std::string &_path);

// Lists the immediate children of the given trash folder. Returns an empty vector and stores an
// error code in '_error' when the folder can't be read - e.g. when the process doesn't have the
// Full Disk Access permission.
std::vector<std::string> ListTrashDirectory(const std::string &_directory, int &_error);

// Returns the original location of a trashed item, if it is known. The location is either
// recorded by us when moving an item to the trash, or read from the .DS_Store of the trash
// folder, which is maintained by the Finder.
std::optional<std::string> OriginalLocationOfTrashedItem(const std::string &_trash_item_path);

// Reads the put-back location of an item from a .DS_Store file. Exposed mainly for testing.
std::optional<std::string> OriginalLocationFromDsStore(const std::string &_ds_store_path, const std::string &_filename);

// The outcome of moving a trashed item back to its original location.
struct PutBackResult {
    // The item now lives at 'resulting_path'.
    bool restored = false;
    // The item was restored, but the copy in the Trash couldn't be removed - e.g. because the
    // folder is read-only. The user has to clean that copy up manually.
    bool source_remains = false;
    // A POSIX error code when the item couldn't be restored at all.
    int error = 0;
    // The final location of the item. When the original name is taken, a numbered one is used.
    std::string resulting_path;
};

// Moves a trashed item back to its original location, creating missing parent folders along the
// way. Never replaces an existing directory entry: a taken name gets a numbered one, and a
// filesystem that can't do an atomic non-replacing rename makes the put-back fail instead of
// risking the replacement. Restoring across volumes copies the item into a staging name next to
// the destination, preserving its data and metadata, and only then claims the name.
PutBackResult PutBackTrashedItem(const std::string &_trash_item_path);

// Records the original location of an item that is about to be moved to the trash. The value is
// stored in an extended attribute, which survives the move.
void RememberOriginalLocation(const std::string &_path);

} // namespace nc::routedio
