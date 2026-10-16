// Copyright (C) 2026 cfanmaoli. Subject to GNU General Public License version 3.
#pragma once

#include <cstddef>
#include <filesystem>
#include <string>
#include <vector>

namespace nc::lang {

struct PackInfo {
    std::string identifier;
    std::string language;
    std::string display_name;
    std::size_t entries = 0;
    std::filesystem::path path;
};

struct ImportStats {
    std::string language;
    std::string display_name;
    std::size_t total = 0;
    std::size_t imported = 0;
    std::size_t skipped_empty = 0;
    std::size_t skipped_malformed = 0;
    std::size_t skipped_placeholders = 0;
    /** entries whose text is byte-identical to the built-in language, i.e. most likely not
     *  translated yet. Only measured when the pack targets a different language. */
    std::size_t identical_to_current = 0;
    bool measured_untranslated = false;
};

/** Folder holding translated language packs:
 *  ~/Library/Application Support/<app name>/LanguagePacks */
const std::filesystem::path &PacksDirectory();

/** Identifier of the pack applied on the next launch. Empty means "none". */
std::string ActivePackIdentifier();
void SetActivePackIdentifier( const std::string &_identifier );

/** What the user picked in the language popup:
 *  ""               - follow the system language
 *  "builtin:<code>" - one of the languages the app ships
 *  "pack:<id>"      - an imported language pack                                          */
std::string ActiveLanguageSelection();
void SetActiveLanguageSelection( const std::string &_selection );

/** Number of entries the currently applied pack provides (0 when there's none). */
std::size_t ActivePackEntryCount();
/** Number of entries that were actually translated when the pack was imported, or
 *  std::numeric_limits<std::size_t>::max() when that couldn't be determined. */
std::size_t ActivePackTranslatedCount();
/** Language code of the currently applied pack, empty when there's none. */
std::string ActivePackLanguage();
std::string ActivePackDisplayName();

std::vector<PackInfo> ListPacks();
bool RemovePack( const std::string &_identifier, std::string &_error );

/** Number of entries the built-in UI language provides. */
std::size_t CurrentLanguageEntryCount();
/** Language code the app currently renders in. */
std::string CurrentLanguage();
std::string DisplayNameForLanguage( const std::string &_language_code );

/** Languages the app itself ships, e.g. {\"en\", \"ru\", \"zh-Hans\"}. */
std::vector<std::string> BuiltInLanguages();

/** Writes every localizable string of the current UI language into a JSON pack, ready to
 *  be translated. */
bool ExportCurrentLanguage( const std::filesystem::path &_destination, std::string &_error );

/** Validates and installs a JSON pack, and makes it the active one. */
bool ImportPack( const std::filesystem::path &_source, ImportStats &_stats, std::string &_error );

/** Quits the app and launches a fresh copy of it. */
void RelaunchApplication();

/** Installs the NSBundle lookup override - called automatically from +load. */
void InstallLocalizationOverride();

} // namespace nc::lang
