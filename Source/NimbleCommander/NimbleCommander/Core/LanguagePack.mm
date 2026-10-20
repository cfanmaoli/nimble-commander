// Copyright (C) 2026 cfanmaoli. Subject to GNU General Public License version 3.
#include "LanguagePack.h"

#include <Cocoa/Cocoa.h>
#include <objc/runtime.h>

#include <algorithm>
#include <cctype>
#include <cstring>
#include <fstream>
#include <limits>
#include <unistd.h>
#include <set>
#include <string>

@interface NSBundle (NCLanguagePack)
- (NSString *)nc_langpack_localizedStringForKey:(NSString *)_key value:(NSString *)_value table:(NSString *)_table;
@end

namespace {

NSString *const kPackFormat = @"nimble-commander-language-pack";
const long kPackFormatVersion = 1;
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
    _s.erase(_s.begin(), std::find_if(_s.begin(), _s.end(), not_space));
    _s.erase(std::find_if(_s.rbegin(), _s.rend(), not_space).base(), _s.end());
    return _s;
}

bool IsValidPackIdentifier(const std::string &_s)
{
    if( _s.empty() || _s.size() > 64 || _s == "." || _s == ".." )
        return false;
    return std::all_of(
        _s.begin(), _s.end(), [](unsigned char _c) { return std::isalnum(_c) || _c == '-' || _c == '_' || _c == '.'; });
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

std::multiset<char> Placeholders(NSString *_string)
{
    // Only the *kind* of every conversion is compared: a translation is free to switch to
    // positional arguments ("%@ ... %@" -> "%1$@ ... %2$@") or to tweak flags and precision,
    // but a placeholder that appears or disappears would make the app print garbage.
    std::multiset<char> result;
    if( _string.length == 0 )
        return result;
    const std::string s = _string.UTF8String;
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
        if( j > position_start && j < s.size() && s[j] == '$' )
            ++j; // positional argument
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
        if( j >= s.size() )
            break;
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
        result.insert(kind);
        i = j;
    }
    return result;
}

bool PlaceholdersCompatible(NSString *_source, NSString *_key, NSString *_translation)
{
    const std::multiset<char> source = Placeholders(_source);
    const std::multiset<char> translation = Placeholders(_translation);
    if( source == translation )
        return true;
    // Strings with a stray '%' ("%% Insert the % character") can't be parsed unambiguously -
    // rather than rejecting a perfectly good translation, let those through unchecked.
    if( source.count('?') || translation.count('?') )
        return true;
    // A plural source ("Compressing %#@items@") may legitimately be spelled out with a plain
    // numeric placeholder - compare against the key, which holds the non-plural form.
    if( [_source rangeOfString:@"%#@"].location != NSNotFound && !LooksLikeObjectIdentifier(_key) )
        return Placeholders(_key) == Placeholders(_translation);
    return false;
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
    if( selection.rfind("builtin:", 0) == 0 ) {
        built_in = true;
        identifier = selection.substr(8);
    }
    else if( selection.rfind("pack:", 0) == 0 ) {
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
        for( NSString *language in(g_main_bundle ?: NSBundle.mainBundle).localizations )
            if( [language isKindOfClass:NSString.class] && ![language isEqualToString:@"Base"] )
                result.emplace_back(language.UTF8String);
        std::sort(result.begin(), result.end());
        result.erase(std::unique(result.begin(), result.end()), result.end());
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
    const std::string selection = ActiveLanguageSelection();
    if( selection.rfind("builtin:", 0) == 0 )
        return {};
    if( selection.rfind("pack:", 0) == 0 )
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
        NSArray *const entries = pack[@"entries"];
        if( ![entries isKindOfClass:NSArray.class] || entries.count == 0 ) {
            _error = "the file doesn't contain any entries";
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
            if( key.length == 0 || table.length == 0 ) {
                ++_stats.skipped_malformed;
                continue;
            }
            if( translation.length == 0 ) {
                ++_stats.skipped_empty;
                continue;
            }
            NSString *reference = [entry[@"source"] isKindOfClass:NSString.class] ? entry[@"source"] : nil;
            if( reference.length == 0 && !LooksLikeObjectIdentifier(key) )
                reference = key;
            if( reference.length && !PlaceholdersCompatible(reference, key, translation) ) {
                // a missing or duplicated %@ would make the app crash or print garbage - refuse it
                ++_stats.skipped_placeholders;
                continue;
            }
            NSString *const bundle_key = [entry[@"bundle"] isKindOfClass:NSString.class] ? entry[@"bundle"] : @"";
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
        NSError *write_error = nil;
        if( ![normalized_data writeToFile:FromPath(PackFileFor(identifier))
                                  options:NSDataWritingAtomic
                                    error:&write_error] ) {
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
        NSString *const script =
            [NSString stringWithFormat:@"while /bin/kill -0 %d 2>/dev/null; do sleep 0.2; done; sleep 0.5; "
                                       @"/usr/bin/open -n \"%@\"",
                                       static_cast<int>(getpid()),
                                       bundle_path];
        NSTask *const task = [[NSTask alloc] init];
        task.launchPath = @"/bin/sh";
        task.arguments = @[@"-c", script];
        [task launchAndReturnError:nil];
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
