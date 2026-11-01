// Copyright (C) 2021-2026 Michael Kazakov. Subject to GNU General Public License version 3.

#pragma once

#include <optional>
#include <string>
#include <vector>

namespace nc::routedio {

int TrashItemAtPath(const char *_path) noexcept;

// Absolute path of the user's Trash folder, e.g. '/Users/john/.Trash'.
std::string TrashDirectory();

// Checks whether the path denotes the trash folder itself.
bool IsTrashDirectory(const std::string &_path);

// Checks whether the path is located inside the trash folder.
bool IsInsideTrash(const std::string &_path);

// Lists the immediate children of the trash folder. Returns an empty vector and stores an error
// code in '_error' when the folder can't be read - e.g. when the process doesn't have the Full
// Disk Access permission.
std::vector<std::string> ListTrash(int &_error);

// Returns the original location of a trashed item, if it is known. The location is either
// recorded by us when moving an item to the trash, or read from the .DS_Store of the trash
// folder, which is maintained by the Finder.
std::optional<std::string> OriginalLocationOfTrashedItem(const std::string &_trash_item_path);

// Reads the put-back location of an item from a .DS_Store file. Exposed mainly for testing.
std::optional<std::string> OriginalLocationFromDsStore(const std::string &_ds_store_path, const std::string &_filename);

// Moves a trashed item back to its original location, creating missing parent folders along the
// way. Returns 0 on success or a POSIX error code, and fills '_resulting_path' with the final
// location of the item.
int PutBackTrashedItem(const std::string &_trash_item_path, std::string &_resulting_path);

// Records the original location of an item that is about to be moved to the trash. The value is
// stored in an extended attribute, which survives the move.
void RememberOriginalLocation(const std::string &_path);

} // namespace nc::routedio
