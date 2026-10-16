// Copyright (C) 2026 cfanmaoli. Subject to GNU General Public License version 3.
#include "PreferencesWindowLanguageTab.h"
#include "../Core/LanguagePack.h"

#include <limits>
#include <string>
#include <vector>

using namespace std::literals;

static NSString *FromStd( const std::string &_string )
{
    return [NSString stringWithUTF8String:_string.c_str()];
}

namespace {

enum class EntryKind : int {
    FollowSystem,
    BuiltIn,
    Pack,
};

struct Entry {
    EntryKind kind;
    std::string value;
};

} // namespace

@implementation PreferencesWindowLanguageTab {
    NSPopUpButton *m_LanguagePopup;
    NSTextField *m_PackValue;
    NSTextField *m_Status;
    NSButton *m_RemoveButton;
    std::vector<Entry> m_Entries;
}

- (void)loadView
{
    NSView *const root = [[NSView alloc] initWithFrame:NSMakeRect( 0, 0, 580, 330 )];

    NSTextField *const title = [NSTextField labelWithString:NSLocalizedStringFromTable(@"Language Packs", @"Preferences", "Language preferences tab title")];
    title.font = [NSFont boldSystemFontOfSize:13];
    title.frame = NSMakeRect( 20, 294, 540, 18 );
    title.autoresizingMask = NSViewMaxYMargin;
    [root addSubview:title];

    NSTextField *const description = [NSTextField wrappingLabelWithString:NSLocalizedStringFromTable(@"You can translate the interface of Nimble Commander into another language, or use a translation made by someone else. Export the current language, replace the text with your own translation, then import the file back and restart the app.", @"Preferences", "Language preferences tab description")];
    description.font = [NSFont systemFontOfSize:11];
    description.textColor = NSColor.secondaryLabelColor;
    description.frame = NSMakeRect( 20, 214, 540, 72 );
    description.autoresizingMask = NSViewMaxYMargin;
    [root addSubview:description];

    NSBox *const separator = [[NSBox alloc] initWithFrame:NSMakeRect( 20, 200, 540, 1 )];
    separator.boxType = NSBoxSeparator;
    separator.autoresizingMask = NSViewMaxYMargin;
    [root addSubview:separator];

    NSTextField *const language_label = [NSTextField labelWithString:NSLocalizedStringFromTable(@"Interface language:", @"Preferences", "Language preferences tab label")];
    language_label.frame = NSMakeRect( 20, 166, 110, 17 );
    [root addSubview:language_label];

    m_LanguagePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect( 132, 160, 320, 26 )];
    m_LanguagePopup.target = self;
    m_LanguagePopup.action = @selector( onLanguageChanged: );
    [root addSubview:m_LanguagePopup];

    NSTextField *const pack_label = [NSTextField labelWithString:NSLocalizedStringFromTable(@"Language pack:", @"Preferences", "Language preferences tab label")];
    pack_label.frame = NSMakeRect( 20, 124, 110, 17 );
    [root addSubview:pack_label];

    m_PackValue = [NSTextField labelWithString:@""];
    m_PackValue.frame = NSMakeRect( 132, 124, 340, 17 );
    m_PackValue.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [root addSubview:m_PackValue];

    m_RemoveButton = [NSButton buttonWithTitle:NSLocalizedStringFromTable(@"Remove", @"Preferences", "Language preferences tab button")
                                        target:self
                                        action:@selector( onRemove: )];
    m_RemoveButton.frame = NSMakeRect( 480, 118, 80, 30 );
    m_RemoveButton.autoresizingMask = NSViewMinXMargin;
    [root addSubview:m_RemoveButton];

    NSButton *const export_button = [NSButton buttonWithTitle:NSLocalizedStringFromTable(@"Export Current Language…", @"Preferences", "Language preferences tab button")
                                                       target:self
                                                       action:@selector( onExport: )];
    export_button.frame = NSMakeRect( 18, 74, 190, 32 );
    [root addSubview:export_button];

    NSButton *const import_button = [NSButton buttonWithTitle:NSLocalizedStringFromTable(@"Import Language File…", @"Preferences", "Language preferences tab button")
                                                       target:self
                                                       action:@selector( onImport: )];
    import_button.frame = NSMakeRect( 216, 74, 190, 32 );
    [root addSubview:import_button];

    NSTextField *const hint = [NSTextField wrappingLabelWithString:NSLocalizedStringFromTable(@"A restart is required for a language change to take effect.", @"Preferences", "Language preferences tab hint")];
    hint.font = [NSFont systemFontOfSize:11];
    hint.textColor = NSColor.secondaryLabelColor;
    hint.frame = NSMakeRect( 20, 46, 540, 17 );
    [root addSubview:hint];

    m_Status = [NSTextField wrappingLabelWithString:@""];
    m_Status.font = [NSFont systemFontOfSize:11];
    m_Status.textColor = NSColor.secondaryLabelColor;
    m_Status.frame = NSMakeRect( 20, 6, 540, 36 );
    [root addSubview:m_Status];

    self.view = root;
    [self refresh];
}

- (NSString *)titleForLanguage:(const std::string &)_code
{
    return [NSString stringWithFormat:@"%@ (%@)",
                                      FromStd( nc::lang::DisplayNameForLanguage( _code ) ),
                                      FromStd( _code )];
}

- (void)refresh
{
    // menu indices include the separators, so every real item carries its index into m_Entries
    m_Entries.clear();
    [m_LanguagePopup removeAllItems];

    auto add_entry = [&]( EntryKind _kind, const std::string &_value, NSString *_title ) -> NSInteger {
        const NSInteger menu_index = static_cast<NSInteger>( m_LanguagePopup.numberOfItems );
        [m_LanguagePopup addItemWithTitle:_title];
        m_LanguagePopup.lastItem.tag = static_cast<NSInteger>( m_Entries.size() );
        m_Entries.push_back( { _kind, _value } );
        return menu_index;
    };

    const std::string selection = nc::lang::ActiveLanguageSelection();
    const std::string active_pack = nc::lang::ActivePackIdentifier();
    std::string active_builtin;
    if( selection.rfind( "builtin:", 0 ) == 0 )
        active_builtin = selection.substr( 8 );

    NSInteger selected_index = add_entry( EntryKind::FollowSystem,
                                          {},
                                          NSLocalizedStringFromTable(@"Follow System", @"Preferences", "Language preferences tab popup") );
    if( !selection.empty() )
        selected_index = -1;

    [m_LanguagePopup.menu addItem:NSMenuItem.separatorItem];
    for( const std::string &code : nc::lang::BuiltInLanguages() ) {
        const NSInteger index = add_entry( EntryKind::BuiltIn, code, [self titleForLanguage:code] );
        if( !active_builtin.empty() && code == active_builtin )
            selected_index = index;
    }

    const std::vector<nc::lang::PackInfo> packs = nc::lang::ListPacks();
    if( !packs.empty() ) {
        [m_LanguagePopup.menu addItem:NSMenuItem.separatorItem];
        for( const nc::lang::PackInfo &pack : packs ) {
            const NSInteger index = add_entry( EntryKind::Pack, pack.identifier, [self titleForLanguage:pack.identifier] );
            if( pack.identifier == active_pack )
                selected_index = index;
        }
    }
    [m_LanguagePopup selectItemAtIndex:selected_index < 0 ? 0 : selected_index];

    if( active_pack.empty() ) {
        m_PackValue.stringValue = NSLocalizedStringFromTable(@"None", @"Preferences", "Language preferences tab status");
        m_RemoveButton.enabled = NO;
    }
    else if( nc::lang::ActivePackTranslatedCount() == std::numeric_limits<std::size_t>::max() ) {
        m_PackValue.stringValue = [NSString stringWithFormat:NSLocalizedStringFromTable(@"%@ (%@) · language pack · %@ entries", @"Preferences", "Language preferences tab status"),
                                                             FromStd( nc::lang::ActivePackDisplayName() ),
                                                             FromStd( nc::lang::ActivePackLanguage() ),
                                                             @(nc::lang::ActivePackEntryCount())];
        m_RemoveButton.enabled = YES;
    }
    else {
        m_PackValue.stringValue = [NSString stringWithFormat:NSLocalizedStringFromTable(@"%@ (%@) · language pack · %@ entries · %@ translated", @"Preferences", "Language preferences tab status"),
                                                             FromStd( nc::lang::ActivePackDisplayName() ),
                                                             FromStd( nc::lang::ActivePackLanguage() ),
                                                             @(nc::lang::ActivePackEntryCount()),
                                                             @(nc::lang::ActivePackTranslatedCount())];
        m_RemoveButton.enabled = YES;
    }
}

- (void)setStatus:(NSString *)_status
{
    m_Status.stringValue = _status ?: @"";
}

- (void)offerRestart
{
    NSAlert *const alert = [[NSAlert alloc] init];
    alert.messageText = NSLocalizedStringFromTable(@"Restart Required", @"Preferences", "Language preferences tab restart prompt");
    alert.informativeText = NSLocalizedStringFromTable(@"The interface language will change the next time Nimble Commander starts.", @"Preferences", "Language preferences tab restart prompt");
    [alert addButtonWithTitle:NSLocalizedStringFromTable(@"Restart Now", @"Preferences", "Language preferences tab button")];
    [alert addButtonWithTitle:NSLocalizedStringFromTable(@"Later", @"Preferences", "Language preferences tab button")];
    if( [alert runModal] == NSAlertFirstButtonReturn )
        nc::lang::RelaunchApplication();
}

- (NSString *)identifier
{
    return NSStringFromClass( self.class );
}

- (NSImage *)toolbarItemImage
{
    NSImage *const symbol = [NSImage imageWithSystemSymbolName:@"character.bubble" accessibilityDescription:nil];
    return symbol ?: [NSImage imageNamed:NSImageNameAdvanced];
}

- (NSString *)toolbarItemLabel
{
    return NSLocalizedStringFromTable(@"Language", @"Preferences", "Language preferences tab title");
}

- (void)onLanguageChanged:(id) [[maybe_unused]] _sender
{
    const NSInteger tag = m_LanguagePopup.selectedItem.tag;
    if( tag < 0 || tag >= static_cast<NSInteger>( m_Entries.size() ) )
        return;
    const Entry &entry = m_Entries[static_cast<std::size_t>( tag )];
    switch( entry.kind ) {
        case EntryKind::FollowSystem:
            nc::lang::SetActiveLanguageSelection( {} );
            // best effort: let the system-provided names, dates and numbers follow as well
            nc::lang::SetPreferredBuiltInLanguage( {} );
            break;
        case EntryKind::BuiltIn:
            nc::lang::SetActiveLanguageSelection( "builtin:" + entry.value );
            // the overlay only swaps the app's own strings - asking the system for this language
            // as well makes dates, numbers and the sidebar names follow
            nc::lang::SetPreferredBuiltInLanguage( entry.value );
            break;
        case EntryKind::Pack:
            nc::lang::SetActiveLanguageSelection( "pack:" + entry.value );
            nc::lang::SetPreferredBuiltInLanguage( {} );
            break;
    }
    [self refresh];
    [self offerRestart];
}

- (void)onExport:(id) [[maybe_unused]] _sender
{
    const std::string language = nc::lang::CurrentLanguage();
    NSSavePanel *const panel = [NSSavePanel savePanel];
    panel.title = NSLocalizedStringFromTable(@"Export Current Language", @"Preferences", "Language preferences tab save panel title");
    panel.nameFieldStringValue = [NSString stringWithFormat:@"%s.json", language.c_str()];
    if( [panel runModal] != NSModalResponseOK )
        return;

    std::string error;
    if( nc::lang::ExportCurrentLanguage( panel.URL.fileSystemRepresentation, error ) ) {
        NSAlert *const alert = [[NSAlert alloc] init];
        alert.messageText = NSLocalizedStringFromTable(@"Export Complete", @"Preferences", "Language preferences tab export result");
        alert.informativeText = [NSString stringWithFormat:NSLocalizedStringFromTable(@"Exported %@ entries to:\n%@", @"Preferences", "Language preferences tab export result"),
                                                           @(nc::lang::CurrentLanguageEntryCount()),
                                                           panel.URL.path];
        [alert addButtonWithTitle:NSLocalizedStringFromTable(@"OK", @"Preferences", "Language preferences tab button")];
        [alert runModal];
        [self setStatus:panel.URL.path];
    }
    else {
        [self reportError:FromStd( error )];
    }
}

- (void)onImport:(id) [[maybe_unused]] _sender
{
    NSOpenPanel *const panel = [NSOpenPanel openPanel];
    panel.title = NSLocalizedStringFromTable(@"Import Language File", @"Preferences", "Language preferences tab open panel title");
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    if( [panel runModal] != NSModalResponseOK )
        return;

    nc::lang::ImportStats stats;
    std::string error;
    if( !nc::lang::ImportPack( panel.URL.fileSystemRepresentation, stats, error ) ) {
        [self reportError:FromStd( error )];
        return;
    }

    NSMutableString *const message = [NSMutableString string];
    [message appendFormat:NSLocalizedStringFromTable(@"Imported %@ entries for “%@”.\n\nRestart Nimble Commander to see the new language.", @"Preferences", "Language preferences tab import result"),
                             @(stats.imported),
                             FromStd( stats.display_name )];
    if( stats.skipped_empty )
        [message appendFormat:@"\n\n%@", [NSString stringWithFormat:
            NSLocalizedStringFromTable(@"Skipped %@ entries without a translation.", @"Preferences", "Language preferences tab import result"),
            @(stats.skipped_empty)]];
    if( stats.skipped_placeholders )
        [message appendFormat:@"\n\n%@", [NSString stringWithFormat:
            NSLocalizedStringFromTable(@"Skipped %@ entries whose format specifiers (%%, %%@, %%d …) don’t match the original text.", @"Preferences", "Language preferences tab import result"),
            @(stats.skipped_placeholders)]];
    if( stats.skipped_malformed )
        [message appendFormat:@"\n\n%@", [NSString stringWithFormat:
            NSLocalizedStringFromTable(@"Skipped %@ malformed entries.", @"Preferences", "Language preferences tab import result"),
            @(stats.skipped_malformed)]];
    if( stats.measured_untranslated && stats.identical_to_current )
        [message appendFormat:@"\n\n%@", [NSString stringWithFormat:
            NSLocalizedStringFromTable(@"%@ of them are identical to the text of the current language and probably aren’t translated yet.", @"Preferences", "Language preferences tab import result"),
            @(stats.identical_to_current)]];

    NSAlert *const alert = [[NSAlert alloc] init];
    alert.messageText = NSLocalizedStringFromTable(@"Import Complete", @"Preferences", "Language preferences tab import result");
    alert.informativeText = message;
    [alert addButtonWithTitle:NSLocalizedStringFromTable(@"Restart Now", @"Preferences", "Language preferences tab button")];
    [alert addButtonWithTitle:NSLocalizedStringFromTable(@"Later", @"Preferences", "Language preferences tab button")];
    const BOOL restart = [alert runModal] == NSAlertFirstButtonReturn;

    [self refresh];
    [self setStatus:message];

    if( restart )
        nc::lang::RelaunchApplication();
}

- (void)onRemove:(id) [[maybe_unused]] _sender
{
    const std::string identifier = nc::lang::ActivePackIdentifier();
    if( identifier.empty() )
        return;

    NSAlert *const alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithFormat:NSLocalizedStringFromTable(@"Are you sure you want to remove the language pack “%@”?", @"Preferences", "Language preferences tab confirmation"),
                                                   FromStd( nc::lang::ActivePackDisplayName() )];
    alert.informativeText = NSLocalizedStringFromTable(@"This can’t be undone.", @"Preferences", "Language preferences tab confirmation");
    [alert addButtonWithTitle:NSLocalizedStringFromTable(@"Remove", @"Preferences", "Language preferences tab button")];
    [alert addButtonWithTitle:NSLocalizedStringFromTable(@"Cancel", @"Preferences", "Language preferences tab button")];
    if( [alert runModal] != NSAlertFirstButtonReturn )
        return;

    std::string error;
    if( !nc::lang::RemovePack( identifier, error ) ) {
        [self reportError:FromStd( error )];
        return;
    }
    [self refresh];
    [self setStatus:NSLocalizedStringFromTable(@"A restart is required for a language change to take effect.", @"Preferences", "Language preferences tab hint")];
}

- (void)reportError:(NSString *)_detail
{
    NSAlert *const alert = [[NSAlert alloc] init];
    alert.messageText = NSLocalizedStringFromTable(@"Unable to use this file", @"Preferences", "Language preferences tab error");
    alert.informativeText = _detail ?: @"";
    [alert addButtonWithTitle:NSLocalizedStringFromTable(@"OK", @"Preferences", "Language preferences tab button")];
    [alert runModal];
}

@end
