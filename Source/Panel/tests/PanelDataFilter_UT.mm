// Copyright (C) 2023-2025 Michael Kazakov. Subject to GNU General Public License version 3.
#include "PanelDataFilter.h"
#include "Tests.h"

#define PREFIX "PanelDataFilter "

namespace {

using namespace nc;
using namespace nc::panel::data;

TEST_CASE(PREFIX "Fuzzy search")
{
    using RIL = std::initializer_list<QuickSearchHighlight::Range>;
    struct TC {
        NSString *filename;
        NSString *text;
        std::optional<QuickSearchHighlight> expected;
    } test_cases[] = {
        {.filename = @"", .text = @"", .expected = QuickSearchHighlight{}},
        {.filename = @"", .text = @"a", .expected = std::nullopt},
        {.filename = @"a", .text = @"", .expected = QuickSearchHighlight{}},
        {.filename = @"a", .text = @"b", .expected = std::nullopt},
        {.filename = @"a", .text = @"a", .expected = QuickSearchHighlight{RIL{{.offset = 0, .length = 1}}}},
        {.filename = @"a", .text = @"ab", .expected = std::nullopt},
        {.filename = @"ab", .text = @"ab", .expected = QuickSearchHighlight{RIL{{.offset = 0, .length = 2}}}},
        {.filename = @"ba", .text = @"ab", .expected = std::nullopt},
        {.filename = @"aaa", .text = @"a", .expected = QuickSearchHighlight{RIL{{.offset = 0, .length = 1}}}},
        {.filename = @"aaa", .text = @"aa", .expected = QuickSearchHighlight{RIL{{.offset = 0, .length = 2}}}},
        {.filename = @"aaa", .text = @"aaa", .expected = QuickSearchHighlight{RIL{{.offset = 0, .length = 3}}}},
        {.filename = @"abc",
         .text = @"ac",
         .expected = QuickSearchHighlight{RIL{{.offset = 0, .length = 1}, {.offset = 2, .length = 1}}}},
        {.filename = @"aab", .text = @"ab", .expected = QuickSearchHighlight{RIL{{.offset = 1, .length = 2}}}},
        {.filename = @"abcabc", .text = @"abc", .expected = QuickSearchHighlight{RIL{{.offset = 0, .length = 3}}}},
        {.filename = @"abcabc",
         .text = @"abab",
         .expected = QuickSearchHighlight{RIL{{.offset = 0, .length = 2}, {.offset = 3, .length = 2}}}},
        {.filename = @"abcabc", .text = @"cabc", .expected = QuickSearchHighlight{RIL{{.offset = 2, .length = 4}}}},
        {.filename = @"abcabc",
         .text = @"bbc",
         .expected = QuickSearchHighlight{RIL{{.offset = 1, .length = 1}, {.offset = 4, .length = 2}}}},
        {.filename = @"abcabc",
         .text = @"acc",
         .expected = QuickSearchHighlight{RIL{
             {.offset = 0, .length = 1}, {.offset = 2, .length = 1}, {.offset = 5, .length = 1}}}},
        {.filename = @"Calculator.app",
         .text = @"calap",
         .expected = QuickSearchHighlight{RIL{{.offset = 0, .length = 3}, {.offset = 11, .length = 2}}}},
        {.filename = @"Calculator.app",
         .text = @"calapp",
         .expected = QuickSearchHighlight{RIL{{.offset = 0, .length = 3}, {.offset = 11, .length = 3}}}},
        {.filename = @"Calculator.app",
         .text = @"calcapp",
         .expected = QuickSearchHighlight{RIL{{.offset = 0, .length = 4}, {.offset = 11, .length = 3}}}},
        {.filename = @"Calculator.app",
         .text = @"culap",
         .expected = QuickSearchHighlight{RIL{{.offset = 3, .length = 4}, {.offset = 12, .length = 1}}}},
        {.filename = @"Calculator.app",
         .text = @"app",
         .expected = QuickSearchHighlight{RIL{{.offset = 11, .length = 3}}}},
    };
    for( auto &tc : test_cases ) {
        auto hl = FuzzySearch(tc.filename, tc.text);
        CHECK(hl == tc.expected);
    }
}

TEST_CASE(PREFIX "Pinyin initials of a name")
{
    CHECK(PinyinInitialsForName(@"下载") == "xz");
    CHECK(PinyinInitialsForName(@"中文文档") == "zwwd");
    CHECK(PinyinInitialsForName(@"文档 abc") == "wdabc");
    CHECK(PinyinInitialsForName(@"下载.txt") == "xztxt");
    CHECK(PinyinInitialsForName(@"plain name.txt").empty());
    CHECK(PinyinInitialsForName(@"").empty());
    // the pinyin of a mixed name still comes out letter by letter
    CHECK(PinyinInitialsForName(@"日本語") == "rby");
}

TEST_CASE(PREFIX "Pinyin initials search")
{
    using RIL = std::initializer_list<QuickSearchHighlight::Range>;
    const auto anywhere = TextualFilter::Where::Anywhere;
    const auto beginning = TextualFilter::Where::Beginning;
    const auto ending = TextualFilter::Where::Ending;
    const auto fuzzy = TextualFilter::Where::Fuzzy;
    const auto both = TextualFilter::Where::BeginningOrEnding;

    struct TC {
        NSString *name;
        NSString *text;
        TextualFilter::Where type;
        std::optional<QuickSearchHighlight> expected;
    } test_cases[] = {
        // the whole point of it all
        {.name = @"下载",
         .text = @"xz",
         .type = anywhere,
         .expected = QuickSearchHighlight{RIL{{.offset = 0, .length = 2}}}},
        {.name = @"下载",
         .text = @"XZ",
         .type = anywhere,
         .expected = QuickSearchHighlight{RIL{{.offset = 0, .length = 2}}}},
        // a single initial highlights its own character
        {.name = @"下载",
         .text = @"z",
         .type = anywhere,
         .expected = QuickSearchHighlight{RIL{{.offset = 1, .length = 1}}}},
        // latin parts of a name stay reachable
        {.name = @"下载.txt",
         .text = @"txt",
         .type = anywhere,
         .expected = QuickSearchHighlight{RIL{{.offset = 3, .length = 3}}}},
        // anchors
        {.name = @"下载.txt",
         .text = @"xz",
         .type = beginning,
         .expected = QuickSearchHighlight{RIL{{.offset = 0, .length = 2}}}},
        {.name = @"下载.txt", .text = @"txt", .type = beginning, .expected = std::nullopt},
        {.name = @"下载.txt",
         .text = @"txt",
         .type = ending,
         .expected = QuickSearchHighlight{RIL{{.offset = 3, .length = 3}}}},
        {.name = @"下载.txt", .text = @"xz", .type = ending, .expected = std::nullopt},
        {.name = @"下载.txt",
         .text = @"xz",
         .type = both,
         .expected = QuickSearchHighlight{RIL{{.offset = 0, .length = 2}}}},
        // fuzzy over the initials
        {.name = @"中文文档",
         .text = @"zw",
         .type = fuzzy,
         .expected = QuickSearchHighlight{RIL{{.offset = 0, .length = 2}}}},
        {.name = @"中文文档", .text = @"zq", .type = fuzzy, .expected = std::nullopt},
        // nothing to do for names without ideographs or for non-latin criteria
        {.name = @"plain.txt", .text = @"pl", .type = anywhere, .expected = std::nullopt},
        {.name = @"下载", .text = @"下载", .type = anywhere, .expected = std::nullopt},
        {.name = @"下载", .text = @"abc", .type = anywhere, .expected = std::nullopt},
    };

    for( const auto &tc : test_cases ) {
        INFO("name: " << tc.name.UTF8String << ", text: " << tc.text.UTF8String
                      << ", type: " << static_cast<int>(tc.type));
        CHECK(PinyinInitialsSearch(tc.name, tc.text, tc.type) == tc.expected);
    }
}

} // namespace

#undef PREFIX
