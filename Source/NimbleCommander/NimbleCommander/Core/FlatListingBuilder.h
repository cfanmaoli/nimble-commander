// Copyright (C) 2026 Michael Kazakov. Subject to GNU General Public License version 3.
#pragma once

#include <VFS/VFS.h>
#include <VFS/VFSDeclarations.h>

#include <cstddef>
#include <string>

namespace nc::core {

// Where the time of a flat scan went, and what it found.
struct FlatListingResult {
    VFSListingPtr listing;
    size_t scanned_items = 0;
    size_t scanned_directories = 0;
    bool truncated = false;
    // timings in milliseconds
    long long scan_ms = 0;
    long long compose_ms = 0;
    long long fetch_ms = 0; // the parallel enumeration phase
    long long fold_ms = 0;  // the sequential pass that builds the sub-listings
};

// A flat listing built the classic way: one VFSListing per directory, composed at the end.
// This is the reference implementation - archives, network hosts and remote panels all need it.
FlatListingResult BuildFlatListingComposed(const VFSHostPtr &_host,
                                           const std::string &_root,
                                           unsigned long _fetch_flags,
                                           const VFSCancelChecker &_cancel_checker,
                                           size_t _max_items,
                                           size_t _max_directories,
                                           size_t _threads);

// The same thing, but enumerated by the Rust core with getattrlistbulk(): the entries go
// straight into one ListingInput, so there are no intermediate listings at all. Only the native
// filesystem is covered.
FlatListingResult BuildFlatListingColumnar(const VFSHostPtr &_host,
                                           const std::string &_root,
                                           unsigned long _fetch_flags,
                                           const VFSCancelChecker &_cancel_checker,
                                           size_t _max_items,
                                           size_t _max_directories,
                                           size_t _threads);

} // namespace nc::core
