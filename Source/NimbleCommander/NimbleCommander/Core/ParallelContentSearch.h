// Copyright (C) 2026 Michael Kazakov. Subject to GNU General Public License version 3.
#pragma once

#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <string_view>

namespace nc::core {

// A text search inside the files of a native directory tree, done natively and in parallel.
// The C++ VFS implementation (SearchForFiles + SearchInFile) stays in charge of archives,
// network hosts and non-UTF-8 encodings; this covers the common case of UTF-8/ASCII content.
class ParallelContentSearch
{
public:
    struct Filter {
        std::string text;
        bool case_sensitive = false;
        bool whole_phrase = false;
        // Files bigger than this are skipped; 0 means no limit.
        uint64_t max_file_size = 0;
        bool go_into_subdirs = true;
    };

    struct Hit {
        std::string name;     // file name without the directory
        std::string dir_path; // absolute directory, with a trailing slash
        uint64_t offset = 0;  // byte offset within the file
        uint64_t bytes_len = 0;
    };

    using FoundCallback = std::function<void(const Hit &)>;

    ParallelContentSearch();
    ~ParallelContentSearch();
    ParallelContentSearch(const ParallelContentSearch &) = delete;
    ParallelContentSearch &operator=(const ParallelContentSearch &) = delete;

    bool Go(const std::string &_root, const Filter &_filter, FoundCallback _found, std::function<void()> _finish);

    void Stop();
    void Wait();

    [[nodiscard]] bool IsRunning() const;
    [[nodiscard]] uint64_t FilesScanned() const;
    [[nodiscard]] uint64_t FilesSkipped() const;
    [[nodiscard]] uint64_t Matches() const;

    // opaque state; public only so that the translation unit's helpers can name it
    struct Impl;

private:
    std::unique_ptr<Impl> m_Impl;
};

} // namespace nc::core
