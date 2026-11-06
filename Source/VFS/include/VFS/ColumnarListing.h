// Copyright (C) 2026 Michael Kazakov. Subject to GNU General Public License version 3.
#pragma once

#include "VFSDeclarations.h"
#include <cstddef>
#include <string>

namespace nc::vfs {

// The result of a columnar enumeration of a directory tree: one listing built directly from the
// entries, without a listing per intermediate directory.
struct ColumnarListingResult {
    VFSListingPtr listing;
    size_t items = 0;
    size_t directories = 0;
    bool truncated = false;
};

// Walks the tree under _root and builds a single flat listing out of everything it finds. The
// directories of each level are enumerated in parallel by _threads workers through the native
// backend's bulk attribute fetching; the entries go straight into one ListingInput.
// Only the native filesystem is covered - the caller picks the composed path for anything else.
ColumnarListingResult BuildColumnarListing(const VFSHostPtr &_host,
                                           const std::string &_root,
                                           unsigned long _fetch_flags,
                                           const VFSCancelChecker &_cancel_checker,
                                           size_t _max_items,
                                           size_t _max_directories,
                                           size_t _threads);

} // namespace nc::vfs
