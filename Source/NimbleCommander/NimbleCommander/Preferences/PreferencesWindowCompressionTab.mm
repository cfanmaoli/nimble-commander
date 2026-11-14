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

- (void)buildViews;
- (void)loadSettings;
- (void)rebuildMethodPopUpForFormat:(NSString *)_format preferredMethod:(NSString *)_preferred_method;
- (void)updateLevelEnabled;
- (void)formatChanged:(id)_sender;
- (void)methodChanged:(id)_sender;
- (void)levelChanged:(id)_sender;
- (void)rarSupportChanged:(id)_sender;
@end

@implementation PreferencesWindowCompressionTab
@synthesize formatPopUp;
@synthesize methodPopUp;
@synthesize levelPopUp;
@synthesize rarSupportCheckbox;

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
    NSTextField *title = [NSTextField
        labelWithString:NSLocalizedStringFromTable(@"Compression", @"Preferences", "Compression preferences title")];
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
        [NSButton checkboxWithTitle:NSLocalizedStringFromTable(@"Enable the RAR support component",
                                                               @"Preferences",
                                                               "Compression preferences: RAR support checkbox")
                             target:self
                             action:@selector(rarSupportChanged:)];

    NSTextField *formatLabel = [NSTextField
        labelWithString:NSLocalizedStringFromTable(@"Format", @"Preferences", "Compression preferences: format label")];
    NSTextField *methodLabel = [NSTextField
        labelWithString:NSLocalizedStringFromTable(@"Method", @"Preferences", "Compression preferences: method label")];
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
    [stack addArrangedSubview:title];
    [stack addArrangedSubview:grid];
    [stack addArrangedSubview:self.rarSupportCheckbox];
    [stack setCustomSpacing:14 afterView:grid];

    [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [stack.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:18],
    ]];

    [self.view layoutSubtreeIfNeeded];
    const NSSize fitting = stack.fittingSize;
    self.view.frame = NSMakeRect(0, 0, std::max(440.0, fitting.width + 40.0), std::max(200.0, fitting.height + 36.0));
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
