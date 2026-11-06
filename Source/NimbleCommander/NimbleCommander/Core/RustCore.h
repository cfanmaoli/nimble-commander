// Copyright (C) 2026 Michael Kazakov. Subject to GNU General Public License version 3.
#pragma once

#include <string>

namespace nc::core {

// The C ABI of the Rust core (see rust/include/nc_core.h). This wrapper keeps the details - and
// the fact that there is a foreign runtime behind it - out of the rest of the app.
struct RustCore {
    // Version of the Rust-side ABI. Throws if the linked library disagrees with the header the
    // app was compiled against.
    static unsigned ABIversion();

    // Round-trips a trivial call through the boundary; used by the smoke test at startup.
    static int Ping(int _value);

    // Glob matching implemented by the Rust core (whole name, \\* and ? wildcards).
    static bool GlobMatch(const std::string &_pattern, const std::string &_text, bool _case_insensitive);
};

} // namespace nc::core
