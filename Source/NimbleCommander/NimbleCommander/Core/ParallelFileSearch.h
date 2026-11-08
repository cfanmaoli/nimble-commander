// Copyright (C) 2026 Michael Kazakov. Subject to GNU General Public License version 3.
#pragma once

#include <cstdint>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <string_view>

namespace nc::core {

// A filename search over the native filesystem, done in parallel. It mirrors the parts of
// vfs::SearchForFiles the find-files dialog uses for local directories and reuses the same
// utility::FileMask for matching, so that the two implementations agree on what a match is.
class ParallelFileSearch
{
public:
    struct Filter {
        // A classic mask, e.g. "*.txt"; empty means "match everything". The same syntax as
        // utility::FileMask (wildcards, comma-separated alternatives and regexes are all fine).
        std::string mask;
        bool search_files = true;
        bool search_dirs = false;
        bool go_into_subdirs = true;
        // Both limits are inclusive; unset means unbounded.
        std::optional<uint64_t> min_size;
        std::optional<uint64_t> max_size;
    };

    struct Hit {
        std::string name;     // file name without the directory
        std::string dir_path; // absolute directory, with a trailing slash
        uint64_t size = 0;
        bool is_dir = false;
    };

    using FoundCallback = std::function<void(const Hit &)>;
    // Reports every directory the walk enters, for the "looking in" label.
    using LookInCallback = std::function<void(const std::string &)>;

    ParallelFileSearch();
    ~ParallelFileSearch();
    ParallelFileSearch(const ParallelFileSearch &) = delete;
    ParallelFileSearch &operator=(const ParallelFileSearch &) = delete;

    bool Go(const std::string &_root,
            const Filter &_filter,
            FoundCallback _found,
            std::function<void()> _finish,
            LookInCallback _looking_in = nullptr);

    void Stop();
    void Wait();

    [[nodiscard]] bool IsRunning() const;
    [[nodiscard]] uint64_t FilesSeen() const;
    [[nodiscard]] uint64_t DirsSeen() const;
    [[nodiscard]] uint64_t Matches() const;

    // opaque state; public only so that the translation unit's helpers can name it
    struct Impl;

private:
    std::unique_ptr<Impl> m_Impl;
};

} // namespace nc::core
