// Copyright (C) 2024-2025 Michael Kazakov. Subject to GNU General Public License version 3.
#include <Viewer/Highlighting/FileSettingsStorage.h>
#include <Viewer/Log.h>
#include <Utility/FSEventsDirUpdate.h>
#include <fstream>
#include <rapidjson/document.h>
#include <rapidjson/error/en.h>
#include <iterator>
#include <ranges>
#include <fmt/format.h>

namespace nc::viewer::hl {

[[clang::no_destroy]] static const std::filesystem::path g_MainSettingsFile = "Main.json";

bool FileSettingsStorage::RegFileExists(const std::filesystem::path &_path) noexcept
{
    std::error_code ec = {};
    const std::filesystem::file_status status = std::filesystem::status(_path, ec);
    if( ec ) {
        return false;
    }

    return std::filesystem::exists(status) && std::filesystem::is_regular_file(status);
}

FileSettingsStorage::FileSettingsStorage(const std::filesystem::path &_base_dir,
                                         const std::filesystem::path &_overrides_dir)
    : m_BaseDir(_base_dir), m_OverridesDir(_overrides_dir)
{
    const std::filesystem::path base_main = m_BaseDir / g_MainSettingsFile;
    const std::filesystem::path overrides_main = m_OverridesDir / g_MainSettingsFile;

    if( RegFileExists(overrides_main) ) {
        // Try to load the main settings from the overrides file
        try {
            m_Langs = LoadLangs(overrides_main);
        } catch( std::exception &ex ) {
            // Something went wrong with the overrides, complain but allow to continue
            Log::Warn("Unable to load the languages definitions from '{}', continuing with no definitions",
                      overrides_main.native());
        }
    }
    else {
        // No overrides main exist - use the base file
        m_Langs = LoadLangs(base_main);
    }

    SubscribeToOverridesChanges();
}

FileSettingsStorage::~FileSettingsStorage()
{
    UnsubscribeFromOverridesChanges();
}

std::vector<FileSettingsStorage::Lang> FileSettingsStorage::LoadLangs(const std::filesystem::path &_path)
{
    Log::Debug("Loading languages definitions from '{}'", _path.native());

    std::ifstream f(_path);
    if( !f.is_open() ) {
        Log::Error("Unable to open the file '{}'", _path.native());
        throw std::invalid_argument(fmt::format("Unable to open the file '{}'", _path.native()));
    }

    const std::string content((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    rapidjson::Document data;
    data.Parse<rapidjson::kParseCommentsFlag>(content.data(), content.size());
    if( data.HasParseError() ) {
        const std::string message = fmt::format("Unable to parse '{}': {} at offset {}",
                                                _path.native(),
                                                rapidjson::GetParseError_En(data.GetParseError()),
                                                static_cast<size_t>(data.GetErrorOffset()));
        Log::Error("{}", message);
        throw std::invalid_argument(message);
    }

    if( !data.IsObject() || !data.HasMember("langs") || !data["langs"].IsArray() ) {
        Log::Error("Invalid JSON format '{}': no 'langs' array", _path.native());
        throw std::invalid_argument(fmt::format("Invalid JSON format '{}': no 'langs' array", _path.native()));
    }

    const auto fail = [&](std::string_view _reason) -> void {
        const std::string message = fmt::format("Parse error in '{}': {}", _path.native(), _reason);
        Log::Error("{}", message);
        throw std::invalid_argument(message);
    };

    std::vector<FileSettingsStorage::Lang> output;
    for( const auto &entry : data["langs"].GetArray() ) {
        if( !entry.IsObject() )
            fail("an entry is not an object");
        const auto name_it = entry.FindMember("name");
        const auto settings_it = entry.FindMember("settings");
        const auto filemask_it = entry.FindMember("filemask");
        if( name_it == entry.MemberEnd() || settings_it == entry.MemberEnd() || filemask_it == entry.MemberEnd() ) {
            fail("an entry is missing one of name/settings/filemask");
        }
        if( !name_it->value.IsString() || !settings_it->value.IsString() || !filemask_it->value.IsString() )
            fail("name/settings/filemask must be strings");
        const std::string name = name_it->value.GetString();
        const std::string settings = settings_it->value.GetString();
        const std::string filemask = filemask_it->value.GetString();
        if( name.empty() )
            fail("empty name is not allowed");
        if( settings.empty() )
            fail("empty settings is not allowed");
        if( filemask.empty() )
            fail("empty filemask is not allowed");

        Lang lang;
        lang.name = name;
        lang.settings_filename = settings;
        lang.mask = utility::FileMask(filemask, utility::FileMask::Type::Mask);
        output.push_back(std::move(lang));
    }

    ankerl::unordered_dense::set<std::string_view, UnorderedStringHashEqual, UnorderedStringHashEqual> set;
    set.reserve(output.size());
    for( auto &lang : output ) {
        if( set.contains(lang.name) ) {
            Log::Error("The language '{}' is defined more than once", lang.name);
            throw std::invalid_argument(fmt::format("The language '{}' is defined more than once", lang.name));
        }
        set.emplace(lang.name);
    }

    return output;
}

void FileSettingsStorage::ReloadLangs()
{
    const std::filesystem::path base_main = m_BaseDir / g_MainSettingsFile;
    const std::filesystem::path overrides_main = m_OverridesDir / g_MainSettingsFile;
    m_Langs.clear();

    try {
        if( RegFileExists(overrides_main) ) {
            m_Langs = LoadLangs(overrides_main);
        }
        else {
            m_Langs = LoadLangs(base_main);
        }
    } catch( std::exception &ex ) {
        // Something went wrong with the overrides, complain but allow to continue
        Log::Warn("Unable to reload the languages definitions from '{}', continuing with no definitions",
                  overrides_main.native());
    }
    m_Outdated = false;
}

std::optional<std::string> FileSettingsStorage::Language(std::string_view _filename) noexcept
{
    if( m_Outdated ) {
        ReloadLangs();
    }

    for( auto &lang : m_Langs ) {
        if( lang.mask.MatchName(_filename) ) {
            return lang.name;
        }
    }
    return {};
}

std::vector<std::string> FileSettingsStorage::List()
{
    std::vector<std::string> list;
    list.reserve(m_Langs.size());
    for( const Lang &lang : m_Langs ) {
        list.push_back(lang.name);
    }
    return list;
}

std::shared_ptr<const std::string> FileSettingsStorage::Settings(std::string_view _lang)
{
    Log::Trace("Settings() called");

    if( const auto sett_it = m_Settings.find(_lang); sett_it != m_Settings.end() ) {
        Log::Trace("Retreived the syntax settings for the language '{}'", _lang);
        return sett_it->second;
    }

    if( m_Outdated ) {
        ReloadLangs();
    }

    const auto lang_it = std::ranges::find_if(m_Langs, [&](auto &lang) { return lang.name == _lang; });
    if( lang_it == m_Langs.end() ) {
        return {};
    }

    const std::filesystem::path base_settings_path = m_BaseDir / lang_it->settings_filename;
    const std::filesystem::path overrides_settings_path = m_OverridesDir / lang_it->settings_filename;
    const std::filesystem::path settings_path =
        RegFileExists(overrides_settings_path) ? overrides_settings_path : base_settings_path;

    std::ifstream ifs{settings_path};
    if( ifs ) {
        std::string text((std::istreambuf_iterator<char>(ifs)), std::istreambuf_iterator<char>());
        auto shared = std::make_shared<std::string>(std::move(text));
        m_Settings.emplace(_lang, shared);
        Log::Debug("Sucessfuly loaded the syntax settings from the file '{}'", settings_path.native());
        return shared;
    }
    else {
        m_Settings.emplace(_lang, nullptr);
        Log::Error("Unable to load the syntax settings from the file '{}'", settings_path.native());
        return {};
    }
}

void FileSettingsStorage::SubscribeToOverridesChanges()
{
    Log::Trace("SubscribeToOverridesChanges() called");
    m_OverridesObservationToken =
        utility::FSEventsDirUpdate::Instance().AddWatchPath(m_OverridesDir.c_str(), [this] { OverridesChanged(); });
}

void FileSettingsStorage::UnsubscribeFromOverridesChanges()
{
    Log::Trace("UnsubscribeFromOverridesChanges() called");
    if( m_OverridesObservationToken ) {
        utility::FSEventsDirUpdate::Instance().RemoveWatchPathWithTicket(m_OverridesObservationToken);
        m_OverridesObservationToken = 0;
    }
}

void FileSettingsStorage::OverridesChanged()
{
    Log::Trace("OverridesChanged() called");
    m_Outdated = true;  // mark the definitions as outdated
    m_Settings.clear(); // drop anything was loaded before
}

} // namespace nc::viewer::hl
