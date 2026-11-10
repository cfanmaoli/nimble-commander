// Copyright (C) 2024-2025 Michael Kazakov. Subject to GNU General Public License version 3.
#include <Viewer/Highlighting/LexerSettings.h>
#include <lexilla/SciLexerStyleNames.h>
#include <rapidjson/document.h>
#include <rapidjson/error/en.h>
#include <frozen/unordered_map.h>
#include <frozen/string.h>
#include <ankerl/unordered_dense.h>
#include <fmt/format.h>
#include <map>

namespace nc::viewer::hl {

[[clang::no_destroy]] static const ankerl::unordered_dense::map<std::string_view, char> g_SCENames = [] {
    static_assert(std::size(Lexilla::g_SCENames) == std::size(Lexilla::g_SCEValues));
    const size_t len = std::size(Lexilla::g_SCENames);
    ankerl::unordered_dense::map<std::string_view, char> names;
    names.reserve(len);
    for( size_t i = 0; i < len; ++i ) {
        names.emplace(Lexilla::g_SCENames[i], Lexilla::g_SCEValues[i]);
    }
    return names;
}();

static constinit frozen::unordered_map<frozen::string, Style, 8> g_MappedStyles{
    {"default", Style::Default},           //
    {"comment", Style::Comment},           //
    {"preprocessor", Style::Preprocessor}, //
    {"keyword", Style::Keyword},           //
    {"operator", Style::Operator},         //
    {"identifier", Style::Identifier},     //
    {"number", Style::Number},             //
    {"string", Style::String}              //
};

std::expected<LexerSettings, std::string> ParseLexerSettings(std::string_view _json) noexcept
{
    rapidjson::Document doc;
    doc.Parse<rapidjson::kParseCommentsFlag>(_json.data(), _json.size());
    if( doc.HasParseError() )
        return std::unexpected{fmt::format("Failed to parse JSON: {} at offset {}",
                                           rapidjson::GetParseError_En(doc.GetParseError()),
                                           static_cast<size_t>(doc.GetErrorOffset()))};
    if( !doc.IsObject() )
        return std::unexpected{std::string{"Failed to parse JSON: the root is not an object"}};

    const auto lexer = doc.FindMember("lexer");
    if( lexer == doc.MemberEnd() || !lexer->value.IsString() )
        return std::unexpected{std::string{"Failed to parse JSON: no 'lexer' string"}};

    LexerSettings sets;
    sets.name = lexer->value.GetString();

    if( const auto wordlists = doc.FindMember("wordlists");
        wordlists != doc.MemberEnd() && !wordlists->value.IsNull() ) {
        if( !wordlists->value.IsArray() )
            return std::unexpected{std::string{"Failed to parse JSON: 'wordlists' is not an array"}};
        for( const auto &entry : wordlists->value.GetArray() ) {
            if( !entry.IsString() )
                return std::unexpected{std::string{"Failed to parse JSON: a wordlist is not a string"}};
            sets.wordlists.emplace_back(entry.GetString());
        }
    }

    if( const auto properties = doc.FindMember("properties");
        properties != doc.MemberEnd() && !properties->value.IsNull() ) {
        if( !properties->value.IsObject() )
            return std::unexpected{std::string{"Failed to parse JSON: 'properties' is not an object"}};
        for( auto it = properties->value.MemberBegin(); it != properties->value.MemberEnd(); ++it ) {
            if( !it->value.IsString() )
                return std::unexpected{std::string{"Failed to parse JSON: a property value is not a string"}};
            sets.properties.push_back({.key = it->name.GetString(), .value = it->value.GetString()});
        }
    }

    if( const auto mapping = doc.FindMember("mapping"); mapping != doc.MemberEnd() && !mapping->value.IsNull() ) {
        if( !mapping->value.IsObject() )
            return std::unexpected{std::string{"Failed to parse JSON: 'mapping' is not an object"}};
        for( auto it = mapping->value.MemberBegin(); it != mapping->value.MemberEnd(); ++it ) {
            if( !it->value.IsString() )
                return std::unexpected{std::string{"Failed to parse JSON: a mapping value is not a string"}};
            const std::string key = it->name.GetString();
            const std::string value = it->value.GetString();

            const auto key_it = g_SCENames.find(key);
            if( key_it == g_SCENames.end() )
                return std::unexpected{fmt::format("Unknown style '{}'", key)};

            const auto value_it = g_MappedStyles.find(frozen::string(value));
            if( value_it == g_MappedStyles.end() )
                return std::unexpected{fmt::format("Unknown style '{}'", value)};

            sets.mapping.SetMapping(key_it->second, value_it->second);
        }
    }

    return sets;
}

} // namespace nc::viewer::hl
