// Copyright (C) 2026 cfanmaoli. Subject to GNU General Public License version 3.
#pragma once

#include <Foundation/Foundation.h>
#include <cctype>
#include <cstring>
#include <map>
#include <string>
#include <vector>

// Internal format validation, shared by language-pack import and its unit tests.
namespace nc::lang::detail {

inline BOOL LooksLikeObjectIdentifier(NSString *_key)
{
    if( _key.length == 0 )
        return NO;
    static NSRegularExpression *const dot_number = [NSRegularExpression regularExpressionWithPattern:@"^[0-9]+\\."
                                                                                             options:0
                                                                                               error:nil];
    static NSRegularExpression *const ib_identifier =
        [NSRegularExpression regularExpressionWithPattern:@"^[0-9A-Za-z]{3}-[0-9A-Za-z]{3}-[0-9A-Za-z]{3}\\."
                                                  options:0
                                                    error:nil];
    const NSRange range = NSMakeRange(0, _key.length);
    return [dot_number firstMatchInString:_key options:0 range:range] != nil ||
           [ib_identifier firstMatchInString:_key options:0 range:range] != nil;
}

// One printf-style conversion: which argument it consumes and what kind it expects.
struct Placeholder {
    int position = 0; // 1-based argument index, explicit ("%2$@") or sequential
    std::string kind; // exact conversion argument type, including width/length
};

struct PlaceholderList {
    std::vector<Placeholder> items;
    bool has_unknown = false;     // a conversion that can't be parsed or isn't on the allowlist
    bool mixed_positions = false; // some conversions are positional, some are not (undefined in printf)
};

inline PlaceholderList ParsePlaceholders(NSString *_string)
{
    PlaceholderList result;
    if( _string.length == 0 )
        return result;
    const std::string s = _string.UTF8String;
    int next_sequential = 1;
    bool saw_positional = false;
    bool saw_sequential = false;
    for( std::size_t i = 0; i < s.size(); ) {
        if( s[i] != '%' ) {
            ++i;
            continue;
        }
        std::size_t j = i + 1;
        if( j < s.size() && s[j] == '%' ) { // literal per cent
            i = j + 1;
            continue;
        }
        const std::size_t position_start = j;
        while( j < s.size() && std::isdigit(static_cast<unsigned char>(s[j])) )
            ++j;
        int position = 0;
        bool positional = false;
        if( j > position_start && j < s.size() && s[j] == '$' ) {
            positional = true;
            const std::string digits = s.substr(position_start, j - position_start);
            if( digits.size() > 6 ) {
                result.has_unknown = true;
            }
            else {
                position = std::stoi(digits);
            }
            ++j;
        }
        while( j < s.size() && std::strchr("-+ #0", s[j]) )
            ++j; // flags
        while( j < s.size() && std::isdigit(static_cast<unsigned char>(s[j])) )
            ++j; // field width
        if( j < s.size() && s[j] == '.' ) {
            ++j;
            while( j < s.size() && std::isdigit(static_cast<unsigned char>(s[j])) )
                ++j;
        }
        const std::size_t length_start = j;
        while( j < s.size() && std::strchr("hlqLjzt", s[j]) )
            ++j;
        std::string length = s.substr(length_start, j - length_start);
        if( length == "q" )
            length = "ll"; // documented synonym for long long
        if( j >= s.size() ) {
            // A trailing '%', or a '%' followed by modifiers that never reach a conversion, is
            // ordinary text ("Progress 100%"). It consumes no argument.
            ++i;
            continue;
        }
        const char conversion = s[j++];
        std::string kind;
        const bool integer_length = length.empty() || length == "hh" || length == "h" || length == "l" ||
                                    length == "ll" || length == "j" || length == "z" || length == "t";
        switch( conversion ) {
            case '@':
                if( length.empty() )
                    kind = "object";
                break;
            case 'd':
            case 'i':
                if( integer_length )
                    kind = "signed:" + length;
                break;
            case 'u':
            case 'x':
            case 'X':
            case 'o':
                if( integer_length )
                    kind = "unsigned:" + length;
                break;
            case 'c':
            case 'C':
                if( length.empty() || (conversion == 'c' && length == "l") )
                    kind = std::string("character:") + conversion + length;
                break;
            case 'f':
            case 'F':
            case 'e':
            case 'E':
            case 'g':
            case 'G':
            case 'a':
            case 'A':
                if( length.empty() || length == "l" )
                    kind = "double"; // printf's 'l' does not change floating argument width
                else if( length == "L" )
                    kind = "long double";
                break;
            case 's':
            case 'S':
                if( length.empty() || (conversion == 's' && length == "l") )
                    kind = std::string("string:") + conversion + length;
                break;
            case 'p':
                if( length.empty() )
                    kind = "pointer";
                break;
            default:
                break;
        }
        if( kind.empty() ) {
            // printf's "*" supplies the width or the precision from an extra argument. This
            // validator doesn't model those argument positions yet, so refuse the string instead of
            // treating the "*" as literal text - the latter let "%*d" pass as a plain percent and
            // under-counted the arguments the format really consumes.
            if( conversion == '*' ) {
                result.has_unknown = true;
                ++i;
                continue;
            }
            // A '%' followed by a character that can't start a conversion is a literal percent sign
            // in the original text ("Percentage (%)", "%? Enter the value of the parameter"): it
            // consumes no argument and doesn't invalidate the string. A conversion that printf does
            // know but this validator refuses - %n, a bogus length modifier like %l@ or %hs - stays
            // an error.
            if( std::strchr("diouxXeEfFgGaAcsSpnC@", conversion) == nullptr ) {
                ++i; // only the '%' is literal - the rest has to be parsed again
                continue;
            }
            result.has_unknown = true;
        }
        if( positional ) {
            saw_positional = true;
            if( position <= 0 )
                result.has_unknown = true;
        }
        else {
            saw_sequential = true;
            position = next_sequential++;
        }
        result.items.push_back({.position = position, .kind = kind});
        i = j;
    }
    result.mixed_positions = saw_positional && saw_sequential;
    return result;
}

inline bool CompareArguments(const PlaceholderList &_source, const PlaceholderList &_translation)
{
    std::map<int, std::string> expected;
    for( const Placeholder &p : _source.items ) {
        const auto [it, inserted] = expected.emplace(p.position, p.kind);
        if( !inserted && it->second != p.kind )
            return false; // one argument used with two different kinds
    }
    std::map<int, std::string> actual;
    for( const Placeholder &p : _translation.items ) {
        const auto [it, inserted] = actual.emplace(p.position, p.kind);
        if( !inserted && it->second != p.kind )
            return false;
    }
    return expected == actual;
}

inline bool PlaceholdersCompatible(NSString *_source, NSString *_key, NSString *_translation)
{
    const PlaceholderList source = ParsePlaceholders(_source);
    const PlaceholderList translation = ParsePlaceholders(_translation);
    // A translation with an unparsable conversion ("%n"), an out-of-range argument or a mix of
    // positional and sequential ones is never accepted.
    if( translation.has_unknown || translation.mixed_positions )
        return false;
    // Literal percent signs in old reference text may be ambiguous; the translation must still
    // contain only valid conversions even when the reference cannot be compared.
    if( source.has_unknown || source.mixed_positions )
        return true;
    // A plural source ("Compressing %#@items@") consumes the count and expands it to a localized
    // string; a translation written as a plain format must therefore use the *non-plural* form from
    // the key ("%d"), not an object placeholder.
    if( [_source rangeOfString:@"%#@"].location != NSNotFound && !LooksLikeObjectIdentifier(_key) ) {
        const PlaceholderList key_placeholders = ParsePlaceholders(_key);
        if( !key_placeholders.has_unknown && !key_placeholders.mixed_positions )
            return CompareArguments(key_placeholders, translation);
    }
    return CompareArguments(source, translation);
}

} // namespace nc::lang::detail
