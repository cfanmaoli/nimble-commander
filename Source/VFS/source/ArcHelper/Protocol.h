// Copyright (C) 2026 Michael Kazakov. Subject to GNU General Public License version 3.
#pragma once

#include <cstdint>
#include <ctime>
#include <optional>
#include <string>
#include <string_view>
#include <sys/types.h>
#include <vector>

namespace nc::vfs::rar {

// Kinds of links that the helper reports, mirroring the link_type values of its protocol.
enum class LinkType : uint8_t {
    Regular = 0,
    UnixSymlink = 1,
    WindowsSymlink = 2,
    Junction = 3,
    Hardlink = 4,
    FileCopy = 5,
};

// A single archive entry as reported by the helper's "list" command.
struct Entry {
    uint32_t index = 0;                  // 0-based entry index, the "read" command expects this value
    std::string name;                    // entry path inside the archive, '/'-separated
    std::vector<std::string> components; // name split into the path components
    bool dir = false;                    // the entry is a directory
    bool encrypted = false;              // the entry payload is encrypted
    bool solid = false;                  // the entry belongs to a solid block
    uint64_t size = 0;                   // unpacked size in bytes
    uint64_t packed = 0;                 // packed size in bytes
    time_t mtime = 0;                    // modification time, Unix seconds, 0 when unknown
    uint32_t crc = 0;                    // CRC32 from the archive header
    LinkType link_type = LinkType::Regular;
    std::optional<std::string> link_target; // known only when the archive stores it in the header
    std::optional<mode_t> mode;             // Unix mode, when the archive carries Unix attributes

    // True when the entry describes a link of any kind.
    [[nodiscard]] bool IsLink() const noexcept;
};

// The parsed output of the helper's "list" command.
struct Listing {
    std::vector<Entry> entries;
    bool done = false;             // the terminator line was seen
    uint64_t reported_entries = 0; // the entry count from the terminator, 0 when it wasn't reported
};

// Parses the JSON-lines output of the helper's "list" command. Returns nullopt when the text isn't
// a well-formed listing. Empty lines are ignored, unknown fields are ignored.
[[nodiscard]] std::optional<Listing> ParseListing(std::string_view _json_lines);

// Parses the one-line JSON that the helper's "link" command prints. Returns nullopt when the text
// isn't a well-formed target response.
[[nodiscard]] std::optional<std::string> ParseLinkResponse(std::string_view _json);

} // namespace nc::vfs::rar
