// Copyright (C) 2026 Michael Kazakov. Subject to GNU General Public License version 3.
#include "Protocol.h"
#include <rapidjson/document.h>
#include <algorithm>
#include <limits>

namespace nc::vfs::rar {

bool Entry::IsLink() const noexcept
{
    return link_type != LinkType::Regular;
}

namespace {

std::optional<uint64_t> ReadUint(const rapidjson::Value &_obj, const char *_name)
{
    const auto member = _obj.FindMember(_name);
    if( member == _obj.MemberEnd() )
        return std::nullopt;
    if( member->value.IsUint64() )
        return member->value.GetUint64();
    if( member->value.IsInt64() && member->value.GetInt64() >= 0 )
        return static_cast<uint64_t>(member->value.GetInt64());
    return std::nullopt;
}

std::optional<int64_t> ReadInt(const rapidjson::Value &_obj, const char *_name)
{
    const auto member = _obj.FindMember(_name);
    if( member == _obj.MemberEnd() )
        return std::nullopt;
    if( member->value.IsInt64() )
        return member->value.GetInt64();
    if( member->value.IsUint64() &&
        member->value.GetUint64() <= static_cast<uint64_t>(std::numeric_limits<int64_t>::max()) )
        return static_cast<int64_t>(member->value.GetUint64());
    return std::nullopt;
}

std::optional<bool> ReadBool(const rapidjson::Value &_obj, const char *_name)
{
    const auto member = _obj.FindMember(_name);
    if( member == _obj.MemberEnd() || !member->value.IsBool() )
        return std::nullopt;
    return member->value.GetBool();
}

std::optional<std::string_view> ReadString(const rapidjson::Value &_obj, const char *_name)
{
    const auto member = _obj.FindMember(_name);
    if( member == _obj.MemberEnd() || !member->value.IsString() )
        return std::nullopt;
    return std::string_view{member->value.GetString(), member->value.GetStringLength()};
}

// The helper reports '/'-separated paths, but some archives carry Windows-style separators.
std::string NormalizeName(std::string_view _name)
{
    std::string name{_name};
    std::ranges::replace(name, '\\', '/');
    return name;
}

std::vector<std::string> SplitComponents(std::string_view _name)
{
    std::vector<std::string> components;
    size_t pos = 0;
    while( pos <= _name.size() ) {
        const size_t slash = _name.find('/', pos);
        const size_t end = slash == std::string_view::npos ? _name.size() : slash;
        if( end > pos )
            components.emplace_back(_name.substr(pos, end - pos));
        if( slash == std::string_view::npos )
            break;
        pos = slash + 1;
    }
    return components;
}

std::optional<Entry> ParseEntry(const rapidjson::Value &_obj)
{
    const std::optional<uint64_t> index = ReadUint(_obj, "index");
    if( !index || *index > std::numeric_limits<uint32_t>::max() )
        return std::nullopt;

    const std::optional<std::string_view> name = ReadString(_obj, "name");
    if( !name || name->empty() )
        return std::nullopt;

    Entry entry;
    entry.index = static_cast<uint32_t>(*index);
    entry.name = NormalizeName(*name);
    entry.components = SplitComponents(entry.name);
    entry.dir = ReadBool(_obj, "dir").value_or(false);
    entry.encrypted = ReadBool(_obj, "encrypted").value_or(false);
    entry.solid = ReadBool(_obj, "solid").value_or(false);
    entry.size = ReadUint(_obj, "size").value_or(0);
    entry.packed = ReadUint(_obj, "packed").value_or(0);
    entry.mtime = static_cast<time_t>(ReadInt(_obj, "mtime").value_or(0));
    entry.crc = static_cast<uint32_t>(ReadUint(_obj, "crc").value_or(0));

    const int64_t link_type = ReadInt(_obj, "link_type").value_or(0);
    if( link_type >= static_cast<int64_t>(LinkType::Regular) && link_type <= static_cast<int64_t>(LinkType::FileCopy) )
        entry.link_type = static_cast<LinkType>(link_type);

    // An empty target means that the helper couldn't provide one - treat it as unknown.
    if( const std::optional<std::string_view> target = ReadString(_obj, "link_target"); target && !target->empty() )
        entry.link_target = std::string{*target};

    // The helper reports the Unix mode only when the archive carries one; a zero isn't a mode.
    if( const std::optional<uint64_t> mode = ReadUint(_obj, "mode");
        mode && *mode != 0 && *mode <= std::numeric_limits<mode_t>::max() )
        entry.mode = static_cast<mode_t>(*mode);

    return entry;
}

} // namespace

std::optional<Listing> ParseListing(const std::string_view _json_lines)
{
    Listing listing;
    size_t pos = 0;
    while( pos < _json_lines.size() ) {
        const size_t eol = _json_lines.find('\n', pos);
        const size_t line_end = eol == std::string_view::npos ? _json_lines.size() : eol;
        const std::string_view line = _json_lines.substr(pos, line_end - pos);
        pos = eol == std::string_view::npos ? _json_lines.size() : eol + 1;

        if( line.empty() || line == "\r" )
            continue;

        rapidjson::Document document;
        document.Parse(line.data(), line.size());
        if( document.HasParseError() || !document.IsObject() )
            return std::nullopt;

        if( const std::optional<bool> done = ReadBool(document, "done"); done && *done ) {
            listing.done = true;
            listing.reported_entries = ReadUint(document, "entries").value_or(0);
            continue;
        }

        std::optional<Entry> entry = ParseEntry(document);
        if( !entry )
            return std::nullopt;
        listing.entries.emplace_back(std::move(*entry));
    }

    return listing;
}

std::optional<std::string> ParseLinkResponse(const std::string_view _json)
{
    rapidjson::Document document;
    document.Parse(_json.data(), _json.size());
    if( document.HasParseError() || !document.IsObject() )
        return std::nullopt;

    if( const auto ok = document.FindMember("ok");
        ok != document.MemberEnd() && ok->value.IsBool() && !ok->value.GetBool() )
        return std::nullopt;

    const std::optional<std::string_view> target = ReadString(document, "target");
    if( !target || target->empty() )
        return std::nullopt;
    return std::string{*target};
}

} // namespace nc::vfs::rar
