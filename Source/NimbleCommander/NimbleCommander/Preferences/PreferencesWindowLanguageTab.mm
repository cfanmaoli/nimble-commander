// Copyright (C) 2026 cfanmaoli. Subject to GNU General Public License version 3.
#include "PreferencesWindowLanguageTab.h"
#include "../Core/LanguagePack.h"

#include <string>

using namespace std::literals;

static NSString *FromStd( const std::string &_string )
{
    return [NSString stringWithUTF8String:_string.c_str()];
}

@implementation PreferencesWindowLanguageTab {
    NSTextField *m_InterfaceLanguageValue;
    NSTextField *m_Status;
    NSButton *m_RemoveButton;
}

- (void)loadView
{
    NSView *const root = [[NSView alloc] initWithFrame:NSMakeRect( 0, 0, 580, 302 )];

    NSTextField *const title = [NSTextField labelWithString:NSLocalizedStringFromTable(@"Language Packs", @"Preferences", "Language preferences tab title")];
    title.font = [NSFont boldSystemFontOfSize:13];
    title.frame = NSMakeRect( 20, 266, 540, 18 );
    title.autoresizingMask = NSViewMaxYMargin;
    [root addSubview:title];

    NSTextField *const description = [NSTextField wrappingLabelWithString:
        NSLocalizedStringFromTable(@"You can translate the interface of Nimble Commander into another language, or use a translation made by someone else. Export the current language, replace the text with your own translation, then import the file back and restart the app.", @"Preferences", "Language preferences tab description")];
    description.font = [NSFont systemFontOfSize:11];
    description.textColor = NSColor.secondaryLabelColor;
    description.frame = NSMakeRect( 20, 186, 540, 70 );
    description.autoresizingMask = NSViewMaxYMargin;
    [root addSubview:description];

    NSBox *const separator = [[NSBox alloc] initWithFrame:NSMakeRect( 20, 172, 540, 1 )];
    separator.boxType = NSBoxSeparator;
    separator.autoresizingMask = NSViewMaxYMargin;
    [root addSubview:separator];

    NSTextField *const interface_label = [NSTextField labelWithString:NSLocalizedStringFromTable(@"Interface language:", @"Preferences", "Language preferences tab label")];
    interface_label.frame = NSMakeRect( 20, 138, 110, 17 );
    [root addSubview:interface_label];

    m_InterfaceLanguageValue = [NSTextField labelWithString:@""];
    m_InterfaceLanguageValue.frame = NSMakeRect( 134, 138, 340, 17 );
    m_InterfaceLanguageValue.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [root addSubview:m_InterfaceLanguageValue];

    m_RemoveButton = [NSButton buttonWithTitle:NSLocalizedStringFromTable(@"Remove", @"Preferences", "Language preferences tab button")
                                        target:self
                                        action:@selector(onRemove:)];
    m_RemoveButton.frame = NSMakeRect( 480, 131, 80, 30 );
    m_RemoveButton.autoresizingMask = NSViewMinXMargin;
    [root addSubview:m_RemoveButton];

    NSButton *const export_button = [NSButton buttonWithTitle:NSLocalizedStringFromTable(@"Export Current Language…", @"Preferences", "Language preferences tab button")
                                                       target:self
                                                       action:@selector(onExport:)];
    export_button.frame = NSMakeRect( 18, 88, 190, 32 );
    [root addSubview:export_button];

    NSButton *const import_button = [NSButton buttonWithTitle:NSLocalizedStringFromTable(@"Import Language File…", @"Preferences", "Language preferences tab button")
                                                       target:self
                                                       action:@selector(onImport:)];
    import_button.frame = NSMakeRect( 216, 88, 190, 32 );
    [root addSubview:import_button];

    NSTextField *const hint = [NSTextField wrappingLabelWithString:
        NSLocalizedStringFromTable(@"A restart is required for a language change to take effect.", @"Preferences", "Language preferences tab hint")];
    hint.font = [NSFont systemFontOfSize:11];
    hint.textColor = NSColor.secondaryLabelColor;
    hint.frame = NSMakeRect( 20, 60, 540, 17 );
    [root addSubview:hint];

    m_Status = [NSTextField wrappingLabelWithString:@""];
    m_Status.font = [NSFont systemFontOfSize:11];
    m_Status.textColor = NSColor.secondaryLabelColor;
    m_Status.frame = NSMakeRect( 20, 12, 540, 44 );
    [root addSubview:m_Status];

    self.view = root;
    [self refresh];
}

- (void)refresh
{
    const std::string identifier = nc::lang::ActivePackIdentifier();
    NSString *value = nil;
    if( identifier.empty() ) {
        const std::string language = nc::lang::CurrentLanguage();
        value = [NSString stringWithFormat:NSLocalizedStringFromTable(@"%@ (%@) · built-in", @"Preferences", "Language preferences tab status"),
                                           FromStd( nc::lang::DisplayNameForLanguage( language ) ),
                                           FromStd( language )];
    }
    else {
        value = [NSString stringWithFormat:NSLocalizedStringFromTable(@"%@ (%@) · language pack · %@ entries", @"Preferences", "Language preferences tab status"),
                                           FromStd( nc::lang::ActivePackDisplayName() ),
                                           FromStd( nc::lang::ActivePackLanguage() ),
                                           @(nc::lang::ActivePackEntryCount())];
    }
    m_InterfaceLanguageValue.stringValue = value;
    m_RemoveButton.enabled = !identifier.empty();
}

- (void)setStatus:(NSString *)_status
{
    m_Status.stringValue = _status ?: @"";
}

- (NSString *)identifier
{
    return NSStringFromClass( self.class );
}

- (NSImage *)toolbarItemImage
{
    NSImage *const symbol = [NSImage imageWithSystemSymbolName:@"character.bubble"
                                      accessibilityDescription:nil];
    return symbol ?: [NSImage imageNamed:NSImageNameAdvanced];
}

- (NSString *)toolbarItemLabel
{
    return NSLocalizedStringFromTable(@"Language", @"Preferences", "Language preferences tab title");
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
        alert.informativeText = [NSString stringWithFormat:
            NSLocalizedStringFromTable(@"Exported %@ entries to:\n%@", @"Preferences", "Language preferences tab export result"),
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
    alert.messageText = [NSString stringWithFormat:
        NSLocalizedStringFromTable(@"Are you sure you want to remove the language pack “%@”?", @"Preferences", "Language preferences tab confirmation"),
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
