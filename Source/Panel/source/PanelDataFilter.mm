// Copyright (C) 2017-2024 Michael Kazakov. Subject to GNU General Public License version 3.
#include "PanelDataFilter.h"
#include <VFS/VFS.h>
#include <Base/CFPtr.h>
#include <Base/CFStackAllocator.h>
#include <algorithm>
#include <cctype>
#include <memory_resource>
#include <string>
#include <unordered_map>
#include <vector>

namespace nc::panel::data {

static_assert(sizeof(TextualFilter) == 10);
static_assert(sizeof(HardFilter) == 11);

bool TextualFilter::operator==(const TextualFilter &_r) const noexcept
{
    if( type != _r.type )
        return false;

    if( text == nil && _r.text != nil )
        return false;

    if( text != nil && _r.text == nil )
        return false;

    if( text == nil && _r.text == nil )
        return true;

    return [text isEqualToString:_r.text]; // no decomposion here
}

bool TextualFilter::operator!=(const TextualFilter &_r) const noexcept
{
    return !(*this == _r);
}

TextualFilter::Where TextualFilter::WhereFromInt(int _v) noexcept
{
    if( _v >= 0 && _v <= Regex )
        return Where(_v);
    return Anywhere;
}

TextualFilter TextualFilter::NoFilter() noexcept
{
    TextualFilter filter;
    filter.type = Anywhere;
    filter.text = nil;
    filter.ignore_dot_dot = true;
    return filter;
}

bool TextualFilter::IsValidItem(const VFSListingItem &_item) const
{
    QuickSearchHighlight hl;
    return IsValidItem(_item, hl);
}

static bool FuzzySearchSatisfiable(CFStringRef _hay,
                                   size_t _hay_len,
                                   size_t _hay_start,
                                   NSString *_needle,
                                   size_t _needle_start) noexcept
{
    const base::CFStackAllocator alloc;
    const auto needle_len = _needle.length;

    size_t pos = _hay_start;
    for( size_t idx = _needle_start; idx < needle_len; ++idx ) {
        const UniChar c = [_needle characterAtIndex:idx];
        const auto cs =
            base::CFPtr<CFStringRef>::adopt(CFStringCreateWithCharactersNoCopy(alloc, &c, 1, kCFAllocatorNull));
        CFRange result = {.location = 0, .length = 0};
        const bool found = CFStringFindWithOptions(
            _hay, cs.get(), CFRangeMake(pos, _hay_len - pos), kCFCompareCaseInsensitive, &result);
        if( !found )
            return false; // cannot be satisfied - filename doesn't contain a sparse sequence of chars from text
        pos = result.location + 1;
    }
    return true;
}

std::optional<QuickSearchHighlight> FuzzySearch(NSString *_filename, NSString *_text) noexcept
{
    assert(_filename != nil);
    assert(_text != nil);

    const base::CFPtr<CFStringRef> cf_filename =
        base::CFPtr<CFStringRef>::adopt(static_cast<CFStringRef>(CFBridgingRetain(_filename)));

    const auto filename_len = _filename.length;

    // 1st - check satisfiability in general
    if( !FuzzySearchSatisfiable(cf_filename.get(), filename_len, 0, _text, 0) )
        return {};

    // 2nd - now start to greadily look for longest substrings - O(n^2)
    std::array<char, 16384> mem_buffer;
    std::pmr::monotonic_buffer_resource mem_resource(mem_buffer.data(), mem_buffer.size());
    std::pmr::vector<QuickSearchHighlight::Range> found(&mem_resource);
    unsigned long filename_pos = 0;
    NSString *text = _text;
    while( true ) {
        const size_t text_length = text.length;
        if( text_length == 0 ) {
            break; // done.
        }

        for( size_t length = text_length; true; --length ) {
            if( length == 0 ) {
                return {}; // invalid case?
            }

            const NSRange result = [_filename rangeOfString:[text substringToIndex:length]
                                                    options:NSCaseInsensitiveSearch
                                                      range:NSMakeRange(filename_pos, filename_len - filename_pos)];
            if( result.length == 0 ) {
                continue; // cannot found a substring this long
            }

            // found one, check that the whole criterion is still satisfiable
            if( !FuzzySearchSatisfiable(
                    cf_filename.get(), filename_len, result.location + result.length, text, length) ) {
                continue; // too greedy - the rest of the criterion is not satisfiable
            }

            // ok, seems legit, memorize and carry on with the leftovers
            found.push_back({.offset = result.location, .length = result.length});
            filename_pos = result.location + result.length;
            text = [text substringFromIndex:result.length];
            break;
        }
    }

    return QuickSearchHighlight({found.data(), found.size()}); // might discard some results here
}

namespace {

// The characters CFStringTransform knows how to transliterate for us.
constexpr bool IsIdeograph(unichar _c) noexcept
{
    return (_c >= 0x3040 && _c <= 0x30FF) || // hiragana, katakana
           (_c >= 0x3400 && _c <= 0x4DBF) || // CJK unified ideographs extension A
           (_c >= 0x4E00 && _c <= 0x9FFF) || // CJK unified ideographs
           (_c >= 0xF900 && _c <= 0xFAFF) || // CJK compatibility ideographs
           (_c >= 0xFF66 && _c <= 0xFF9F);   // halfwidth katakana
}

struct Initials {
    std::string text;
    // for every character of 'text' - the index of the name character it was made from
    std::vector<unsigned> sources;
};

// What can a latin-only criterion possibly match? Only names carrying ideographs have initials.
bool BuildInitials(NSString *_name, Initials &_out) noexcept
{
    _out.text.clear();
    _out.sources.clear();
    bool any_ideograph = false;

    const NSUInteger len = _name.length;
    NSUInteger idx = 0;
    while( idx < len ) {
        const unichar c = [_name characterAtIndex:idx];
        if( !IsIdeograph(c) ) {
            if( (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ) {
                _out.text += static_cast<char>(std::tolower(static_cast<int>(c)));
                _out.sources.push_back(static_cast<unsigned>(idx));
            }
            ++idx;
            continue;
        }

        NSUInteger end = idx;
        while( end < len && IsIdeograph([_name characterAtIndex:end]) )
            ++end;
        const NSUInteger run_len = end - idx;

        NSString *const run = [_name substringWithRange:NSMakeRange(idx, run_len)];
        NSMutableString *const latin = [run mutableCopy];
        const bool transliterated =
            CFStringTransform((__bridge CFMutableStringRef)latin, nullptr, kCFStringTransformToLatin, false) &&
            CFStringTransform(
                (__bridge CFMutableStringRef)latin, nullptr, kCFStringTransformStripCombiningMarks, false);
        if( transliterated ) {
            any_ideograph = true;
            // the transliteration separates the syllables of a run with spaces
            NSArray<NSString *> *const syllables = [[latin lowercaseString] componentsSeparatedByString:@" "];
            for( NSUInteger i = 0; i < syllables.count; ++i ) {
                NSString *const syllable = syllables[i];
                if( syllable.length == 0 )
                    continue;
                const unichar first = [syllable characterAtIndex:0];
                if( first >= 'a' && first <= 'z' ) {
                    _out.text += static_cast<char>(first);
                    _out.sources.push_back(static_cast<unsigned>(idx + std::min(i, run_len - 1)));
                }
            }
        }
        idx = end;
    }
    return any_ideograph;
}

// Transliteration is not free, while the quick search runs over the whole listing on every
// keystroke - remember what has already been computed for this thread.
const Initials &CachedInitials(NSString *_name) noexcept
{
    [[clang::no_destroy]] static thread_local std::unordered_map<std::string, Initials> cache;
    const char *const utf8 = _name.UTF8String;
    std::string key = utf8 != nullptr ? utf8 : "";
    if( const auto it = cache.find(key); it != cache.end() )
        return it->second;
    if( cache.size() >= 8192 )
        cache.clear();
    Initials value;
    if( !BuildInitials(_name, value) )
        value = Initials{};
    return cache.emplace(std::move(key), std::move(value)).first->second;
}

bool IsLatinOnly(NSString *_text) noexcept
{
    if( _text.length == 0 )
        return false;
    for( NSUInteger i = 0; i < _text.length; ++i ) {
        const unichar c = [_text characterAtIndex:i];
        if( !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) )
            return false;
    }
    return true;
}

} // namespace

std::string PinyinInitialsForName(NSString *_name) noexcept
{
    return CachedInitials(_name).text;
}

std::optional<QuickSearchHighlight>
PinyinInitialsSearch(NSString *_name, NSString *_text, TextualFilter::Where _type) noexcept
{
    if( !IsLatinOnly(_text) )
        return std::nullopt;

    const Initials &initials = CachedInitials(_name);
    if( initials.text.empty() )
        return std::nullopt;

    const char *const needle_utf8 = _text.UTF8String;
    if( needle_utf8 == nullptr )
        return std::nullopt;
    std::string needle{needle_utf8};
    std::transform(needle.begin(), needle.end(), needle.begin(), [](unsigned char _c) {
        return static_cast<char>(std::tolower(_c));
    });

    // where in the initials does the criterion sit?
    size_t begin = std::string::npos;
    if( _type == TextualFilter::Where::Fuzzy ) {
        size_t pos = 0;
        for( const char c : needle ) {
            const size_t found = initials.text.find(c, pos);
            if( found == std::string::npos )
                return std::nullopt;
            if( begin == std::string::npos )
                begin = found;
            pos = found + 1;
        }
        if( begin == std::string::npos )
            return std::nullopt;
        // the fuzzy case matches a sparse sequence - cover the whole span with one range
        const size_t last = pos - 1;
        QuickSearchHighlight::Range range{.offset = initials.sources[begin],
                                          .length = initials.sources[last] + 1 - initials.sources[begin]};
        return QuickSearchHighlight({&range, 1});
    }

    if( _type == TextualFilter::Where::Beginning || _type == TextualFilter::Where::BeginningOrEnding ) {
        if( initials.text.compare(0, needle.size(), needle) == 0 )
            begin = 0;
    }
    if( begin == std::string::npos &&
        (_type == TextualFilter::Where::Ending || _type == TextualFilter::Where::BeginningOrEnding) ) {
        if( initials.text.size() >= needle.size() &&
            initials.text.compare(initials.text.size() - needle.size(), needle.size(), needle) == 0 )
            begin = initials.text.size() - needle.size();
    }
    if( begin == std::string::npos && _type == TextualFilter::Where::Anywhere )
        begin = initials.text.find(needle);

    if( begin == std::string::npos )
        return std::nullopt;

    QuickSearchHighlight::Range range{.offset = initials.sources[begin],
                                      .length =
                                          initials.sources[begin + needle.size() - 1] + 1 - initials.sources[begin]};
    return QuickSearchHighlight({&range, 1});
}

namespace {

struct CompiledRegex {
    NSRegularExpression *expression = nil; // nil when the pattern doesn't compile (yet)
};

// Patterns would be recompiled on every keystroke otherwise - and the filter walks the whole listing.
CompiledRegex &CachedRegex(NSString *_pattern) noexcept
{
    [[clang::no_destroy]] static thread_local std::unordered_map<std::string, CompiledRegex> cache;
    const char *const utf8 = _pattern.UTF8String;
    std::string key = utf8 != nullptr ? utf8 : "";
    if( const auto it = cache.find(key); it != cache.end() )
        return it->second;
    if( cache.size() >= 2048 )
        cache.clear();
    CompiledRegex value;
    NSError *error = nil;
    value.expression = [NSRegularExpression regularExpressionWithPattern:_pattern
                                                                 options:NSRegularExpressionCaseInsensitive
                                                                   error:&error];
    return cache.emplace(std::move(key), value).first->second;
}

} // namespace

std::optional<QuickSearchHighlight> RegexSearch(NSString *_name, NSString *_text) noexcept
{
    if( _text.length == 0 )
        return QuickSearchHighlight{}; // an empty expression matches everything

    NSRegularExpression *const expression = CachedRegex(_text).expression;
    if( expression == nil )
        return std::nullopt; // not a valid expression (yet)

    NSArray<NSTextCheckingResult *> *const matches = [expression matchesInString:_name
                                                                         options:0
                                                                           range:NSMakeRange(0, _name.length)];
    if( matches.count == 0 )
        return std::nullopt;

    std::array<QuickSearchHighlight::Range, QuickSearchHighlight::max_len> ranges;
    size_t count = 0;
    for( NSTextCheckingResult *const match in matches ) {
        if( count >= ranges.size() )
            break;
        if( match.range.length == 0 )
            continue; // zero-width match - nothing to highlight
        ranges[count++] = {.offset = match.range.location, .length = match.range.length};
    }
    if( count == 0 )
        return std::nullopt;
    return QuickSearchHighlight({ranges.data(), count});
}

bool TextualFilter::IsValidItem(const VFSListingItem &_item, QuickSearchHighlight &_found_range) const
{
    _found_range = {};

    if( text == nil )
        return true; // nothing to filter with - just say yes

    if( ignore_dot_dot && _item.IsDotDot() )
        return true; // never filter out the Holy Dot-Dot directory!

    const auto textlen = text.length;
    if( textlen == 0 )
        return true; // will return true on any item with @"" filter

    NSString *const name = _item.DisplayNameNS();

    // A name carrying ideographs can also be reached through the initials of its transliteration,
    // so that "下载" answers to "xz" - the literal comparison below knows nothing about that.
    if( auto pinyin = PinyinInitialsSearch(name, text, type) ) {
        _found_range = *pinyin;
        return true;
    }

    const auto namelen = name.length;
    if( textlen > namelen )
        return false; // unsatisfiable by definition

    if( type == Regex ) {
        if( auto res = RegexSearch(name, text) ) {
            _found_range = *res;
            return true;
        }
        return false;
    }

    if( type == Anywhere ) {
        const NSRange result = [name rangeOfString:text options:NSCaseInsensitiveSearch];
        if( result.length == 0 )
            return false;

        QuickSearchHighlight::Range hlrange;
        hlrange.offset = result.location;
        hlrange.length = result.length;
        _found_range = QuickSearchHighlight({&hlrange, 1});
        return true;
    }
    else if( type == Beginning ) {
        const NSRange result = [name rangeOfString:text options:NSCaseInsensitiveSearch | NSAnchoredSearch];

        if( result.length == 0 )
            return false;

        QuickSearchHighlight::Range hlrange;
        hlrange.offset = result.location;
        hlrange.length = result.length;
        _found_range = QuickSearchHighlight({&hlrange, 1});
        return true;
    }
    else if( type == Ending || type == BeginningOrEnding ) {
        if( type == BeginningOrEnding ) { // look at beginning
            const NSRange result = [name rangeOfString:text options:NSCaseInsensitiveSearch | NSAnchoredSearch];
            if( result.length != 0 ) {
                QuickSearchHighlight::Range hlrange;
                hlrange.offset = result.location;
                hlrange.length = result.length;
                _found_range = QuickSearchHighlight({&hlrange, 1});
                return true;
            }
        }

        if( _item.HasExtension() ) {
            // slow path here - look before extension
            const NSRange dotrange = [name rangeOfString:@"." options:NSBackwardsSearch];
            if( dotrange.length != 0 && dotrange.location > textlen ) {
                const NSRange result =
                    [name rangeOfString:text
                                options:NSCaseInsensitiveSearch | NSAnchoredSearch | NSBackwardsSearch
                                  range:NSMakeRange(dotrange.location - textlen, textlen)];
                if( result.length != 0 ) {
                    QuickSearchHighlight::Range hlrange;
                    hlrange.offset = result.location;
                    hlrange.length = result.length;
                    _found_range = QuickSearchHighlight({&hlrange, 1});
                    return true;
                }
            }
        }

        // look at the end at last
        const NSRange result = [name rangeOfString:text
                                           options:NSCaseInsensitiveSearch | NSAnchoredSearch | NSBackwardsSearch];
        if( result.length != 0 ) {
            QuickSearchHighlight::Range hlrange;
            hlrange.offset = result.location;
            hlrange.length = result.length;
            _found_range = QuickSearchHighlight({&hlrange, 1});
            return true;
        }
        else
            return false;
    }
    else if( type == Fuzzy ) {
        if( auto res = FuzzySearch(name, text) ) {
            _found_range = *res;
            return true;
        }
        else {
            return false;
        }
    }
    return false;
}

void TextualFilter::OnPanelDataLoad()
{
    if( clear_on_new_listing )
        text = nil;
}

bool TextualFilter::IsFiltering() const noexcept
{
    return text != nil && text.length > 0;
}

//////////////////////////////////////////////////////////////////////////////////////////////////////
// HardFilter
//////////////////////////////////////////////////////////////////////////////////////////////////////

bool HardFilter::IsValidItem(const VFSListingItem &_item, QuickSearchHighlight &_found_range) const
{
    if( !show_hidden && _item.IsHidden() )
        return false;

    return text.IsValidItem(_item, _found_range);
}

bool HardFilter::IsFiltering() const noexcept
{
    return !show_hidden || text.IsFiltering();
}

} // namespace nc::panel::data
