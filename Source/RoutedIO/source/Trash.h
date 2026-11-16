// Copyright (C) 2021 Michael Kazakov. Subject to GNU General Public License version 3.

#pragma once

#include <string>

namespace nc::routedio::detail {

// Removes a staging copy created by a cross-volume put-back: restores owner write access on every
// directory inside it and then deletes the tree. Returns 0, or the errno when the staging entry
// still couldn't be removed. Exposed mainly for testing.
int RemoveStagingTree(const std::string &_staging) noexcept;

// The extended attribute that records where an item came from. Exposed for testing.
extern const char *const kOriginalLocationAttribute;

} // namespace nc::routedio::detail
