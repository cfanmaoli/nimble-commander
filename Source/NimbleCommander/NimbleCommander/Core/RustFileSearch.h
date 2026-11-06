// Copyright (C) 2026 Michael Kazakov. Subject to GNU General Public License version 3.
#pragma once

#include <cstdint>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <string_view>

namespace nc::core {

// A filename search backed by the Rust core (rust/nc_core). It only covers the native
// filesystem and the classic (glob) masks - the VFS SearchForFiles remains the implementation for
// archives, network hosts, content filters and regular expressions.
class RustFileSearch
{
public:
    struct Filter {
        // A single classic mask with wildcards, e.g. "*.txt". Empty means "match everything".
        std::string mask;
        bool case_sensitive = false;
        bool search_files = true;
        bool search_dirs = false;
        bool go_into_subdirs = true;
        // Both limits are inclusive; unset means unbounded.
        std::optional<uint64_t> min_size;
        std::optional<uint64_t> max_size;
    };

    struct Hit {
        std::string name;     // file name without the directory
        std::string dir_path; // the directory it was found in, with a trailing slash
        uint64_t size = 0;
        bool is_dir = false;
    };

    using FoundCallback = std::function<void(const Hit &)>;

    RustFileSearch();
    ~RustFileSearch();
    RustFileSearch(const RustFileSearch &) = delete;
    RustFileSearch &operator=(const RustFileSearch &) = delete;

    // Returns false if the search couldn't be started (already running / bad arguments).
    // The callbacks are invoked from a worker thread.
    bool Go(const std::string &_root, const Filter &_filter, FoundCallback _found, std::function<void()> _finish);

    void Stop();
    void Wait();

    [[nodiscard]] bool IsRunning() const;
    [[nodiscard]] uint64_t FilesSeen() const;
    [[nodiscard]] uint64_t DirsSeen() const;
    [[nodiscard]] uint64_t Matches() const;

    // True when the given mask can be handled by the Rust matcher: a single classic mask with
    // ASCII-only wildcards (the C++ FileMask also accepts comma-separated lists and regexes).
    [[nodiscard]] static bool CanHandleMask(std::string_view _mask);

    // opaque state; public only so that the translation unit's helpers can name it
    struct Impl;

private:
    std::unique_ptr<Impl> m_Impl;
};

} // namespace nc::core
