// Copyright (C) 2026 cfanmaoli. Subject to GNU General Public License version 3.
#include "PreferencesWindowLanguageTab.h"
#include "../Core/LanguagePack.h"

#include <limits>
#include <string>
#include <vector>

using namespace std::literals;

static NSString *FromStd(const std::string &_string)
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
    NSButton *m_RestartButton;
    NSPopUpButton *m_PackPopup;
    NSTextField *m_PackValue;
    NSTextField *m_Status;
    NSButton *m_RemoveButton;
    std::vector<Entry> m_Entries;
    std::vector<nc::lang::PackInfo> m_Packs;
}

- (void)loadView
{
    NSView *const root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 580, 350)];

    NSTextField *const title =
        [NSTextField labelWithString:NSLocalizedStringFromTable(
                                         @"Language Packs", @"Preferences", "Language preferences tab title")];
    title.font = [NSFont boldSystemFontOfSize:13];
    title.frame = NSMakeRect(20, 314, 540, 18);
    title.autoresizingMask = NSViewMaxYMargin;
    [root addSubview:title];

    NSTextField *const description = [NSTextField
        wrappingLabelWithString:NSLocalizedStringFromTable(
                                    @"You can translate the interface of Nimble Commander into another language, or "
                                    @"use a translation made by someone else. Export the current language, replace the "
                                    @"text with your own translation, then import the file back and restart the app.",
                                    @"Preferences",
                                    "Language preferences tab description")];
    description.font = [NSFont systemFontOfSize:11];
    description.textColor = NSColor.secondaryLabelColor;
    description.frame = NSMakeRect(20, 234, 540, 72);
    description.autoresizingMask = NSViewMaxYMargin;
    [root addSubview:description];

    NSBox *const separator = [[NSBox alloc] initWithFrame:NSMakeRect(20, 220, 540, 1)];
    separator.boxType = NSBoxSeparator;
    separator.autoresizingMask = NSViewMaxYMargin;
    [root addSubview:separator];

    NSTextField *const language_label =
        [NSTextField labelWithString:NSLocalizedStringFromTable(
                                         @"Interface language:", @"Preferences", "Language preferences tab label")];
    language_label.frame = NSMakeRect(20, 186, 110, 17);
    [root addSubview:language_label];

    m_LanguagePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(132, 180, 300, 26)];
    m_LanguagePopup.target = self;
    m_LanguagePopup.action = @selector(onLanguageChanged:);
    [root addSubview:m_LanguagePopup];

    // One click to apply a language change - no "are you sure?" in between.
    m_RestartButton =
        [NSButton buttonWithTitle:NSLocalizedStringFromTable(
                                      @"Restart to Apply", @"Preferences", "Language preferences tab button")
                           target:self
                           action:@selector(onRestart:)];
    m_RestartButton.frame = NSMakeRect(440, 179, 120, 28);
    m_RestartButton.autoresizingMask = NSViewMinXMargin;
    [root addSubview:m_RestartButton];

    NSTextField *const pack_label =
        [NSTextField labelWithString:NSLocalizedStringFromTable(
                                         @"Language pack:", @"Preferences", "Language preferences tab label")];
    pack_label.frame = NSMakeRect(20, 148, 110, 17);
    [root addSubview:pack_label];

    m_PackPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(132, 142, 320, 26)];
    m_PackPopup.target = self;
    m_PackPopup.action = @selector(onPackSelectionChanged:);
    [root addSubview:m_PackPopup];

    m_PackValue = [NSTextField labelWithString:@""];
    m_PackValue.font = [NSFont systemFontOfSize:11];
    m_PackValue.textColor = NSColor.secondaryLabelColor;
    m_PackValue.frame = NSMakeRect(134, 120, 420, 16);
    m_PackValue.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [root addSubview:m_PackValue];

    m_RemoveButton = [NSButton
        buttonWithTitle:NSLocalizedStringFromTable(@"Remove", @"Preferences", "Language preferences tab button")
                 target:self
                 action:@selector(onRemove:)];
    m_RemoveButton.frame = NSMakeRect(480, 138, 80, 30);
    m_RemoveButton.autoresizingMask = NSViewMinXMargin;
    [root addSubview:m_RemoveButton];

    NSButton *const export_button =
        [NSButton buttonWithTitle:NSLocalizedStringFromTable(
                                      @"Export Current Language…", @"Preferences", "Language preferences tab button")
                           target:self
                           action:@selector(onExport:)];
    export_button.frame = NSMakeRect(18, 78, 190, 32);
    [root addSubview:export_button];

    NSButton *const import_button =
        [NSButton buttonWithTitle:NSLocalizedStringFromTable(
                                      @"Import Language File…", @"Preferences", "Language preferences tab button")
                           target:self
                           action:@selector(onImport:)];
    import_button.frame = NSMakeRect(216, 78, 190, 32);
    [root addSubview:import_button];

    NSTextField *const hint =
        [NSTextField wrappingLabelWithString:NSLocalizedStringFromTable(
                                                 @"A restart is required for a language change to take effect.",
                                                 @"Preferences",
                                                 "Language preferences tab hint")];
    hint.font = [NSFont systemFontOfSize:11];
    hint.textColor = NSColor.secondaryLabelColor;
    hint.frame = NSMakeRect(20, 50, 540, 17);
    [root addSubview:hint];

    m_Status = [NSTextField wrappingLabelWithString:@""];
    m_Status.font = [NSFont systemFontOfSize:11];
    m_Status.textColor = NSColor.secondaryLabelColor;
    m_Status.frame = NSMakeRect(20, 8, 540, 38);
    [root addSubview:m_Status];

    self.view = root;
    [self refresh];
}

- (NSString *)titleForLanguage:(const std::string &)_code
{
    return [NSString stringWithFormat:@"%@ (%@)", FromStd(nc::lang::DisplayNameForLanguage(_code)), FromStd(_code)];
}

- (void)refresh
{
    // menu indices include the separators, so every real item carries its index into m_Entries
    m_Entries.clear();
    [m_LanguagePopup removeAllItems];

    auto add_entry = [&](EntryKind _kind, const std::string &_value, NSString *_title) -> NSInteger {
        const NSInteger menu_index = static_cast<NSInteger>(m_LanguagePopup.numberOfItems);
        [m_LanguagePopup addItemWithTitle:_title];
        m_LanguagePopup.lastItem.tag = static_cast<NSInteger>(m_Entries.size());
        m_Entries.push_back({_kind, _value});
        return menu_index;
    };

    const std::string selection = nc::lang::ActiveLanguageSelection();
    const std::string active_pack = nc::lang::ActivePackIdentifier();
    std::string active_builtin;
    if( selection.rfind("builtin:", 0) == 0 )
        active_builtin = selection.substr(8);

    NSInteger selected_index =
        add_entry(EntryKind::FollowSystem,
                  {},
                  NSLocalizedStringFromTable(@"Follow System", @"Preferences", "Language preferences tab popup"));
    if( !selection.empty() )
        selected_index = -1;

    [m_LanguagePopup.menu addItem:NSMenuItem.separatorItem];
    for( const std::string &code : nc::lang::BuiltInLanguages() ) {
        const NSInteger index = add_entry(EntryKind::BuiltIn, code, [self titleForLanguage:code]);
        if( !active_builtin.empty() && code == active_builtin )
            selected_index = index;
    }

    const std::vector<nc::lang::PackInfo> packs = nc::lang::ListPacks();
    if( !packs.empty() ) {
        [m_LanguagePopup.menu addItem:NSMenuItem.separatorItem];
        for( const nc::lang::PackInfo &pack : packs ) {
            const NSInteger index =
                add_entry(EntryKind::Pack, pack.identifier, [self titleForLanguage:pack.identifier]);
            if( pack.identifier == active_pack )
                selected_index = index;
        }
    }
    [m_LanguagePopup selectItemAtIndex:selected_index < 0 ? 0 : selected_index];

    // The second popup picks *which* installed pack the Remove button applies to, so that a
    // pack can be deleted without activating it first.
    m_Packs = nc::lang::ListPacks();
    [m_PackPopup removeAllItems];
    NSInteger pack_selection = -1;
    for( std::size_t i = 0; i != m_Packs.size(); ++i ) {
        [m_PackPopup addItemWithTitle:[self titleForLanguage:m_Packs[i].identifier]];
        if( m_Packs[i].identifier == active_pack )
            pack_selection = static_cast<NSInteger>(i);
    }
    if( m_Packs.empty() ) {
        [m_PackPopup
            addItemWithTitle:NSLocalizedStringFromTable(@"None", @"Preferences", "Language preferences tab status")];
        [m_PackPopup selectItemAtIndex:0];
        m_PackPopup.enabled = NO;
        m_RemoveButton.enabled = NO;
        m_PackValue.stringValue = @"";
    }
    else {
        m_PackPopup.enabled = YES;
        m_RemoveButton.enabled = YES;
        [m_PackPopup selectItemAtIndex:pack_selection < 0 ? 0 : pack_selection];
        [self updatePackInfo];
    }
}

- (void)updatePackInfo
{
    const NSInteger index = m_PackPopup.indexOfSelectedItem;
    if( index < 0 || index >= static_cast<NSInteger>(m_Packs.size()) ) {
        m_PackValue.stringValue = @"";
        return;
    }
    const nc::lang::PackInfo &pack = m_Packs[static_cast<std::size_t>(index)];
    const bool active = pack.identifier == nc::lang::ActivePackIdentifier();
    NSString *info = nil;
    if( pack.translated == std::numeric_limits<std::size_t>::max() ) {
        info = [NSString stringWithFormat:NSLocalizedStringFromTable(@"%@ (%@) · language pack · %@ entries",
                                                                     @"Preferences",
                                                                     "Language preferences tab status"),
                                          FromStd(pack.display_name),
                                          FromStd(pack.language),
                                          @(pack.entries)];
    }
    else {
        info = [NSString
            stringWithFormat:NSLocalizedStringFromTable(@"%@ (%@) · language pack · %@ entries · %@ translated",
                                                        @"Preferences",
                                                        "Language preferences tab status"),
                             FromStd(pack.display_name),
                             FromStd(pack.language),
                             @(pack.entries),
                             @(pack.translated)];
    }
    if( active )
        info = [info stringByAppendingFormat:@" · %@",
                                             NSLocalizedStringFromTable(
                                                 @"in use", @"Preferences", "Language preferences tab status")];
    m_PackValue.stringValue = info;
}

- (void)setStatus:(NSString *)_status
{
    m_Status.stringValue = _status ?: @"";
}

- (void)offerRestart
{
    NSAlert *const alert = [[NSAlert alloc] init];
    alert.messageText =
        NSLocalizedStringFromTable(@"Restart Required", @"Preferences", "Language preferences tab restart prompt");
    alert.informativeText =
        NSLocalizedStringFromTable(@"The interface language will change the next time Nimble Commander starts.",
                                   @"Preferences",
                                   "Language preferences tab restart prompt");
    [alert addButtonWithTitle:NSLocalizedStringFromTable(
                                  @"Restart Now", @"Preferences", "Language preferences tab button")];
    [alert addButtonWithTitle:NSLocalizedStringFromTable(@"Later", @"Preferences", "Language preferences tab button")];
    if( [alert runModal] == NSAlertFirstButtonReturn )
        nc::lang::RelaunchApplication();
}

- (NSString *)identifier
{
    return NSStringFromClass(self.class);
}

- (NSImage *)toolbarItemImage
{
    // deliberately an asset, not an SF Symbol: rasterising a vector glyph while the window is
    // being laid out during termination trips an assertion inside CoreUI
    return [NSImage imageNamed:@"preferences.toolbar.language"];
}

- (NSString *)toolbarItemLabel
{
    return NSLocalizedStringFromTable(@"Language", @"Preferences", "Language preferences tab title");
}

- (void)onLanguageChanged:(id) [[maybe_unused]] _sender
{
    const NSInteger tag = m_LanguagePopup.selectedItem.tag;
    if( tag < 0 || tag >= static_cast<NSInteger>(m_Entries.size()) )
        return;
    const Entry &entry = m_Entries[static_cast<std::size_t>(tag)];
    switch( entry.kind ) {
        case EntryKind::FollowSystem:
            nc::lang::SetActiveLanguageSelection({});
            break;
        case EntryKind::BuiltIn:
            nc::lang::SetActiveLanguageSelection("builtin:" + entry.value);
            break;
        case EntryKind::Pack:
            nc::lang::SetActiveLanguageSelection("pack:" + entry.value);
            break;
    }
    // Rebuilding the popup while its own action is still being dispatched leaves AppKit looking
    // at a menu that is being torn down - do it on the next runloop turn. No modal here: the
    // "Restart to Apply" button next to the popup is the deliberate way to apply the change.
    dispatch_async(dispatch_get_main_queue(), ^{
      [self refresh];
      [self setStatus:NSLocalizedStringFromTable(@"A restart is required for a language change to take effect.",
                                                 @"Preferences",
                                                 "Language preferences tab hint")];
    });
}

- (void)onRestart:(id) [[maybe_unused]] _sender
{
    // the button is the deliberate way to apply a change, so ask once before dropping whatever
    // the user is doing in the other windows
    NSAlert *const alert = [[NSAlert alloc] init];
    alert.messageText = NSLocalizedStringFromTable(@"Restart Nimble Commander to apply the new language?",
                                                   @"Preferences",
                                                   "Language preferences tab restart confirmation");
    alert.informativeText =
        NSLocalizedStringFromTable(@"The interface language will change the next time Nimble Commander starts.",
                                   @"Preferences",
                                   "Language preferences tab restart prompt");
    [alert addButtonWithTitle:NSLocalizedStringFromTable(
                                  @"Restart Now", @"Preferences", "Language preferences tab button")];
    [alert addButtonWithTitle:NSLocalizedStringFromTable(@"Cancel", @"Preferences", "Language preferences tab button")];
    if( [alert runModal] == NSAlertFirstButtonReturn )
        nc::lang::RelaunchApplication();
}

- (void)onExport:(id) [[maybe_unused]] _sender
{
    const std::string language = nc::lang::CurrentLanguage();
    NSSavePanel *const panel = [NSSavePanel savePanel];
    panel.title = NSLocalizedStringFromTable(
        @"Export Current Language", @"Preferences", "Language preferences tab save panel title");
    panel.nameFieldStringValue = [NSString stringWithFormat:@"%s.json", language.c_str()];
    if( [panel runModal] != NSModalResponseOK )
        return;

    std::string error;
    if( nc::lang::ExportCurrentLanguage(panel.URL.fileSystemRepresentation, error) ) {
        NSAlert *const alert = [[NSAlert alloc] init];
        alert.messageText =
            NSLocalizedStringFromTable(@"Export Complete", @"Preferences", "Language preferences tab export result");
        alert.informativeText =
            [NSString stringWithFormat:NSLocalizedStringFromTable(@"Exported %@ entries to:\n%@",
                                                                  @"Preferences",
                                                                  "Language preferences tab export result"),
                                       @(nc::lang::CurrentLanguageEntryCount()),
                                       panel.URL.path];
        [alert addButtonWithTitle:NSLocalizedStringFromTable(@"OK", @"Preferences", "Language preferences tab button")];
        [alert runModal];
        [self setStatus:panel.URL.path];
    }
    else {
        [self reportError:FromStd(error)];
    }
}

- (void)onImport:(id) [[maybe_unused]] _sender
{
    NSOpenPanel *const panel = [NSOpenPanel openPanel];
    panel.title = NSLocalizedStringFromTable(
        @"Import Language File", @"Preferences", "Language preferences tab open panel title");
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    if( [panel runModal] != NSModalResponseOK )
        return;

    nc::lang::ImportStats stats;
    std::string error;
    if( !nc::lang::ImportPack(panel.URL.fileSystemRepresentation, stats, error) ) {
        [self reportError:FromStd(error)];
        return;
    }

    NSMutableString *const message = [NSMutableString string];
    [message appendFormat:NSLocalizedStringFromTable(
                              @"Imported %@ entries for “%@”.\n\nRestart Nimble Commander to see the new language.",
                              @"Preferences",
                              "Language preferences tab import result"),
                          @(stats.imported),
                          FromStd(stats.display_name)];
    if( stats.skipped_empty )
        [message appendFormat:@"\n\n%@",
                              [NSString stringWithFormat:NSLocalizedStringFromTable(
                                                             @"Skipped %@ entries without a translation.",
                                                             @"Preferences",
                                                             "Language preferences tab import result"),
                                                         @(stats.skipped_empty)]];
    if( stats.skipped_placeholders )
        [message appendFormat:@"\n\n%@",
                              [NSString stringWithFormat:NSLocalizedStringFromTable(
                                                             @"Skipped %@ entries whose format specifiers (%%, %%@, "
                                                             @"%%d …) don’t match the original text.",
                                                             @"Preferences",
                                                             "Language preferences tab import result"),
                                                         @(stats.skipped_placeholders)]];
    if( stats.skipped_malformed )
        [message appendFormat:@"\n\n%@",
                              [NSString
                                  stringWithFormat:NSLocalizedStringFromTable(@"Skipped %@ malformed entries.",
                                                                              @"Preferences",
                                                                              "Language preferences tab import result"),
                                                   @(stats.skipped_malformed)]];
    if( stats.measured_untranslated && stats.identical_to_current )
        [message appendFormat:@"\n\n%@",
                              [NSString stringWithFormat:NSLocalizedStringFromTable(
                                                             @"%@ of them are identical to the text of the current "
                                                             @"language and probably aren’t translated yet.",
                                                             @"Preferences",
                                                             "Language preferences tab import result"),
                                                         @(stats.identical_to_current)]];

    NSAlert *const alert = [[NSAlert alloc] init];
    alert.messageText =
        NSLocalizedStringFromTable(@"Import Complete", @"Preferences", "Language preferences tab import result");
    alert.informativeText = message;
    [alert addButtonWithTitle:NSLocalizedStringFromTable(
                                  @"Restart Now", @"Preferences", "Language preferences tab button")];
    [alert addButtonWithTitle:NSLocalizedStringFromTable(@"Later", @"Preferences", "Language preferences tab button")];
    const BOOL restart = [alert runModal] == NSAlertFirstButtonReturn;

    [self refresh];
    [self setStatus:message];

    if( restart )
        nc::lang::RelaunchApplication();
}

- (void)onPackSelectionChanged:(id) [[maybe_unused]] _sender
{
    [self updatePackInfo];
}

- (void)onRemove:(id) [[maybe_unused]] _sender
{
    const NSInteger index = m_PackPopup.indexOfSelectedItem;
    if( index < 0 || index >= static_cast<NSInteger>(m_Packs.size()) )
        return;
    const nc::lang::PackInfo pack = m_Packs[static_cast<std::size_t>(index)];
    const std::string identifier = pack.identifier;
    if( identifier.empty() )
        return;
    const bool was_active = identifier == nc::lang::ActivePackIdentifier();

    NSAlert *const alert = [[NSAlert alloc] init];
    alert.messageText = [NSString
        stringWithFormat:NSLocalizedStringFromTable(@"Are you sure you want to remove the language pack “%@”?",
                                                    @"Preferences",
                                                    "Language preferences tab confirmation"),
                         FromStd(pack.display_name)];
    alert.informativeText =
        NSLocalizedStringFromTable(@"This can’t be undone.", @"Preferences", "Language preferences tab confirmation");
    [alert addButtonWithTitle:NSLocalizedStringFromTable(@"Remove", @"Preferences", "Language preferences tab button")];
    [alert addButtonWithTitle:NSLocalizedStringFromTable(@"Cancel", @"Preferences", "Language preferences tab button")];
    if( [alert runModal] != NSAlertFirstButtonReturn )
        return;

    std::string error;
    if( !nc::lang::RemovePack(identifier, error) ) {
        [self reportError:FromStd(error)];
        return;
    }
    [self refresh];
    // only the pack that was actually in use needs a restart to disappear from the UI
    [self setStatus:was_active
                        ? NSLocalizedStringFromTable(@"A restart is required for a language change to take effect.",
                                                     @"Preferences",
                                                     "Language preferences tab hint")
                        : [NSString stringWithFormat:NSLocalizedStringFromTable(@"Removed the language pack “%@”.",
                                                                                @"Preferences",
                                                                                "Language preferences tab status"),
                                                     FromStd(pack.display_name)]];
}

- (void)reportError:(NSString *)_detail
{
    NSAlert *const alert = [[NSAlert alloc] init];
    alert.messageText =
        NSLocalizedStringFromTable(@"Unable to use this file", @"Preferences", "Language preferences tab error");
    alert.informativeText = _detail ?: @"";
    [alert addButtonWithTitle:NSLocalizedStringFromTable(@"OK", @"Preferences", "Language preferences tab button")];
    [alert runModal];
}

@end
