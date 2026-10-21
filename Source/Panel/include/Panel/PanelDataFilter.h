// Copyright (C) 2017-2024 Michael Kazakov. Subject to GNU General Public License version 3.
#pragma once

#include <VFS/VFSDeclarations.h>
#include <CoreFoundation/CoreFoundation.h>

#include "PanelDataItemVolatileData.h"

#include <compare>
#include <optional>
#include <string>

namespace nc::panel::data {

struct TextualFilter {
    enum Where : int8_t // persistancy-bound values, don't change it
    {
        Anywhere = 0,
        Beginning = 1,
        Ending = 2, // handling extensions somehow
        BeginningOrEnding = 3,
        Fuzzy = 4,
        Regex = 5
    };

    NSString *text;
    Where type = Where::Anywhere;

    // will not apply filter on dot-dot entries
    bool ignore_dot_dot : 1 = true;

    // if true then PanelData will automatically set text to nil on Load method call
    bool clear_on_new_listing : 1 = false;

    // option for PanelData to mark QS hightlight
    bool hightlight_results : 1 = true;

    constexpr TextualFilter() noexcept = default;
    bool operator==(const TextualFilter &_r) const noexcept;
    bool operator!=(const TextualFilter &_r) const noexcept;
    static Where WhereFromInt(int _v) noexcept;
    static TextualFilter NoFilter() noexcept;
    bool IsValidItem(const VFSListingItem &_item, QuickSearchHighlight &_found_range) const;
    [[nodiscard]] bool IsValidItem(const VFSListingItem &_item) const;
    void OnPanelDataLoad();
    [[nodiscard]] bool IsFiltering() const noexcept;
} __attribute__((packed));

struct HardFilter {
    TextualFilter text = TextualFilter::NoFilter();
    bool show_hidden = true;
    bool IsValidItem(const VFSListingItem &_item, QuickSearchHighlight &_found_range) const;
    [[nodiscard]] bool IsFiltering() const noexcept;
    bool operator==(const HardFilter &_r) const noexcept = default;
    bool operator!=(const HardFilter &_r) const noexcept = default;
};

std::optional<QuickSearchHighlight> FuzzySearch(NSString *_filename, NSString *_text) noexcept;

/**
 * Matches a latin-only criterion against the initials of the transliterated syllables of a name,
 * so that a Chinese "下载" can be found by typing "xz". Returns the range of the *name* that the
 * matching initials came from, or nullopt when the criterion is not latin-only or the name has
 * nothing to transliterate.
 */
std::optional<QuickSearchHighlight>
PinyinInitialsSearch(NSString *_name, NSString *_text, TextualFilter::Where _type) noexcept;

/**
 * The latin initials of a name: "下载" -> "xz", "文档 abc" -> "wdabc". Empty when the name has no
 * ideographs. Exposed for the unit tests.
 */
std::string PinyinInitialsForName(NSString *_name) noexcept;

/**
 * Matches a name against an ICU regular expression, case-insensitively unless the pattern overrides
 * it with an inline flag such as (?-i). Returns the matched ranges, or nullopt when the pattern is
 * not a valid expression yet - which happens on every other keystroke while the user is still
 * typing it.
 */
std::optional<QuickSearchHighlight> RegexSearch(NSString *_name, NSString *_text) noexcept;

} // namespace nc::panel::data
