// Copyright (C) 2026 Michael Kazakov. Subject to GNU General Public License version 3.
#include "PreferencesWindowCompressionTab.h"
#include "../Bootstrap/Config.h"
#include <Operations/Compression.h>
#include <Utility/ObjCpp.h>
#include <VFS/RarHelper.h>

#include <algorithm>

namespace {

const auto g_ConfigFormat = "compression.format";
const auto g_ConfigMethod = "compression.method";
const auto g_ConfigLevel = "compression.level";
const auto g_ConfigRarSupport = "compression.rarSupport";

NSArray<NSDictionary<NSString *, NSString *> *> *FormatItems()
{
    return @[
        @{@"value": @"zip", @"title": @"Zip"},
        @{@"value": @"7z", @"title": @"7z"},
        @{@"value": @"tar", @"title": @"Tar"},
    ];
}

NSArray<NSDictionary<NSString *, NSString *> *> *MethodItemsForFormat(NSString *_format)
{
    if( [_format isEqualToString:@"tar"] )
        return @[
            @{@"value": @"none", @"title": @"None"},
            @{@"value": @"gzip", @"title": @"Gzip"},
            @{@"value": @"bzip2", @"title": @"Bzip2"},
            @{@"value": @"xz", @"title": @"Xz"},
            @{@"value": @"zstd", @"title": @"Zstd"},
        ];

    return @[
        @{@"value": @"store", @"title": @"Store"},
        @{@"value": @"deflate", @"title": @"Deflate"},
        @{@"value": @"bzip2", @"title": @"Bzip2"},
        @{@"value": @"lzma", @"title": @"LZMA"},
        @{@"value": @"zstd", @"title": @"Zstd"},
    ];
}

NSString *DefaultMethodForFormat(NSString *_format)
{
    return [_format isEqualToString:@"tar"] ? @"none" : @"deflate";
}

void AddPopUpItem(NSPopUpButton *_popup, NSString *_title, id _represented_object)
{
    [_popup addItemWithTitle:_title];
    _popup.lastItem.representedObject = _represented_object;
}

NSString *SelectedValue(NSPopUpButton *_popup)
{
    return nc::objc_cast<NSString>(_popup.selectedItem.representedObject);
}

void SelectValue(NSPopUpButton *_popup, id _value)
{
    for( NSMenuItem *item in _popup.itemArray )
        if( [item.representedObject isEqual:_value] ) {
            [_popup selectItem:item];
            return;
        }
}

} // namespace

@interface PreferencesWindowCompressionTab ()
@property(nonatomic) NSPopUpButton *formatPopUp;
@property(nonatomic) NSPopUpButton *methodPopUp;
@property(nonatomic) NSPopUpButton *levelPopUp;
@property(nonatomic) NSButton *rarSupportCheckbox;
@property(nonatomic) NSTextField *helperStatusLabel;

- (void)buildViews;
- (void)loadSettings;
- (void)rebuildMethodPopUpForFormat:(NSString *)_format preferredMethod:(NSString *)_preferred_method;
- (void)updateLevelEnabled;
- (void)formatChanged:(id)_sender;
- (void)methodChanged:(id)_sender;
- (void)levelChanged:(id)_sender;
- (void)rarSupportChanged:(id)_sender;
- (void)updateHelperStatus;
@end

@implementation PreferencesWindowCompressionTab
@synthesize formatPopUp;
@synthesize methodPopUp;
@synthesize levelPopUp;
@synthesize rarSupportCheckbox;
@synthesize helperStatusLabel;

- (instancetype)init
{
    return [super init];
}

- (void)loadView
{
    self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 440, 200)];
    [self buildViews];
    [self loadSettings];
}

- (void)buildViews
{
    NSTextField *title =
        [NSTextField labelWithString:NSLocalizedStringFromTable(
                                         @"Defaults", @"Preferences", "Compression preferences: settings group title")];
    title.font = [NSFont boldSystemFontOfSize:[NSFont systemFontSize]];

    self.formatPopUp = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.methodPopUp = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.levelPopUp = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    for( NSPopUpButton *popup in @[self.formatPopUp, self.methodPopUp, self.levelPopUp] ) {
        popup.translatesAutoresizingMaskIntoConstraints = NO;
        [popup.widthAnchor constraintGreaterThanOrEqualToConstant:200].active = YES;
    }

    for( NSDictionary<NSString *, NSString *> *item in FormatItems() )
        AddPopUpItem(self.formatPopUp, item[@"title"], item[@"value"]);
    for( int level = 1; level <= 9; ++level )
        AddPopUpItem(self.levelPopUp, [NSString stringWithFormat:@"%d", level], @(level));

    self.formatPopUp.target = self;
    self.formatPopUp.action = @selector(formatChanged:);
    self.methodPopUp.target = self;
    self.methodPopUp.action = @selector(methodChanged:);
    self.levelPopUp.target = self;
    self.levelPopUp.action = @selector(levelChanged:);

    self.rarSupportCheckbox =
        [NSButton checkboxWithTitle:NSLocalizedStringFromTable(@"Use the ncrar-helper component for RAR archives",
                                                               @"Preferences",
                                                               "Compression preferences: RAR helper checkbox")
                             target:self
                             action:@selector(rarSupportChanged:)];

    NSTextField *formatLabel = [NSTextField
        labelWithString:NSLocalizedStringFromTable(@"Format", @"Preferences", "Compression preferences: format label")];
    NSTextField *methodLabel =
        [NSTextField labelWithString:NSLocalizedStringFromTable(
                                         @"Algorithm", @"Preferences", "Compression preferences: algorithm label")];
    NSTextField *levelLabel = [NSTextField
        labelWithString:NSLocalizedStringFromTable(@"Level", @"Preferences", "Compression preferences: level label")];

    NSGridView *grid = [NSGridView gridViewWithViews:@[
        @[formatLabel, self.formatPopUp],
        @[methodLabel, self.methodPopUp],
        @[levelLabel, self.levelPopUp],
    ]];
    grid.rowSpacing = 8;
    grid.columnSpacing = 8;
    [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;

    NSStackView *stack = [[NSStackView alloc] initWithFrame:NSZeroRect];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 10;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    NSBox *separator = [[NSBox alloc] initWithFrame:NSZeroRect];
    separator.boxType = NSBoxSeparator;
    separator.translatesAutoresizingMaskIntoConstraints = NO;
    [separator.heightAnchor constraintEqualToConstant:1].active = YES;

    [stack addArrangedSubview:title];
    [stack addArrangedSubview:grid];
    [stack addArrangedSubview:separator];
    [stack addArrangedSubview:self.rarSupportCheckbox];

    self.helperStatusLabel = [NSTextField labelWithString:@""];
    self.helperStatusLabel.font = [NSFont systemFontOfSize:11];
    self.helperStatusLabel.textColor = NSColor.secondaryLabelColor;
    [stack addArrangedSubview:self.helperStatusLabel];

    [stack setCustomSpacing:14 afterView:grid];
    [stack setCustomSpacing:4 afterView:self.rarSupportCheckbox];
    [stack setCustomSpacing:12 afterView:separator];
    [separator.widthAnchor constraintEqualToAnchor:grid.widthAnchor].active = YES;

    [self.view addSubview:stack];
    // The other preference tabs centre their content horizontally; keep this one in line.
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [stack.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:18],
    ]];

    [self.view layoutSubtreeIfNeeded];
    const NSSize fitting = stack.fittingSize;
    // All xib-based preference tabs are 730 points wide; matching that keeps the window from
    // collapsing when this tab is selected.
    self.view.frame = NSMakeRect(0, 0, std::max(730.0, fitting.width + 40.0), std::max(200.0, fitting.height + 36.0));
}

- (void)loadSettings
{
    nc::config::Config &config = GlobalConfig();
    const nc::ops::CompressionOptions options = nc::ops::ResolveCompressionOptions(
        config.GetString(g_ConfigFormat), config.GetString(g_ConfigMethod), config.GetInt(g_ConfigLevel));

    NSString *format = [NSString stringWithUTF8String:nc::ops::CompressionFormatName(options.format)];
    SelectValue(self.formatPopUp, format);
    [self rebuildMethodPopUpForFormat:format
                      preferredMethod:[NSString stringWithUTF8String:nc::ops::CompressionMethodName(options.method)]];
    SelectValue(self.levelPopUp, @(options.level));

    self.rarSupportCheckbox.state = config.GetBool(g_ConfigRarSupport) ? NSControlStateValueOn : NSControlStateValueOff;
    [self updateLevelEnabled];
    [self updateHelperStatus];
}

- (void)rebuildMethodPopUpForFormat:(NSString *)_format preferredMethod:(NSString *)_preferred_method
{
    [self.methodPopUp removeAllItems];
    bool preferred_method_exists = false;
    for( NSDictionary<NSString *, NSString *> *item in MethodItemsForFormat(_format) ) {
        AddPopUpItem(self.methodPopUp, item[@"title"], item[@"value"]);
        if( [item[@"value"] isEqualToString:_preferred_method] )
            preferred_method_exists = true;
    }

    SelectValue(self.methodPopUp, preferred_method_exists ? _preferred_method : DefaultMethodForFormat(_format));
    [self updateLevelEnabled];
}

- (void)updateLevelEnabled
{
    NSString *method = SelectedValue(self.methodPopUp);
    self.levelPopUp.enabled = ![method isEqualToString:@"store"] && ![method isEqualToString:@"none"];
}

- (void)formatChanged:(id) [[maybe_unused]] _sender
{
    NSString *format = SelectedValue(self.formatPopUp);
    if( format == nil )
        return;
    GlobalConfig().Set(g_ConfigFormat, format.UTF8String);

    NSString *previous_method = SelectedValue(self.methodPopUp);
    [self rebuildMethodPopUpForFormat:format preferredMethod:previous_method];
    GlobalConfig().Set(g_ConfigMethod, SelectedValue(self.methodPopUp).UTF8String);
}

- (void)methodChanged:(id) [[maybe_unused]] _sender
{
    GlobalConfig().Set(g_ConfigMethod, SelectedValue(self.methodPopUp).UTF8String);
    [self updateLevelEnabled];
}

- (void)levelChanged:(id) [[maybe_unused]] _sender
{
    GlobalConfig().Set(g_ConfigLevel, [self.levelPopUp.selectedItem.representedObject intValue]);
}

- (void)rarSupportChanged:(id) [[maybe_unused]] _sender
{
    const bool enabled = self.rarSupportCheckbox.state == NSControlStateValueOn;
    GlobalConfig().Set(g_ConfigRarSupport, enabled);
    nc::vfs::rar::SetHelperEnabled(enabled);
    [self updateHelperStatus];
}

- (void)updateHelperStatus
{
    if( !nc::vfs::rar::IsHelperEnabled() ) {
        self.helperStatusLabel.stringValue =
            NSLocalizedStringFromTable(@"Disabled", @"Preferences", "Compression preferences: RAR helper status");
        return;
    }

    const std::optional<std::string> path = nc::vfs::rar::HelperPath();
    if( !path ) {
        self.helperStatusLabel.stringValue =
            NSLocalizedStringFromTable(@"Not installed - the built-in RAR reader is used",
                                       @"Preferences",
                                       "Compression preferences: RAR helper status");
        return;
    }

    NSString *const executable = [NSString stringWithUTF8String:path->c_str()];
    NSString *const bundle_path = [[[executable stringByDeletingLastPathComponent] stringByDeletingLastPathComponent]
        stringByDeletingLastPathComponent];
    NSString *const version =
        [[NSBundle bundleWithPath:bundle_path] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    if( version.length ) {
        self.helperStatusLabel.stringValue =
            [NSString stringWithFormat:NSLocalizedStringFromTable(@"Installed · version %@",
                                                                  @"Preferences",
                                                                  "Compression preferences: RAR helper status"),
                                       version];
    }
    else {
        self.helperStatusLabel.stringValue =
            NSLocalizedStringFromTable(@"Installed", @"Preferences", "Compression preferences: RAR helper status");
    }
}

- (NSToolbarItem *)toolbarItem
{
    NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:self.identifier];
    item.image = self.toolbarItemImage;
    item.label = self.toolbarItemLabel;
    item.enabled = true;
    return item;
}

- (NSString *)identifier
{
    return NSStringFromClass(self.class);
}

- (NSImage *)toolbarItemImage
{
    NSImage *image = [NSImage imageWithSystemSymbolName:@"doc.zipper" accessibilityDescription:nil];
    return image ?: [NSImage imageNamed:NSImageNameAdvanced];
}

- (NSString *)toolbarItemLabel
{
    return NSLocalizedStringFromTable(@"Compression", @"Preferences", "Compression preferences tab title");
}

@end
