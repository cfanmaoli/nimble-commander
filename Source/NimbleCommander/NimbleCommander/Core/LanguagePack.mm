// Copyright (C) 2026 cfanmaoli. Subject to GNU General Public License version 3.
#include "LanguagePack.h"

#include <Cocoa/Cocoa.h>
#include <objc/runtime.h>

#include <algorithm>
#include <cctype>
#include <cstring>
#include <fstream>
#include <limits>
#include <map>
#include <unistd.h>
#include <set>
#include <string>

@interface NSBundle (NCLanguagePack)
- (NSString *)nc_langpack_localizedStringForKey:(NSString *)_key value:(NSString *)_value table:(NSString *)_table;
@end

namespace {

NSString *const kPackFormat = @"nimble-commander-language-pack";
const long kPackFormatVersion = 1;

// A pack is a plain JSON file written by this app; anything past these limits is treated as hostile
// rather than as a big translation.
constexpr unsigned long long kMaxPackFileSize = 64ull * 1024 * 1024;
constexpr NSUInteger kMaxPackEntries = 200'000;
constexpr NSUInteger kMaxPackKeyLength = 8ul * 1024;
constexpr NSUInteger kMaxPackTranslationLength = 64ul * 1024;
NSString *const kManifestFileName = @"LocalizationManifest.json";
NSString *const kActiveFileName = @"active.txt";
NSString *const kDefaultTable = @"Localizable";
NSString *const kInfoPlistTable = @"InfoPlist";
NSString *const kSeparator = @"\x1f";

// bundle -> table -> key -> value. Installed once in +load, never mutated afterwards, so
// lookups from any thread are safe.
NSDictionary<NSString *, NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *> *g_overlay = nil;
NSArray<NSDictionary *> *g_manifest_entries = nil;
NSBundle *g_main_bundle = nil;
std::size_t g_active_entries = 0;
[[clang::no_destroy]] std::string g_active_language;
[[clang::no_destroy]] std::string g_active_display_name;
std::size_t g_active_translated = std::numeric_limits<std::size_t>::max();

NSString *ISODateString()
{
    static NSISO8601DateFormatter *const formatter = [[NSISO8601DateFormatter alloc] init];
    return [formatter stringFromDate:NSDate.date];
}

std::string ErrorText(NSError *_error, const char *_fallback)
{
    NSString *const description = _error.localizedDescription;
    return description.length ? description.UTF8String : std::string{_fallback};
}

std::string Trim(std::string _s)
{
    const auto not_space = [](unsigned char _c) { return !std::isspace(_c); };
    _s.erase(_s.begin(), std::ranges::find_if(_s, not_space));
    _s.erase(std::ranges::find_if(_s.rbegin(), _s.rend(), not_space).base(), _s.end());
    return _s;
}

bool IsValidPackIdentifier(const std::string &_s)
{
    if( _s.empty() || _s.size() > 64 || _s == "." || _s == ".." )
        return false;
    return std::ranges::all_of(
        _s, [](unsigned char _c) { return std::isalnum(_c) || _c == '-' || _c == '_' || _c == '.'; });
}

std::string SanitizePackIdentifier(const std::string &_s)
{
    std::string result;
    for( char c : _s ) {
        const auto u = static_cast<unsigned char>(c);
        result += (std::isalnum(u) || c == '-' || c == '_' || c == '.') ? c : '-';
    }
    if( result.size() > 64 )
        result.resize(64);
    return IsValidPackIdentifier(result) ? result : "imported";
}

NSString *FromPath(const std::filesystem::path &_path)
{
    return [NSString stringWithUTF8String:_path.c_str()];
}

NSString *BundleKeyForBundle(NSBundle *_bundle)
{
    if( _bundle == nil || _bundle == g_main_bundle )
        return @"";
    return _bundle.bundlePath.lastPathComponent ?: @"";
}

std::filesystem::path PackFileFor(const std::string &_identifier)
{
    return nc::lang::PacksDirectory() / (_identifier + ".json");
}

NSString *EntryKey(NSString *_bundle, NSString *_table, NSString *_key)
{
    return
        [NSString stringWithFormat:@"%@%@%@%@%@", _bundle ?: @"", kSeparator, _table ?: @"", kSeparator, _key ?: @""];
}

BOOL LooksLikeObjectIdentifier(NSString *_key)
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
    char kind = '?';  // O = object, I = integer, F = float, S = C string, P = pointer, ? = unknown
};

struct PlaceholderList {
    std::vector<Placeholder> items;
    bool has_unknown = false;     // a conversion that can't be parsed or isn't on the allowlist
    bool mixed_positions = false; // some conversions are positional, some are not (undefined in printf)
};

PlaceholderList ParsePlaceholders(NSString *_string)
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
        while( j < s.size() && std::strchr("hlqLjzt", s[j]) )
            ++j; // length modifier
        if( j >= s.size() ) {
            result.has_unknown = true;
            break;
        }
        const char conversion = s[j++];
        char kind = '?';
        switch( conversion ) {
            case '@':
                kind = 'O';
                break;
            case 'd':
            case 'i':
            case 'u':
            case 'x':
            case 'X':
            case 'o':
            case 'c':
            case 'C':
                kind = 'I';
                break;
            case 'f':
            case 'F':
            case 'e':
            case 'E':
            case 'g':
            case 'G':
            case 'a':
            case 'A':
                kind = 'F';
                break;
            case 's':
            case 'S':
                kind = 'S';
                break;
            case 'p':
                kind = 'P';
                break;
            case '#': // the "%#@name@" plural form stands for the number of items
                if( j < s.size() && s[j] == '@' ) {
                    ++j;
                    while( j < s.size() && s[j] != '@' )
                        ++j;
                    if( j < s.size() )
                        ++j;
                }
                kind = 'O';
                break;
            default:
                kind = '?';
                break;
        }
        if( kind == '?' )
            result.has_unknown = true;
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

bool CompareArguments(const PlaceholderList &_source, const PlaceholderList &_translation)
{
    std::map<int, char> expected;
    for( const Placeholder &p : _source.items ) {
        const auto [it, inserted] = expected.emplace(p.position, p.kind);
        if( !inserted && it->second != p.kind )
            return false; // one argument used with two different kinds
    }
    std::map<int, char> actual;
    for( const Placeholder &p : _translation.items ) {
        const auto [it, inserted] = actual.emplace(p.position, p.kind);
        if( !inserted && it->second != p.kind )
            return false;
    }
    return expected == actual;
}

bool PlaceholdersCompatible(NSString *_source, NSString *_key, NSString *_translation)
{
    const PlaceholderList source = ParsePlaceholders(_source);
    const PlaceholderList translation = ParsePlaceholders(_translation);
    // The reference string comes from the app, so if it can't be parsed the translation can't be
    // judged - don't reject a perfectly good pack over it.
    if( source.has_unknown || source.mixed_positions )
        return true;
    // A translation with an unparsable conversion ("%n"), an out-of-range argument or a mix of
    // positional and sequential ones is never accepted.
    if( translation.has_unknown || translation.mixed_positions )
        return false;
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

NSArray<NSBundle *> *RelevantBundles()
{
    NSBundle *const main_bundle = g_main_bundle ?: NSBundle.mainBundle;
    NSMutableArray<NSBundle *> *result = [NSMutableArray arrayWithObject:main_bundle];
    NSString *const resources = main_bundle.resourcePath;
    if( resources.length ) {
        NSArray<NSString *> *const items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:resources
                                                                                               error:nil];
        for( NSString *item in [items sortedArrayUsingSelector:@selector(compare:)] )
            if( [item.pathExtension isEqualToString:@"bundle"] ) {
                NSBundle *const bundle = [NSBundle bundleWithPath:[resources stringByAppendingPathComponent:item]];
                if( bundle )
                    [result addObject:bundle];
            }
    }
    return result;
}

NSString *CurrentLprojPath(NSBundle *_bundle)
{
    // When a built-in language is selected explicitly, export/import must look at that language's
    // lproj - the bundle's preferred localizations still follow the system language.
    if( !g_active_language.empty() ) {
        NSString *const candidate = [_bundle.resourcePath
            stringByAppendingPathComponent:[@(g_active_language.c_str()) stringByAppendingPathExtension:@"lproj"]];
        if( [[NSFileManager defaultManager] fileExistsAtPath:candidate] )
            return candidate;
    }
    NSString *const localizable = [_bundle pathForResource:@"Localizable" ofType:@"strings"];
    if( localizable.length )
        return localizable.stringByDeletingLastPathComponent;
    for( NSString *language in _bundle.preferredLocalizations ) {
        NSString *const candidate =
            [_bundle.resourcePath stringByAppendingPathComponent:[language stringByAppendingPathExtension:@"lproj"]];
        if( [[NSFileManager defaultManager] fileExistsAtPath:candidate] )
            return candidate;
    }
    return nil;
}

NSString *ManifestPath()
{
    if( NSString *const resources = (g_main_bundle ?: NSBundle.mainBundle).resourcePath ) {
        NSString *const path = [resources stringByAppendingPathComponent:kManifestFileName];
        if( [[NSFileManager defaultManager] fileExistsAtPath:path] )
            return path;
    }
    NSString *const path = FromPath(nc::lang::PacksDirectory() / kManifestFileName.UTF8String);
    return [[NSFileManager defaultManager] fileExistsAtPath:path] ? path : nil;
}

NSArray<NSDictionary *> *ManifestEntries()
{
    if( g_manifest_entries )
        return g_manifest_entries;
    NSString *const path = ManifestPath();
    if( path == nil )
        return nil;
    NSData *const data = [NSData dataWithContentsOfFile:path];
    if( data.length == 0 )
        return nil;
    const id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if( ![root isKindOfClass:NSDictionary.class] )
        return nil;
    NSArray *const entries = (static_cast<NSDictionary *>(root))[@"entries"];
    if( ![entries isKindOfClass:NSArray.class] )
        return nil;
    g_manifest_entries = entries;
    return g_manifest_entries;
}

NSDictionary<NSString *, NSDictionary *> *ManifestIndex()
{
    static NSDictionary<NSString *, NSDictionary *> *const index = []() -> NSDictionary<NSString *, NSDictionary *> * {
        NSArray<NSDictionary *> *const entries = ManifestEntries();
        if( entries == nil )
            return nil;
        NSMutableDictionary *result = [NSMutableDictionary dictionaryWithCapacity:entries.count];
        for( NSDictionary *entry in entries ) {
            if( ![entry isKindOfClass:NSDictionary.class] )
                continue;
            NSString *const bundle = [entry[@"bundle"] isKindOfClass:NSString.class] ? entry[@"bundle"] : @"";
            NSString *const table = [entry[@"table"] isKindOfClass:NSString.class] ? entry[@"table"] : kDefaultTable;
            NSString *const key = [entry[@"key"] isKindOfClass:NSString.class] ? entry[@"key"] : @"";
            if( key.length == 0 )
                continue;
            NSMutableDictionary *value = [NSMutableDictionary dictionary];
            if( [entry[@"source"] isKindOfClass:NSString.class] )
                value[@"en"] = entry[@"source"];
            if( [entry[@"comment"] isKindOfClass:NSString.class] )
                value[@"comment"] = entry[@"comment"];
            result[EntryKey(bundle, table, key)] = value;
        }
        return [result copy];
    }();
    return index;
}

NSMutableDictionary *
MakeEntry(NSString *_bundle, NSString *_table, NSString *_key, NSString *_translation, NSDictionary *_manifest_entry)
{
    NSString *source = [_manifest_entry[@"en"] isKindOfClass:NSString.class] ? _manifest_entry[@"en"] : nil;
    if( source.length == 0 )
        source = LooksLikeObjectIdentifier(_key) ? @"" : _key;
    NSMutableDictionary *const entry = [NSMutableDictionary dictionary];
    entry[@"bundle"] = _bundle ?: @"";
    entry[@"table"] = _table;
    entry[@"key"] = _key;
    entry[@"source"] = source ?: @"";
    entry[@"translation"] = _translation ?: @"";
    if( NSString *const comment = _manifest_entry[@"comment"]; [comment isKindOfClass:NSString.class] )
        // Interface Builder comments start with "Class = ..." and only repeat what the source already
        // says - keep only the ones a human wrote.
        if( comment.length && ![comment hasPrefix:@"Class = "] )
            entry[@"comment"] = comment;
    return entry;
}

std::string LanguageNameForCode(NSString *_code)
{
    if( _code.length == 0 )
        return {};
    // Say the name in the language the interface is running in, not in the one the system is
    // set to - otherwise an English interface lists the languages as "英语" and "日本語".
    NSString *const ui_language = g_active_language.empty()
                                      ? (g_main_bundle ?: NSBundle.mainBundle).preferredLocalizations.firstObject
                                      : @(g_active_language.c_str());
    NSLocale *const locale = ui_language.length ? [NSLocale localeWithLocaleIdentifier:ui_language] : nil;
    NSString *const name = [(locale ?: NSLocale.currentLocale) localizedStringForLanguageCode:_code];
    NSString *const result = name.length ? name : _code;
    return result.UTF8String;
}

void AddOverlayEntry(NSMutableDictionary *_overlay,
                     NSString *_bundle,
                     NSString *_table,
                     NSString *_key,
                     NSString *_value)
{
    NSMutableDictionary *by_table = _overlay[_bundle];
    if( by_table == nil ) {
        by_table = [NSMutableDictionary dictionary];
        _overlay[_bundle] = by_table;
    }
    NSMutableDictionary *by_key = by_table[_table];
    if( by_key == nil ) {
        by_key = [NSMutableDictionary dictionary];
        by_table[_table] = by_key;
    }
    by_key[_key] = _value;
}

// One of the languages the app itself ships: take everything from its .lproj folders and fill
// the gaps with the English source, so a partially localised language doesn't fall back to
// whatever the system language happens to be.
NSDictionary *BuildOverlayFromBuiltInLanguage(const std::string &_code, std::size_t &_count)
{
    NSMutableDictionary *const overlay = [NSMutableDictionary dictionary];
    _count = 0;
    NSString *const language = [NSString stringWithUTF8String:_code.c_str()];

    for( NSBundle *bundle in RelevantBundles() ) {
        NSString *const bundle_key = BundleKeyForBundle(bundle);
        NSString *const lproj =
            [bundle.resourcePath stringByAppendingPathComponent:[language stringByAppendingPathExtension:@"lproj"]];
        if( ![[NSFileManager defaultManager] fileExistsAtPath:lproj] )
            continue;
        NSArray<NSString *> *const files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:lproj error:nil];
        for( NSString *file in files ) {
            if( ![file.pathExtension isEqualToString:@"strings"] )
                continue;
            NSString *const table = file.stringByDeletingPathExtension;
            if( [table isEqualToString:kInfoPlistTable] )
                continue;
            NSDictionary *const strings =
                [NSDictionary dictionaryWithContentsOfFile:[lproj stringByAppendingPathComponent:file]];
            if( ![strings isKindOfClass:NSDictionary.class] )
                continue;
            for( NSString *key in strings ) {
                NSString *const value = strings[key];
                if( ![value isKindOfClass:NSString.class] || value.length == 0 )
                    continue;
                AddOverlayEntry(overlay, bundle_key, table, key, value);
                ++_count;
            }
        }
    }

    if( NSArray<NSDictionary *> *const manifest = ManifestEntries() )
        for( NSDictionary *entry in manifest ) {
            if( ![entry isKindOfClass:NSDictionary.class] )
                continue;
            NSString *const bundle_key = [entry[@"bundle"] isKindOfClass:NSString.class] ? entry[@"bundle"] : @"";
            NSString *const table = [entry[@"table"] isKindOfClass:NSString.class] ? entry[@"table"] : kDefaultTable;
            NSString *const key = [entry[@"key"] isKindOfClass:NSString.class] ? entry[@"key"] : @"";
            NSString *const source = [entry[@"source"] isKindOfClass:NSString.class] ? entry[@"source"] : @"";
            if( key.length == 0 || source.length == 0 || [table isEqualToString:kInfoPlistTable] )
                continue;
            if( overlay[bundle_key][table][key] != nil )
                continue;
            AddOverlayEntry(overlay, bundle_key, table, key, source);
            ++_count;
        }
    return [overlay copy];
}

void LoadActiveOverlay()
{
    const std::string selection = nc::lang::ActiveLanguageSelection();
    if( selection.empty() )
        return;

    bool built_in = false;
    std::string identifier = selection;
    if( selection.starts_with("builtin:") ) {
        built_in = true;
        identifier = selection.substr(8);
    }
    else if( selection.starts_with("pack:") ) {
        identifier = selection.substr(5);
    }
    if( identifier.empty() )
        return;

    std::size_t count = 0;
    if( built_in ) {
        g_overlay = BuildOverlayFromBuiltInLanguage(identifier, count);
        g_active_entries = count;
        g_active_translated = std::numeric_limits<std::size_t>::max();
        g_active_language = identifier;
        g_active_display_name = LanguageNameForCode([NSString stringWithUTF8String:identifier.c_str()]);
        return;
    }

    NSData *const data = [NSData dataWithContentsOfFile:FromPath(PackFileFor(identifier))];
    if( data.length == 0 )
        return;
    NSDictionary *const pack = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if( ![pack isKindOfClass:NSDictionary.class] )
        return;
    NSArray *const entries = pack[@"entries"];
    if( ![entries isKindOfClass:NSArray.class] )
        return;

    NSMutableDictionary *overlay = [NSMutableDictionary dictionary];
    for( NSDictionary *entry in entries ) {
        if( ![entry isKindOfClass:NSDictionary.class] )
            continue;
        NSString *const key = [entry[@"key"] isKindOfClass:NSString.class] ? entry[@"key"] : @"";
        NSString *const translation =
            [entry[@"translation"] isKindOfClass:NSString.class] ? entry[@"translation"] : @"";
        if( key.length == 0 || translation.length == 0 )
            continue;
        AddOverlayEntry(overlay,
                        [entry[@"bundle"] isKindOfClass:NSString.class] ? entry[@"bundle"] : @"",
                        [entry[@"table"] isKindOfClass:NSString.class] ? entry[@"table"] : kDefaultTable,
                        key,
                        translation);
        ++count;
    }
    g_overlay = [overlay copy];
    g_active_entries = count;
    g_active_translated = [pack[@"translatedEntries"] isKindOfClass:NSNumber.class]
                              ? static_cast<std::size_t>([pack[@"translatedEntries"] unsignedLongLongValue])
                              : std::numeric_limits<std::size_t>::max();
    NSString *const language = [pack[@"language"] isKindOfClass:NSString.class] ? pack[@"language"] : @"";
    NSString *const language_name = [pack[@"languageName"] isKindOfClass:NSString.class] ? pack[@"languageName"] : @"";
    g_active_language = language.UTF8String ?: "";
    g_active_display_name = language_name.UTF8String ?: "";
    if( g_active_display_name.empty() )
        g_active_display_name = LanguageNameForCode([NSString stringWithUTF8String:g_active_language.c_str()]);
}

std::size_t CountCurrentLanguageEntries()
{
    std::size_t result = 0;
    for( NSBundle *bundle in RelevantBundles() ) {
        NSString *const lproj = CurrentLprojPath(bundle);
        if( lproj == nil )
            continue;
        NSArray<NSString *> *const files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:lproj error:nil];
        for( NSString *file in files ) {
            if( ![file.pathExtension isEqualToString:@"strings"] )
                continue;
            if( [[file stringByDeletingPathExtension] isEqualToString:kInfoPlistTable] )
                continue;
            NSDictionary *const strings =
                [NSDictionary dictionaryWithContentsOfFile:[lproj stringByAppendingPathComponent:file]];
            if( [strings isKindOfClass:NSDictionary.class] )
                result += strings.count;
        }
    }
    return result;
}

// What the app would show without any pack - used to tell "translated" from "still the text
// that was exported".
NSDictionary<NSString *, NSString *> *NativeStringsIndex()
{
    static NSDictionary<NSString *, NSString *> *const index = [] {
        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        for( NSBundle *bundle in RelevantBundles() ) {
            NSString *const lproj = CurrentLprojPath(bundle);
            if( lproj == nil )
                continue;
            NSString *const bundle_key = BundleKeyForBundle(bundle);
            NSArray<NSString *> *const files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:lproj
                                                                                                   error:nil];
            for( NSString *file in files ) {
                if( ![file.pathExtension isEqualToString:@"strings"] )
                    continue;
                NSString *const table = file.stringByDeletingPathExtension;
                if( [table isEqualToString:kInfoPlistTable] )
                    continue;
                NSDictionary *const strings =
                    [NSDictionary dictionaryWithContentsOfFile:[lproj stringByAppendingPathComponent:file]];
                if( ![strings isKindOfClass:NSDictionary.class] )
                    continue;
                for( NSString *key in strings )
                    if( [strings[key] isKindOfClass:NSString.class] )
                        result[EntryKey(bundle_key, table, key)] = strings[key];
            }
        }
        return [result copy];
    }();
    return index;
}

} // namespace

namespace nc::lang {

const std::filesystem::path &PacksDirectory()
{
    [[clang::no_destroy]] static const std::filesystem::path directory = [] {
        std::filesystem::path path;
        NSArray *const paths =
            NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, true);
        if( paths.count )
            path = std::filesystem::path(static_cast<NSString *>(paths[0]).fileSystemRepresentation);
        else
            path = std::filesystem::temp_directory_path();
        if( NSString *const executable = NSBundle.mainBundle.infoDictionary[@"CFBundleExecutable"]; executable.length )
            path /= executable.fileSystemRepresentation;
        path /= "LanguagePacks";
        std::error_code ec;
        std::filesystem::create_directories(path, ec);
        return path;
    }();
    return directory;
}

std::vector<std::string> BuiltInLanguages()
{
    @autoreleasepool {
        std::vector<std::string> result;
        // Russian is not offered: the project cannot maintain that translation. Users who want it can
        // import a language pack instead.
        for( NSString *language in(g_main_bundle ?: NSBundle.mainBundle).localizations )
            if( [language isKindOfClass:NSString.class] && ![language isEqualToString:@"Base"] &&
                ![language isEqualToString:@"ru"] )
                result.emplace_back(language.UTF8String);
        std::ranges::sort(result);
        result.erase(std::ranges::unique(result).begin(), result.end());
        return result;
    }
}

std::string ActiveLanguageSelection()
{
    std::ifstream in(PacksDirectory() / kActiveFileName.UTF8String);
    std::string selection;
    std::getline(in, selection);
    return Trim(selection);
}

void SetActiveLanguageSelection(const std::string &_selection)
{
    const std::filesystem::path file = PacksDirectory() / kActiveFileName.UTF8String;
    std::error_code ec;
    if( _selection.empty() ) {
        std::filesystem::remove(file, ec);
        return;
    }
    std::ofstream out(file, std::ios::trunc);
    out << _selection << "\n";
}

std::string ActivePackIdentifier()
{
    std::string selection = ActiveLanguageSelection();
    if( selection.starts_with("builtin:") )
        return {};
    if( selection.starts_with("pack:") )
        return selection.substr(5);
    return selection; // packs imported before the popup existed
}

void SetActivePackIdentifier(const std::string &_identifier)
{
    SetActiveLanguageSelection(_identifier.empty() ? std::string{} : "pack:" + _identifier);
}

std::size_t ActivePackEntryCount()
{
    return g_active_entries;
}

std::size_t ActivePackTranslatedCount()
{
    return g_active_translated;
}

std::string ActivePackLanguage()
{
    return g_active_language;
}

std::string ActivePackDisplayName()
{
    return g_active_display_name;
}

std::string CurrentLanguage()
{
    if( !g_active_language.empty() )
        return g_active_language;
    NSString *const language = (g_main_bundle ?: NSBundle.mainBundle).preferredLocalizations.firstObject;
    return language.length ? language.UTF8String : "en";
}

std::string DisplayNameForLanguage(const std::string &_language_code)
{
    return LanguageNameForCode([NSString stringWithUTF8String:_language_code.c_str()]);
}

std::size_t CurrentLanguageEntryCount()
{
    @autoreleasepool {
        return CountCurrentLanguageEntries();
    }
}

std::vector<PackInfo> ListPacks()
{
    @autoreleasepool {
        std::vector<PackInfo> result;
        NSArray<NSString *> *const files =
            [[NSFileManager defaultManager] contentsOfDirectoryAtPath:FromPath(PacksDirectory()) error:nil];
        for( NSString *file in [files sortedArrayUsingSelector:@selector(localizedStandardCompare:)] ) {
            if( ![file.pathExtension isEqualToString:@"json"] )
                continue;
            NSData *const data =
                [NSData dataWithContentsOfFile:[FromPath(PacksDirectory()) stringByAppendingPathComponent:file]];
            NSDictionary *const pack =
                data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            if( ![pack isKindOfClass:NSDictionary.class] )
                continue;
            PackInfo info;
            info.identifier = file.stringByDeletingPathExtension.UTF8String;
            info.path = PacksDirectory() / file.UTF8String;
            info.language = [pack[@"language"] isKindOfClass:NSString.class]
                                ? static_cast<NSString *>(pack[@"language"]).UTF8String
                                : info.identifier;
            info.display_name = [pack[@"languageName"] isKindOfClass:NSString.class]
                                    ? static_cast<NSString *>(pack[@"languageName"]).UTF8String
                                    : DisplayNameForLanguage(info.language);
            NSArray *const entries = pack[@"entries"];
            info.entries = [entries isKindOfClass:NSArray.class] ? entries.count : 0;
            if( [pack[@"translatedEntries"] isKindOfClass:NSNumber.class] )
                info.translated = static_cast<std::size_t>([pack[@"translatedEntries"] unsignedLongLongValue]);
            result.push_back(std::move(info));
        }
        return result;
    }
}

bool RemovePack(const std::string &_identifier, std::string &_error)
{
    if( !IsValidPackIdentifier(_identifier) ) {
        _error = "invalid identifier";
        return false;
    }
    std::error_code ec;
    const bool removed = std::filesystem::remove(PackFileFor(_identifier), ec);
    if( !removed && ec ) {
        _error = ec.message();
        return false;
    }
    if( ActivePackIdentifier() == _identifier )
        SetActivePackIdentifier({});
    return true;
}

bool ExportCurrentLanguage(const std::filesystem::path &_destination, std::string &_error)
{
    @autoreleasepool {
        NSDictionary<NSString *, NSDictionary *> *const manifest = ManifestIndex();
        NSMutableArray *const entries = [NSMutableArray array];
        NSMutableSet<NSString *> *const seen = [NSMutableSet set];

        for( NSBundle *bundle in RelevantBundles() ) {
            NSString *const bundle_key = BundleKeyForBundle(bundle);
            NSString *const lproj = CurrentLprojPath(bundle);
            if( lproj == nil )
                continue;
            NSArray<NSString *> *const files = [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:lproj
                                                                                                    error:nil]
                sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
            for( NSString *file in files ) {
                if( ![file.pathExtension isEqualToString:@"strings"] )
                    continue;
                NSString *const table = file.stringByDeletingPathExtension;
                if( [table isEqualToString:kInfoPlistTable] )
                    continue; // the OS reads these on its own, we can't override them anyway
                NSDictionary *const strings =
                    [NSDictionary dictionaryWithContentsOfFile:[lproj stringByAppendingPathComponent:file]];
                if( ![strings isKindOfClass:NSDictionary.class] )
                    continue;
                for( NSString *key in
                     [strings.allKeys sortedArrayUsingSelector:@selector(localizedStandardCompare:)] ) {
                    NSString *const value = strings[key];
                    if( ![value isKindOfClass:NSString.class] )
                        continue;
                    [entries
                        addObject:MakeEntry(bundle_key, table, key, value, manifest[EntryKey(bundle_key, table, key)])];
                    [seen addObject:EntryKey(bundle_key, table, key)];
                }
            }
        }

        // entries the manifest knows about but the current language has no value for
        if( NSArray<NSDictionary *> *const known = ManifestEntries() )
            for( NSDictionary *entry in known ) {
                if( ![entry isKindOfClass:NSDictionary.class] )
                    continue;
                NSString *const bundle_key = [entry[@"bundle"] isKindOfClass:NSString.class] ? entry[@"bundle"] : @"";
                NSString *const table =
                    [entry[@"table"] isKindOfClass:NSString.class] ? entry[@"table"] : kDefaultTable;
                NSString *const key = [entry[@"key"] isKindOfClass:NSString.class] ? entry[@"key"] : @"";
                if( key.length == 0 || [table isEqualToString:kInfoPlistTable] )
                    continue;
                NSString *const combined = EntryKey(bundle_key, table, key);
                if( [seen containsObject:combined] )
                    continue;
                [seen addObject:combined];
                [entries addObject:MakeEntry(bundle_key, table, key, @"", entry)];
            }

        const std::string current_language = CurrentLanguage();
        NSString *const language = [NSString stringWithUTF8String:current_language.c_str()];
        NSMutableDictionary *const root = [NSMutableDictionary dictionary];
        root[@"format"] = kPackFormat;
        root[@"formatVersion"] = @(kPackFormatVersion);
        root[@"application"] =
            (g_main_bundle ?: NSBundle.mainBundle).infoDictionary[@"CFBundleShortVersionString"] ?: @"";
        root[@"exportedAt"] = ISODateString();
        root[@"baseLanguage"] = language;
        root[@"language"] = language;
        root[@"languageName"] = [NSString stringWithUTF8String:DisplayNameForLanguage(current_language).c_str()];
        root[@"entryCount"] = @(entries.count);
        root[@"notes"] = @"Translate the 'translation' fields (or leave them empty to fall back to the "
                          "original string), set 'language' to your language code, then import this file "
                          "back into the app.";
        root[@"entries"] = entries;

        NSError *json_error = nil;
        NSData *const data = [NSJSONSerialization
            dataWithJSONObject:root
                       options:static_cast<NSJSONWritingOptions>(NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys)
                         error:&json_error];
        if( data == nil ) {
            _error = ErrorText(json_error, "unable to serialize the pack");
            return false;
        }
        NSError *write_error = nil;
        if( ![data writeToURL:[NSURL fileURLWithPath:FromPath(_destination)]
                      options:NSDataWritingAtomic
                        error:&write_error] ) {
            _error = ErrorText(write_error, "unable to write the file");
            return false;
        }
        return true;
    }
}

bool ImportPack(const std::filesystem::path &_source, ImportStats &_stats, std::string &_error)
{
    @autoreleasepool {
        NSDictionary *const attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:FromPath(_source)
                                                                                          error:nil];
        if( attributes == nil ) {
            _error = "unable to read the file";
            return false;
        }
        if( [attributes[NSFileSize] unsignedLongLongValue] > kMaxPackFileSize ) {
            _error = "the file is too large to be a language pack";
            return false;
        }

        NSData *const data = [NSData dataWithContentsOfFile:FromPath(_source)];
        if( data.length == 0 ) {
            _error = "unable to read the file";
            return false;
        }
        const id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if( ![root isKindOfClass:NSDictionary.class] ) {
            _error = "the file doesn't contain a JSON object";
            return false;
        }
        NSDictionary *const pack = root;

        // The exporter always writes these; a hand-written pack may omit them, but a pack that
        // claims a different format or a newer version must not be interpreted as if it were ours.
        NSString *const format = [pack[@"format"] isKindOfClass:NSString.class] ? pack[@"format"] : nil;
        if( format != nil && ![format isEqualToString:kPackFormat] ) {
            _error = "the file is not a Nimble Commander language pack";
            return false;
        }
        NSNumber *const format_version =
            [pack[@"formatVersion"] isKindOfClass:NSNumber.class] ? pack[@"formatVersion"] : nil;
        if( format_version != nil && format_version.longValue > kPackFormatVersion ) {
            _error = "the pack was made by a newer version of the app";
            return false;
        }

        NSArray *const entries = pack[@"entries"];
        if( ![entries isKindOfClass:NSArray.class] || entries.count == 0 ) {
            _error = "the file doesn't contain any entries";
            return false;
        }
        if( entries.count > kMaxPackEntries ) {
            _error = "the pack contains too many entries";
            return false;
        }

        std::string language = [pack[@"language"] isKindOfClass:NSString.class]
                                   ? static_cast<NSString *>(pack[@"language"]).UTF8String
                                   : std::string{};
        if( language.empty() )
            language = _source.stem().string();
        const std::string identifier = SanitizePackIdentifier(language);
        NSString *const language_name =
            [pack[@"languageName"] isKindOfClass:NSString.class] ? pack[@"languageName"] : nil;

        // A pack that was exported from the built-in language keeps that language's text for the
        // entries the author hasn't translated yet - point that out instead of silently mixing.
        NSString *const built_in_language = (g_main_bundle ?: NSBundle.mainBundle).preferredLocalizations.firstObject;
        const bool measure_untranslated =
            built_in_language.length &&
            ![built_in_language isEqualToString:[NSString stringWithUTF8String:identifier.c_str()]];
        NSDictionary<NSString *, NSString *> *const native = measure_untranslated ? NativeStringsIndex() : nil;
        NSDictionary *const manifest_index = ManifestIndex();
        _stats.measured_untranslated = measure_untranslated;

        NSMutableArray *const normalized = [NSMutableArray array];
        for( id item in entries ) {
            ++_stats.total;
            if( ![item isKindOfClass:NSDictionary.class] ) {
                ++_stats.skipped_malformed;
                continue;
            }
            NSDictionary *const entry = item;
            NSString *const key = [entry[@"key"] isKindOfClass:NSString.class] ? entry[@"key"] : @"";
            NSString *const table = [entry[@"table"] isKindOfClass:NSString.class] ? entry[@"table"] : kDefaultTable;
            NSString *const translation =
                [entry[@"translation"] isKindOfClass:NSString.class] ? entry[@"translation"] : @"";
            NSString *const bundle_key = [entry[@"bundle"] isKindOfClass:NSString.class] ? entry[@"bundle"] : @"";
            if( key.length == 0 || table.length == 0 || key.length > kMaxPackKeyLength ||
                bundle_key.length > kMaxPackKeyLength || translation.length > kMaxPackTranslationLength ) {
                ++_stats.skipped_malformed;
                continue;
            }
            // A pack may only translate strings this app actually has; anything else would let it
            // put arbitrary text into tables the app doesn't know about. The manifest entry also
            // carries the original text, which is the trustworthy base for the format check below -
            // the pack's own "source" field is written by whoever produced the file.
            NSDictionary *const manifest_entry =
                manifest_index != nil ? manifest_index[EntryKey(bundle_key, table, key)] : nil;
            if( manifest_index != nil && manifest_entry == nil ) {
                ++_stats.skipped_unknown;
                continue;
            }
            if( translation.length == 0 ) {
                ++_stats.skipped_empty;
                continue;
            }
            NSString *reference = [manifest_entry[@"en"] isKindOfClass:NSString.class] ? manifest_entry[@"en"] : nil;
            if( reference.length == 0 )
                reference = [entry[@"source"] isKindOfClass:NSString.class] ? entry[@"source"] : nil;
            if( reference.length == 0 && !LooksLikeObjectIdentifier(key) )
                reference = key;
            if( reference.length && !PlaceholdersCompatible(reference, key, translation) ) {
                // a missing or duplicated %@ would make the app crash or print garbage - refuse it
                ++_stats.skipped_placeholders;
                continue;
            }
            if( native ) {
                NSString *const built_in = native[EntryKey(bundle_key, table, key)];
                if( built_in && [built_in isEqualToString:translation] )
                    ++_stats.identical_to_current;
            }
            [normalized addObject:MakeEntry(bundle_key, table, key, translation, entry)];
            ++_stats.imported;
        }

        NSMutableDictionary *const out = [NSMutableDictionary dictionary];
        out[@"format"] = kPackFormat;
        out[@"formatVersion"] = @(kPackFormatVersion);
        out[@"importedAt"] = ISODateString();
        out[@"language"] = [NSString stringWithUTF8String:identifier.c_str()];
        out[@"languageName"] = language_name.length
                                   ? language_name
                                   : [NSString stringWithUTF8String:DisplayNameForLanguage(identifier).c_str()];
        out[@"entryCount"] = @(normalized.count);
        if( _stats.measured_untranslated )
            out[@"translatedEntries"] = @(_stats.imported - _stats.identical_to_current);
        out[@"entries"] = normalized;

        NSError *json_error = nil;
        NSData *const normalized_data = [NSJSONSerialization
            dataWithJSONObject:out
                       options:static_cast<NSJSONWritingOptions>(NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys)
                         error:&json_error];
        if( normalized_data == nil ) {
            _error = ErrorText(json_error, "unable to serialize the pack");
            return false;
        }
        // Importing over an existing pack replaces it; keep the previous copy next to it, so that
        // a typo in a translation doesn't silently destroy someone's work. Only the most recent
        // backup is kept - the file is named '<identifier>.json.backup'.
        NSString *const pack_path = FromPath(PackFileFor(identifier));
        NSFileManager *const fm = [NSFileManager defaultManager];
        if( [fm fileExistsAtPath:pack_path] ) {
            NSString *const backup_path = [pack_path stringByAppendingString:@".backup"];
            [fm removeItemAtPath:backup_path error:nil];
            [fm copyItemAtPath:pack_path toPath:backup_path error:nil];
        }

        NSError *write_error = nil;
        if( ![normalized_data writeToFile:pack_path options:NSDataWritingAtomic error:&write_error] ) {
            _error = ErrorText(write_error, "unable to write the pack");
            return false;
        }

        SetActivePackIdentifier(identifier);
        _stats.language = identifier;
        _stats.display_name =
            out[@"languageName"] ? static_cast<NSString *>(out[@"languageName"]).UTF8String : identifier;
        return true;
    }
}

void RelaunchApplication()
{
    @autoreleasepool {
        NSString *const bundle_path = (g_main_bundle ?: NSBundle.mainBundle).bundlePath;

        // Deliberately no AppleLanguages write here. Running the app under a per-app language
        // override makes AppKit assert inside CoreUI while rasterising an SF Symbol (the file
        // panel's search icons in PanelViewHeader) as soon as a modal alert runs its display
        // cycle - reproducible with "defaults write <id> AppleLanguages -array ru" alone, i.e.
        // it is an upstream problem, not something this feature should step into. The overlay
        // below switches every string the app itself draws, which is what this feature is for.
        //
        // Wait for this very process to disappear before starting the new copy: launching it
        // while we are still alive makes the preferences written a moment ago get lost.
        // The pid and the bundle path travel as positional arguments: the path is user-controlled -
        // it may contain quotes, '$' or backticks - and must never be spliced into the script text.
        NSString *const script = @"while /bin/kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; sleep 0.5; "
                                  "/usr/bin/open -n \"$2\"";
        NSTask *const task = [[NSTask alloc] init];
        task.launchPath = @"/bin/sh";
        task.arguments = @[@"-c", script, @"nc-language-pack-restart", @(getpid()).stringValue, bundle_path];
        NSError *launch_error = nil;
        if( ![task launchAndReturnError:&launch_error] ) {
            // Without the helper process terminating would leave the user with no app at all.
            NSLog(@"Failed to schedule the relaunch: %@", launch_error.localizedDescription);
            return;
        }
        [NSApp terminate:nil];
    }
}

void InstallLocalizationOverride()
{
    g_main_bundle = NSBundle.mainBundle;
    LoadActiveOverlay();

    const Method original = class_getInstanceMethod(NSBundle.class, @selector(localizedStringForKey:value:table:));
    const Method replacement =
        class_getInstanceMethod(NSBundle.class, @selector(nc_langpack_localizedStringForKey:value:table:));
    if( original && replacement && original != replacement )
        method_exchangeImplementations(original, replacement);
}

} // namespace nc::lang

@implementation NSBundle (NCLanguagePack)

+ (void)load
{
    nc::lang::InstallLocalizationOverride();
}

- (NSString *)nc_langpack_localizedStringForKey:(NSString *)_key value:(NSString *)_value table:(NSString *)_table
{
    NSString *const original = [self nc_langpack_localizedStringForKey:_key value:_value table:_table];
    if( g_overlay && _key.length ) {
        NSDictionary *const by_table = g_overlay[BundleKeyForBundle(self)];
        if( by_table ) {
            NSDictionary *const by_key = by_table[_table.length ? _table : kDefaultTable];
            if( by_key ) {
                NSString *const translation = by_key[_key];
                if( translation )
                    return translation;
            }
        }
    }
    return original;
}

@end
