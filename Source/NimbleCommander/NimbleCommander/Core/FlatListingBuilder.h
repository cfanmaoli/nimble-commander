// Copyright (C) 2026 Michael Kazakov. Subject to GNU General Public License version 3.
#pragma once

#include <VFS/VFS.h>
#include <VFS/VFSDeclarations.h>

#include <cstddef>
#include <string>
#include <vector>

namespace nc::core {

// Where the time of a flat scan went, and what it found.
struct FlatListingResult {
    VFSListingPtr listing;
    size_t scanned_items = 0;
    size_t scanned_directories = 0;
    bool truncated = false;
    // true when the scan stopped because of the time budget, not because of the size limits
    bool timed_out = false;
    // how many cloud-synced directories the scan deliberately did not enter
    size_t skipped_cloud_directories = 0;
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
                                           size_t _threads,
                                           double _max_seconds,
                                           const std::vector<std::string> &_skip_prefixes);

// The same thing, enumerated natively with getattrlistbulk(): the entries go
// straight into one ListingInput, so there are no intermediate listings at all. Only the native
// filesystem is covered.
FlatListingResult BuildFlatListingColumnar(const VFSHostPtr &_host,
                                           const std::string &_root,
                                           unsigned long _fetch_flags,
                                           const VFSCancelChecker &_cancel_checker,
                                           size_t _max_items,
                                           size_t _max_directories,
                                           size_t _threads,
                                           double _max_seconds,
                                           const std::vector<std::string> &_skip_prefixes);

} // namespace nc::core
