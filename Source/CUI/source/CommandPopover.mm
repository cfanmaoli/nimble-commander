// Copyright (C) 2024-2025 Michael Kazakov. Subject to GNU General Public License version 3.
#include "CommandPopover.h"
#include <Base/KeyCodes.h>
using namespace nc::base::keycodes;
#include <vector>
#include <ranges>
#include <algorithm>
#include <numeric>
#include <span>
#include <cmath>
#include <cwctype>
#include <optional>

static constexpr double g_ContentViewCornerRadius = 10.;

// Carbon virtual key codes for the arrow keys. Base/KeyCodes.h only lists the
// keys this component historically used, so define the two we need for column
// navigation locally instead of adding a dependency on HIToolbox.
static constexpr unsigned short g_LeftArrowKeyCode = 0x7B;
static constexpr unsigned short g_RightArrowKeyCode = 0x7C;

@interface NCCommandPopover (Private)
- (std::span<NCCommandPopoverItem *const>)commandItems;

@property(nonatomic, readwrite) NSSize contentSize;

@end

@interface NCCommandPopoverWindow : NSWindow
@end

@interface NCCommandPopoverContentView : NSView
@end

@interface NCCommandPopoverViewController : NSViewController <NSTableViewDataSource, //
                                                              NSTableViewDelegate,   //
                                                              NSTextFieldDelegate>
- (instancetype _Nonnull)initWithPopover:(NCCommandPopover *)_popover andTitle:(NSString *)_title;
- (void)tableView:(NSTableView *)_table didClickTableRow:(NSInteger)_row;
- (bool)processKeyDown:(NSEvent *)_event;
// A grid is made of N side-by-side table views. Each table view's tag is its
// column index; these helpers map a (table view, row) pair to the flat index
// in m_FilteredItems and activate/select that item.
- (NSInteger)flatIndexInTableView:(NSTableView *)_table forRow:(NSInteger)_row;
- (NCCommandPopoverItem *)itemInTableView:(NSTableView *)_table row:(NSInteger)_row;
- (NCCommandPopoverItem *)itemAtFlatIndex:(NSInteger)_flat;
- (void)activateItemAtFlatIndex:(NSInteger)_flat_index;
- (void)clearSelectionInOtherTableViews:(NSTableView *)_except;
- (void)moveFocusFrom:(NSTableView *)_from byColumns:(int)_delta;
- (void)recomputeRowsPerColumn;
- (void)updateScrollViewHeighConstraint;
@property(readonly, nonatomic) bool numericHotkeysEnabled;
@end

@interface NCCommandPopoverTableView : NSTableView
- (void)processMouseMoved:(NSPoint)_local_coords;
@end

@implementation NCCommandPopoverItem {
    NSString *m_Title;
    __weak id m_Target;
    SEL m_Action;
    id m_RepresentedObject;
    NSImage *m_Image;
    long m_Tag;
    bool m_IsSeparator;
    bool m_IsSectionHeader;
}
@synthesize tag = m_Tag;
@synthesize representedObject = m_RepresentedObject;
@synthesize image = m_Image;
@synthesize toolTip;

- (NCCommandPopoverItem *_Nonnull)init
{
    self = [super init];
    if( self ) {
        m_Title = @"";
        m_Tag = 0;
        m_IsSeparator = false;
        m_IsSectionHeader = false;
    }
    return self;
}

+ (NCCommandPopoverItem *_Nonnull)sectionHeaderWithTitle:(NSString *_Nonnull)_title
{
    NCCommandPopoverItem *item = [[NCCommandPopoverItem alloc] init];
    item->m_IsSectionHeader = true;
    item->m_Title = [_title copy];
    return item;
}

+ (NCCommandPopoverItem *_Nonnull)separatorItem
{
    NCCommandPopoverItem *item = [[NCCommandPopoverItem alloc] init];
    item->m_IsSeparator = true;
    return item;
}

- (NSString *)title
{
    return m_Title;
}

- (void)setTitle:(NSString *)_title
{
    if( m_IsSeparator )
        return;
    assert(_title != nullptr);
    m_Title = [_title copy];
}

- (bool)separatorItem
{
    return m_IsSeparator;
}

- (bool)sectionHeader
{
    return m_IsSectionHeader;
}

- (void)setTarget:(id)_target
{
    assert(!m_IsSeparator && !m_IsSectionHeader);
    m_Target = _target;
}

- (__weak id)target
{
    return m_Target;
}

- (void)setAction:(SEL)_action
{
    assert(!m_IsSeparator && !m_IsSectionHeader);
    m_Action = _action;
}

- (SEL)action
{
    return m_Action;
}

@end

@implementation NCCommandPopoverViewController {
    NSString *m_Title;
    NSTextField *m_LabelTextField;
    NSImageView *m_SearchIcon;
    NCCommandPopoverTableView *m_TableView; // primary (column 0) table view, also the keyboard first responder
    NSScrollView *m_ScrollView;             // primary (column 0) scroll view
    NSLayoutConstraint *m_ScrollViewHeightConstraint;
    NSFont *m_LabelFont;
    NSFont *m_SectionFont;
    __weak NCCommandPopover *m_Parent;
    std::vector<NCCommandPopoverItem *> m_AllItems;
    std::vector<NCCommandPopoverItem *> m_FilteredItems;
    std::vector<signed char> m_ItemIdxToHotKeyIdx; // negative means no mapping
    std::array<int, 12> m_HotKeyIdxToItemIdx;      // negative means no mapping
    double m_RegularRowHeight;
    double m_SeparatorRowHeight;

    // Multi-column grid (2.1.7). One table view per column, laid out side by
    // side. Items are distributed column-major: column c shows the flat items
    // [c*m_RowsPerColumn, (c+1)*m_RowsPerColumn). m_TableView is column 0.
    std::vector<NCCommandPopoverTableView *> m_TableViews;
    std::vector<NSScrollView *> m_ScrollViews;
    NSView *m_Grid;
    NSLayoutConstraint *m_GridWidthConstraint;
    int m_Columns;
    int m_RowsPerColumn;
}

- (instancetype _Nonnull)initWithPopover:(NCCommandPopover *)_popover andTitle:(NSString *)_title
{
    self = [super initWithNibName:nil bundle:nil];
    if( self ) {
        m_Parent = _popover;
        m_Title = _title;
        m_LabelFont = [NSFont menuFontOfSize:0.0];
        m_SectionFont = [NSFont menuFontOfSize:NSFont.smallSystemFontSize];
        m_RegularRowHeight = std::round(m_LabelFont.pointSize + 7.);
        m_SeparatorRowHeight = 11.;
    }
    return self;
}

- (void)loadView
{
    m_AllItems.assign(m_Parent.commandItems.begin(), m_Parent.commandItems.end());
    m_FilteredItems = m_AllItems;

    [self setupHotKeysMapping];
    const double max_title_width = [self maximumCommandTitleWidth];
    const double title_col_margin = 20.;
    const double title_col_width = std::max(max_title_width + title_col_margin, 160.);
    const double hk_col_width = [@"3" sizeWithAttributes:@{NSFontAttributeName: m_LabelFont}].width + 2.;
    const double img_col_width = 20.;
    const double column_width = img_col_width + title_col_width + hk_col_width + 16.;

    // 2.1.7: spread the items over several side-by-side columns on wide
    // screens. The caller asks for a number of columns via 'columns' (default
    // 1 keeps the classic single strip). Clamp by the screen width and by the
    // number of items so we never create empty or off-screen columns.
    const int requested = std::clamp(m_Parent.columns, 1, 3);
    NSScreen *const screen = NSScreen.mainScreen;
    const double avail = screen ? screen.visibleFrame.size.width - 80. : 1200.;
    const int fits = std::max(1, static_cast<int>(std::floor(avail / column_width)));
    const int by_items = std::max(1, static_cast<int>(std::min<size_t>(m_AllItems.size(), 3)));
    m_Columns = std::max(1, std::min(requested, std::min(fits, by_items)));
    [self recomputeRowsPerColumn];

    NCCommandPopoverContentView *v = [[NCCommandPopoverContentView alloc] initWithFrame:NSMakeRect(0., 0., 200., 200.)];

    m_SearchIcon = [[NSImageView alloc] initWithFrame:NSRect()];
    m_SearchIcon.translatesAutoresizingMaskIntoConstraints = false;
    m_SearchIcon.image = [NSImage imageNamed:NSImageNameTouchBarSearchTemplate];
    m_SearchIcon.imageAlignment = NSImageAlignCenter;
    m_SearchIcon.imageScaling = NSImageScaleProportionallyDown;
    m_SearchIcon.imageFrameStyle = NSImageFrameNone;
    [v addSubview:m_SearchIcon];

    m_LabelTextField = [[NSTextField alloc] initWithFrame:NSRect()];
    m_LabelTextField.stringValue = @"";
    m_LabelTextField.placeholderString = m_Title;
    m_LabelTextField.bordered = false;
    m_LabelTextField.editable = true;
    m_LabelTextField.drawsBackground = false;
    m_LabelTextField.translatesAutoresizingMaskIntoConstraints = false;
    m_LabelTextField.font = m_LabelFont;
    m_LabelTextField.focusRingType = NSFocusRingTypeNone;
    m_LabelTextField.usesSingleLineMode = true;
    m_LabelTextField.lineBreakMode = NSLineBreakByClipping;
    m_LabelTextField.delegate = self;
    [v addSubview:m_LabelTextField];

    // A plain container holds one scroll view per column. Each table view's tag
    // is its column index, which is how the data source maps a row to a flat
    // item. Columns are pinned with explicit constraints below (equal width and
    // height, side by side) instead of relying on NSStackView's alignment.
    m_Grid = [[NSView alloc] initWithFrame:NSRect()];
    m_Grid.translatesAutoresizingMaskIntoConstraints = false;
    [v addSubview:m_Grid];

    m_TableViews.clear();
    m_ScrollViews.clear();
    for( int col = 0; col < m_Columns; ++col ) {
        NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSRect()];
        sv.borderType = NSNoBorder;
        sv.hasVerticalScroller = false;
        sv.hasHorizontalScroller = false;
        sv.verticalScrollElasticity = NSScrollElasticityNone;
        sv.horizontalScrollElasticity = NSScrollElasticityNone;
        sv.translatesAutoresizingMaskIntoConstraints = false;
        sv.drawsBackground = false;
        sv.contentInsets = NSEdgeInsets{.top = 0., .left = 0., .bottom = 0., .right = 0.};

        NCCommandPopoverTableView *tv = [[NCCommandPopoverTableView alloc] initWithFrame:NSRect()];
        tv.autoresizingMask = NSViewNotSizable;
        tv.delegate = self;
        tv.dataSource = self;
        tv.tag = col;
        tv.headerView = nil;
        tv.allowsColumnReordering = false;
        tv.allowsColumnResizing = false;
        tv.allowsMultipleSelection = false;
        tv.allowsEmptySelection = true;
        tv.allowsColumnSelection = false;
        tv.allowsTypeSelect = false;
        tv.autosaveTableColumns = false;
        tv.intercellSpacing = NSMakeSize(0., 2);
        tv.style = NSTableViewStyleFullWidth;
        tv.usesAlternatingRowBackgroundColors = false;
        tv.backgroundColor = NSColor.clearColor;
        tv.rowSizeStyle = NSTableViewRowSizeStyleCustom;
        tv.rowHeight = m_RegularRowHeight;

        NSTableColumn *img_col = [[NSTableColumn alloc] initWithIdentifier:@"I"];
        img_col.width = img_col_width;
        [tv addTableColumn:img_col];

        NSTableColumn *label_col = [[NSTableColumn alloc] initWithIdentifier:@"L"];
        label_col.width = title_col_width;
        [tv addTableColumn:label_col];

        NSTableColumn *hk_col = [[NSTableColumn alloc] initWithIdentifier:@"K"];
        hk_col.width = hk_col_width;
        [tv addTableColumn:hk_col];

        sv.documentView = tv;
        [m_Grid addSubview:sv];
        m_TableViews.push_back(tv);
        m_ScrollViews.push_back(sv);

        if( col == 0 ) {
            m_TableView = tv;
            m_ScrollView = sv;
        }
    }

    // Pin every column: equal width, full grid height, laid left-to-right with
    // a 1pt gutter. This guarantees a clean aligned grid regardless of how
    // tall each column's content is.
    const double gutter = 1.;
    for( size_t i = 0; i < m_ScrollViews.size(); ++i ) {
        NSScrollView *sv = m_ScrollViews[i];
        [m_Grid addConstraint:[NSLayoutConstraint constraintWithItem:sv
                                                          attribute:NSLayoutAttributeTop
                                                          relatedBy:NSLayoutRelationEqual
                                                             toItem:m_Grid
                                                          attribute:NSLayoutAttributeTop
                                                         multiplier:1.
                                                           constant:0.]];
        [m_Grid addConstraint:[NSLayoutConstraint constraintWithItem:sv
                                                          attribute:NSLayoutAttributeBottom
                                                          relatedBy:NSLayoutRelationEqual
                                                             toItem:m_Grid
                                                          attribute:NSLayoutAttributeBottom
                                                         multiplier:1.
                                                           constant:0.]];
        if( i == 0 ) {
            [m_Grid addConstraint:[NSLayoutConstraint constraintWithItem:sv
                                                              attribute:NSLayoutAttributeLeading
                                                              relatedBy:NSLayoutRelationEqual
                                                                 toItem:m_Grid
                                                              attribute:NSLayoutAttributeLeading
                                                             multiplier:1.
                                                               constant:0.]];
        }
        else {
            NSScrollView *prev = m_ScrollViews[i - 1];
            [m_Grid addConstraint:[NSLayoutConstraint constraintWithItem:sv
                                                              attribute:NSLayoutAttributeLeading
                                                              relatedBy:NSLayoutRelationEqual
                                                                 toItem:prev
                                                              attribute:NSLayoutAttributeTrailing
                                                             multiplier:1.
                                                               constant:gutter]];
            [m_Grid addConstraint:[NSLayoutConstraint constraintWithItem:sv
                                                              attribute:NSLayoutAttributeWidth
                                                              relatedBy:NSLayoutRelationEqual
                                                                 toItem:prev
                                                              attribute:NSLayoutAttributeWidth
                                                             multiplier:1.
                                                               constant:0.]];
        }
    }
    if( !m_ScrollViews.empty() ) {
        [m_Grid addConstraint:[NSLayoutConstraint constraintWithItem:m_ScrollViews.back()
                                                          attribute:NSLayoutAttributeTrailing
                                                          relatedBy:NSLayoutRelationEqual
                                                             toItem:m_Grid
                                                          attribute:NSLayoutAttributeTrailing
                                                         multiplier:1.
                                                           constant:0.]];
    }

    auto views = NSDictionaryOfVariableBindings(m_LabelTextField, m_SearchIcon, m_Grid);
    [v addConstraints:[NSLayoutConstraint
                          constraintsWithVisualFormat:@"H:|-(6)-[m_SearchIcon(==16)]-(4)-[m_LabelTextField(>=40)]-(4)-|"
                                              options:0
                                              metrics:nil
                                                views:views]];

    [v addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-(==0)-[m_Grid]-(==0)-|"
                                                              options:0
                                                              metrics:nil
                                                                views:views]];
    [v addConstraints:[NSLayoutConstraint
                          constraintsWithVisualFormat:@"V:|-(6)-[m_LabelTextField]-(4)-[m_Grid(>=20)]-(4)-|"
                                              options:0
                                              metrics:nil
                                                views:views]];
    [v addConstraint:[NSLayoutConstraint constraintWithItem:m_SearchIcon
                                                  attribute:NSLayoutAttributeCenterY
                                                  relatedBy:NSLayoutRelationEqual
                                                     toItem:m_LabelTextField
                                                  attribute:NSLayoutAttributeCenterY
                                                 multiplier:1.
                                                   constant:0.]];
    [v addConstraint:[NSLayoutConstraint constraintWithItem:m_SearchIcon
                                                  attribute:NSLayoutAttributeHeight
                                                  relatedBy:NSLayoutRelationGreaterThanOrEqual
                                                     toItem:nil
                                                  attribute:NSLayoutAttributeNotAnAttribute
                                                 multiplier:1.
                                                   constant:16.]];

    m_GridWidthConstraint = [NSLayoutConstraint constraintWithItem:m_Grid
                                                         attribute:NSLayoutAttributeWidth
                                                         relatedBy:NSLayoutRelationGreaterThanOrEqual
                                                            toItem:nil
                                                         attribute:NSLayoutAttributeNotAnAttribute
                                                        multiplier:1.
                                                          constant:m_Columns * column_width +
                                                              (m_Columns - 1) * gutter];
    [v addConstraint:m_GridWidthConstraint];

    m_ScrollViewHeightConstraint = [NSLayoutConstraint constraintWithItem:m_Grid
                                                                attribute:NSLayoutAttributeHeight
                                                                relatedBy:NSLayoutRelationGreaterThanOrEqual
                                                                   toItem:nil
                                                                attribute:NSLayoutAttributeNotAnAttribute
                                                               multiplier:1.
                                                                 constant:0.];
    m_ScrollViewHeightConstraint.priority = NSLayoutPriorityWindowSizeStayPut;
    [v addConstraint:m_ScrollViewHeightConstraint];

    self.view = v;
    [self updateScrollViewHeighConstraint];
    [self.view layout];
}

- (void)updateScrollViewHeighConstraint
{
    // With a multi-column grid the popover grows sideways, not downwards:
    // each column shows at most `m_RowsPerColumn` rows (capped at 30). The
    // height is the tallest column so every column stays fully visible.
    const auto &items = m_FilteredItems;
    const size_t max_visible_rows = 30;
    double height = 2.;
    for( int col = 0; col < m_Columns; ++col ) {
        const size_t start = static_cast<size_t>(col) * m_RowsPerColumn;
        double col_height = 2.;
        const size_t visible = std::min<size_t>(m_RowsPerColumn, max_visible_rows);
        for( size_t row = 0; row < visible; ++row ) {
            const size_t idx = start + row;
            if( idx >= items.size() )
                break;
            col_height += items[idx].separatorItem ? m_SeparatorRowHeight : m_RegularRowHeight;
            if( row > 0 )
                col_height += m_TableView.intercellSpacing.height;
        }
        height = std::max(height, col_height);
    }
    m_ScrollViewHeightConstraint.constant = height;
}

// Recompute how many rows each column holds. Called whenever the filtered set
// changes (typing a filter) so columns rebalance instead of keeping stale rows.
- (void)recomputeRowsPerColumn
{
    const size_t count = m_FilteredItems.size();
    m_RowsPerColumn = static_cast<int>((count + m_Columns - 1) / m_Columns);
    if( m_RowsPerColumn < 1 )
        m_RowsPerColumn = 1;
}

// Column-major mapping: column c owns flat items [c*R, (c+1)*R).
- (NSInteger)flatIndexInTableView:(NSTableView *)_table forRow:(NSInteger)_row
{
    return static_cast<NSInteger>(_table.tag) * m_RowsPerColumn + _row;
}

- (NCCommandPopoverItem *)itemInTableView:(NSTableView *)_table row:(NSInteger)_row
{
    return [self itemAtFlatIndex:[self flatIndexInTableView:_table forRow:_row]];
}

- (NCCommandPopoverItem *)itemAtFlatIndex:(NSInteger)_flat
{
    if( _flat < 0 || _flat >= static_cast<NSInteger>(m_FilteredItems.size()) )
        return nil;
    return m_FilteredItems[_flat];
}

- (void)activateItemAtFlatIndex:(NSInteger)_flat
{
    NCCommandPopoverItem *const item = [self itemAtFlatIndex:_flat];
    if( item == nil )
        return;
    SEL action = item.action;
    id target = item.target;

    [m_Parent close]; // close before firing, matching the original behaviour

    if( ![NSApplication.sharedApplication sendAction:action to:target from:item] )
        NSBeep();
}

- (void)clearSelectionInOtherTableViews:(NSTableView *)_except
{
    for( NSTableView *tv : m_TableViews )
        if( tv != _except )
            [tv selectRowIndexes:[NSIndexSet indexSet] byExtendingSelection:false];
}

- (void)moveFocusFrom:(NSTableView *)_from byColumns:(int)_delta
{
    const int target_col = static_cast<int>(_from.tag) + _delta;
    if( target_col < 0 || target_col >= m_Columns )
        return;
    NSTableView *const target = m_TableViews[target_col];
    [self clearSelectionInOtherTableViews:target];
    const NSInteger rows = [self numberOfRowsInTableView:target];
    for( NSInteger row = 0; row < rows; ++row ) {
        if( [self tableView:target shouldSelectRow:row] ) {
            [target selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:false];
            break;
        }
    }
    [self.view.window makeFirstResponder:target];
}

- (void)viewDidAppear
{
    [super viewDidAppear];
    [self.view.window makeFirstResponder:m_TableView];
    [self updateScrollViewHeighConstraint];
    [self.view layout];
    m_Parent.contentSize = self.view.fittingSize;

    // First try place the selection where the mouse cursor currently is to avoid flicker.
    // With a grid, find which column the cursor is over and only highlight there.
    const NSPoint global_mouse_location = NSEvent.mouseLocation;
    const NSPoint window_mouse_location = [self.view.window convertPointFromScreen:global_mouse_location];
    for( NCCommandPopoverTableView *tv : m_TableViews ) {
        const NSPoint table_mouse_location = [tv convertPoint:window_mouse_location fromView:nil];
        if( [tv mouse:table_mouse_location inRect:tv.bounds] ) {
            [self clearSelectionInOtherTableViews:tv];
            [tv processMouseMoved:table_mouse_location];
            break;
        }
    }

    // And only afterwards set to the first row if no column has a selection
    bool any_selected = false;
    for( NSTableView *tv : m_TableViews ) {
        if( tv.selectedRow != -1 ) {
            any_selected = true;
            break;
        }
    }
    if( !any_selected ) {
        [self selectFirstSelectableRow];
    }
}

- (double)maximumCommandTitleWidth
{
    if( m_AllItems.empty() ) {
        return 0.;
    }
    auto attributes = @{NSFontAttributeName: m_LabelFont};
    auto widths = m_AllItems | std::views::transform([attributes](NCCommandPopoverItem *_item) -> double {
                      return [_item.title sizeWithAttributes:attributes].width;
                  });
    return *std::ranges::max_element(widths);
}

- (void)setupHotKeysMapping
{
    const auto &items = m_FilteredItems;
    m_HotKeyIdxToItemIdx.fill(-1);
    m_ItemIdxToHotKeyIdx.resize(items.size(), -1);
    for( size_t it_idx = 0, hk_idx = 0; it_idx < items.size() && hk_idx < m_HotKeyIdxToItemIdx.size(); ++it_idx ) {
        if( items[it_idx].separatorItem || items[it_idx].sectionHeader )
            continue;
        m_ItemIdxToHotKeyIdx[it_idx] = static_cast<signed char>(hk_idx);
        m_HotKeyIdxToItemIdx[hk_idx] = static_cast<int>(it_idx);
        ++hk_idx;
    }
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
    const NSInteger col = tableView.tag;
    const NSInteger start = col * m_RowsPerColumn;
    const NSInteger total = static_cast<NSInteger>(m_FilteredItems.size());
    if( start >= total )
        return 0;
    return std::min<NSInteger>(m_RowsPerColumn, total - start);
}

- (NSString *)hotkeyLabelForItemAtIndex:(size_t)_index
{
    if( _index >= m_ItemIdxToHotKeyIdx.size() )
        return @"";
    switch( m_ItemIdxToHotKeyIdx[_index] ) {
        case 0:
            return @"1";
        case 1:
            return @"2";
        case 2:
            return @"3";
        case 3:
            return @"4";
        case 4:
            return @"5";
        case 5:
            return @"6";
        case 6:
            return @"7";
        case 7:
            return @"8";
        case 8:
            return @"9";
        case 9:
            return @"0";
        case 10:
            return @"-";
        case 11:
            return @"=";
        default:
            return @"";
    }
}

- (std::optional<size_t>)itemIndexFromKeyDown:(NSEvent *)_event
{
    if( !self.numericHotkeysEnabled )
        return {};

    // Use only clear keypresses, no modifiers
    if( _event.modifierFlags & (NSEventModifierFlagShift | NSEventModifierFlagControl | NSEventModifierFlagOption |
                                NSEventModifierFlagCommand) )
        return {};

    NSString *chars = _event.characters;
    if( chars == nil || chars.length != 1 )
        return {};
    const unsigned short ch = [chars characterAtIndex:0];
    auto to_idx = [&](size_t _idx) -> std::optional<size_t> {
        assert(_idx < m_HotKeyIdxToItemIdx.size());
        if( m_HotKeyIdxToItemIdx[_idx] >= 0 )
            return m_HotKeyIdxToItemIdx[_idx];
        return {};
    };

    switch( ch ) {
        case '1':
            return to_idx(0);
        case '2':
            return to_idx(1);
        case '3':
            return to_idx(2);
        case '4':
            return to_idx(3);
        case '5':
            return to_idx(4);
        case '6':
            return to_idx(5);
        case '7':
            return to_idx(6);
        case '8':
            return to_idx(7);
        case '9':
            return to_idx(8);
        case '0':
            return to_idx(9);
        case '-':
            return to_idx(10);
        case '=':
            return to_idx(11);
        default:
            return {};
    }
}

- (NSView *)tableView:(NSTableView *)_table viewForTableColumn:(NSTableColumn *)_column row:(NSInteger)_row
{
    NCCommandPopoverItem *item = [self itemInTableView:_table row:_row];
    if( item == nil ) {
        return nil;
    }
    if( item.separatorItem ) {
        NSBox *box = [[NSBox alloc] initWithFrame:NSRect()];
        box.boxType = NSBoxSeparator;
        box.translatesAutoresizingMaskIntoConstraints = false;
        NSTableCellView *cv = [[NSTableCellView alloc] initWithFrame:NSRect()];
        [cv addSubview:box];
        [cv addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-(==0)-[box]-(==0)-|"
                                                                   options:0
                                                                   metrics:nil
                                                                     views:NSDictionaryOfVariableBindings(box)]];
        [cv addConstraint:[NSLayoutConstraint constraintWithItem:box
                                                       attribute:NSLayoutAttributeCenterY
                                                       relatedBy:NSLayoutRelationEqual
                                                          toItem:cv
                                                       attribute:NSLayoutAttributeCenterY
                                                      multiplier:1.
                                                        constant:0.]];
        [cv addConstraint:[NSLayoutConstraint constraintWithItem:box
                                                       attribute:NSLayoutAttributeHeight
                                                       relatedBy:NSLayoutRelationEqual
                                                          toItem:nil
                                                       attribute:NSLayoutAttributeNotAnAttribute
                                                      multiplier:0.
                                                        constant:1.]];
        return cv;
    }
    else if( item.sectionHeader ) {
        return nil; // handled in rowViewForRow
    }
    else {

        if( [_column.identifier isEqualToString:@"I"] ) {
            if( item.image == nil )
                return nil;
            NSImageView *iv = [[NSImageView alloc] initWithFrame:NSRect()];
            iv.image = item.image;
            iv.imageFrameStyle = NSImageFrameNone;
            iv.imageAlignment = NSImageAlignCenter;
            iv.imageScaling = NSImageScaleProportionallyDown;
            iv.translatesAutoresizingMaskIntoConstraints = false;
            NSTableCellView *cv = [[NSTableCellView alloc] initWithFrame:NSRect()];
            [cv addSubview:iv];
            cv.imageView = iv;
            [cv addConstraints:@[
                [NSLayoutConstraint constraintWithItem:iv
                                             attribute:NSLayoutAttributeWidth
                                             relatedBy:NSLayoutRelationEqual
                                                toItem:nil
                                             attribute:NSLayoutAttributeNotAnAttribute
                                            multiplier:1.
                                              constant:16.],
                [NSLayoutConstraint constraintWithItem:iv
                                             attribute:NSLayoutAttributeHeight
                                             relatedBy:NSLayoutRelationEqual
                                                toItem:nil
                                             attribute:NSLayoutAttributeNotAnAttribute
                                            multiplier:1.
                                              constant:16.],
                [NSLayoutConstraint constraintWithItem:iv
                                             attribute:NSLayoutAttributeRight
                                             relatedBy:NSLayoutRelationEqual
                                                toItem:cv
                                             attribute:NSLayoutAttributeRight
                                            multiplier:1.
                                              constant:-4.],
                [NSLayoutConstraint constraintWithItem:iv
                                             attribute:NSLayoutAttributeCenterY
                                             relatedBy:NSLayoutRelationEqual
                                                toItem:cv
                                             attribute:NSLayoutAttributeCenterY
                                            multiplier:1.
                                              constant:0.]
            ]];
            return cv;
        }

        if( [_column.identifier isEqualToString:@"L"] ) {
            NSTextField *tf = [[NSTextField alloc] initWithFrame:NSRect()];
            tf.translatesAutoresizingMaskIntoConstraints = false;
            tf.stringValue = item.title;
            tf.bordered = false;
            tf.editable = false;
            tf.usesSingleLineMode = true;
            tf.drawsBackground = false;
            tf.font = m_LabelFont;
            tf.textColor = NSColor.labelColor;
            tf.toolTip = item.toolTip;

            NSTableCellView *cv = [[NSTableCellView alloc] initWithFrame:NSRect()];
            [cv addSubview:tf];
            cv.textField = tf;
            [cv addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-(==0)-[tf]-(==0)-|"
                                                                       options:0
                                                                       metrics:nil
                                                                         views:NSDictionaryOfVariableBindings(tf)]];
            [cv addConstraint:[NSLayoutConstraint constraintWithItem:tf
                                                           attribute:NSLayoutAttributeCenterY
                                                           relatedBy:NSLayoutRelationEqual
                                                              toItem:cv
                                                           attribute:NSLayoutAttributeCenterY
                                                          multiplier:1.
                                                            constant:0.]];
            return cv;
        }

        if( [_column.identifier isEqualToString:@"K"] && self.numericHotkeysEnabled ) {
            const NSInteger flat = [self flatIndexInTableView:_table forRow:_row];
            NSString *hk = [self hotkeyLabelForItemAtIndex:static_cast<size_t>(flat)];
            if( hk.length == 0 )
                return nil;
            NSTextField *tf = [[NSTextField alloc] initWithFrame:NSRect()];
            tf.translatesAutoresizingMaskIntoConstraints = false;
            tf.stringValue = hk;
            tf.bordered = false;
            tf.editable = false;
            tf.drawsBackground = false;
            tf.usesSingleLineMode = true;
            tf.alignment = NSTextAlignmentCenter;
            tf.font = m_LabelFont;
            tf.textColor = NSColor.disabledControlTextColor;

            NSTableCellView *cv = [[NSTableCellView alloc] initWithFrame:NSRect()];
            [cv addSubview:tf];
            cv.textField = tf;
            [cv addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-(==0)-[tf]-(==0)-|"
                                                                       options:0
                                                                       metrics:nil
                                                                         views:NSDictionaryOfVariableBindings(tf)]];
            [cv addConstraint:[NSLayoutConstraint constraintWithItem:tf
                                                           attribute:NSLayoutAttributeCenterY
                                                           relatedBy:NSLayoutRelationEqual
                                                              toItem:cv
                                                           attribute:NSLayoutAttributeCenterY
                                                          multiplier:1.
                                                            constant:0.]];
            return cv;
        }
    }
    return nil;
}

- (nullable NSTableRowView *)tableView:(NSTableView *)_table rowViewForRow:(NSInteger)_row
{
    NCCommandPopoverItem *item = [self itemInTableView:_table row:_row];
    if( item == nil || !item.sectionHeader )
        return nil;

    NSTextField *tf = [[NSTextField alloc] initWithFrame:NSRect()];
    tf.translatesAutoresizingMaskIntoConstraints = false;
    tf.stringValue = item.title;
    tf.bordered = false;
    tf.editable = false;
    tf.usesSingleLineMode = true;
    tf.drawsBackground = false;
    tf.font = m_SectionFont;
    tf.textColor = NSColor.disabledControlTextColor;

    NSTableRowView *rv = [[NSTableRowView alloc] initWithFrame:NSRect()];
    [rv addSubview:tf];
    [rv addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-(==6)-[tf]-(==0)-|"
                                                               options:0
                                                               metrics:nil
                                                                 views:NSDictionaryOfVariableBindings(tf)]];
    [rv addConstraint:[NSLayoutConstraint constraintWithItem:tf
                                                   attribute:NSLayoutAttributeCenterY
                                                   relatedBy:NSLayoutRelationEqual
                                                      toItem:rv
                                                   attribute:NSLayoutAttributeCenterY
                                                  multiplier:1.
                                                    constant:0.]];
    return rv;
}

- (void)tableView:(NSTableView *)_table didClickTableRow:(NSInteger)_row
{
    [self activateItemAtFlatIndex:[self flatIndexInTableView:_table forRow:_row]];
}

- (double)tableView:(NSTableView *)_table heightOfRow:(long)_row
{
    NCCommandPopoverItem *item = [self itemInTableView:_table row:_row];
    if( item != nil && item.separatorItem )
        return m_SeparatorRowHeight;
    return m_RegularRowHeight;
}

- (BOOL)tableView:(NSTableView *)_table shouldSelectRow:(NSInteger)_row
{
    NCCommandPopoverItem *item = [self itemInTableView:_table row:_row];
    if( item != nil )
        return !(item.separatorItem || item.sectionHeader);
    return false;
}

- (bool)processKeyDown:(NSEvent *)_event
{
    // Use only clear keypresses, no modifiers
    if( _event.modifierFlags & (NSEventModifierFlagControl | NSEventModifierFlagCommand) )
        return false;

    const auto keycode = _event.keyCode;
    if( keycode == kVK_Delete ) {
        NSString *str = m_LabelTextField.stringValue ? m_LabelTextField.stringValue : @"";
        if( str.length > 0 ) {
            str = [str substringToIndex:str.length - 1];
            m_LabelTextField.stringValue = str;
            [self updateFiltering];
            return true;
        }
        else {
            return false;
        }
    }

    static NSCharacterSet *const allowed = [] {
        NSMutableCharacterSet *const set = [[NSMutableCharacterSet alloc] init];
        [set formUnionWithCharacterSet:NSCharacterSet.alphanumericCharacterSet];
        [set formUnionWithCharacterSet:NSCharacterSet.punctuationCharacterSet];
        [set formUnionWithCharacterSet:NSCharacterSet.symbolCharacterSet];
        return set.invertedSet;
    }();
    NSString *chars = _event.characters;
    if( chars.length == 0 || [chars rangeOfCharacterFromSet:allowed].location != NSNotFound ) {
        return false;
    }

    NSString *str = m_LabelTextField.stringValue ? m_LabelTextField.stringValue : @"";
    str = [str stringByAppendingString:chars];
    m_LabelTextField.stringValue = str;

    [self updateFiltering];
    return true;
}

- (void)controlTextDidChange:(NSNotification *) [[maybe_unused]] _obj
{
    [self updateFiltering];
}

- (BOOL)control:(NSControl *)_control textView:(NSTextView *)_text_biew doCommandBySelector:(SEL)_sel
{
    if( _control == m_LabelTextField && _sel == @selector(cancelOperation:) ) {
        [m_Parent close];
        return true;
    }
    return false;
}

// Subsequence match: every character of _needle appears in _haystack in order
// (case-insensitive). This is the classic command-palette fuzzy algorithm:
// "gof" matches "Go To Folder", "ncm" matches "New Command Line Mode".
static bool FuzzySubsequenceMatch(NSString *_haystack, NSString *_needle)
{
    if( _needle.length == 0 )
        return true;
    const NSUInteger needle_len = _needle.length;
    NSUInteger n = 0;
    for( NSUInteger i = 0; i < _haystack.length && n < needle_len; ++i ) {
        const unichar h = [_haystack characterAtIndex:i];
        const unichar c = [_needle characterAtIndex:n];
        if( towlower(static_cast<wint_t>(h)) == towlower(static_cast<wint_t>(c)) )
            ++n;
    }
    return n == needle_len;
}

- (void)updateFiltering
{
    NSString *str = m_LabelTextField.stringValue ? m_LabelTextField.stringValue : @"";
    const bool fuzzy = m_Parent.fuzzyFiltering;
    auto validate = [str, fuzzy](NCCommandPopoverItem *_item) -> bool {
        if( str.length == 0 )
            return true; // no filtering
        if( _item.separatorItem || _item.sectionHeader )
            return false;
        if( fuzzy )
            return FuzzySubsequenceMatch(_item.title, str);
        return [_item.title rangeOfString:str options:NSCaseInsensitiveSearch].location != NSNotFound;
    };

    std::vector<NCCommandPopoverItem *> new_filtered;
    std::ranges::copy_if(m_AllItems, std::back_inserter(new_filtered), validate);
    if( new_filtered == m_FilteredItems )
        return; // nothing to do

    m_FilteredItems = new_filtered;
    [self setupHotKeysMapping];
    [self recomputeRowsPerColumn];
    for( NSTableView *tv : m_TableViews )
        [tv reloadData];
    [self selectFirstSelectableRow];

    [self updateScrollViewHeighConstraint];
    [self.view layout];
    m_Parent.contentSize = self.view.fittingSize;
}

- (void)selectFirstSelectableRow
{
    [self clearSelectionInOtherTableViews:m_TableView];
    const NSInteger rows = [self numberOfRowsInTableView:m_TableView];
    for( NSInteger row = 0; row < rows; ++row ) {
        if( [self tableView:m_TableView shouldSelectRow:row] ) {
            [m_TableView selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:false];
            return;
        }
    }
}

- (bool)numericHotkeysEnabled
{
    return m_LabelTextField.stringValue == nil || m_LabelTextField.stringValue.length == 0;
}

@end

static constexpr NSTrackingAreaOptions g_TrackingOptions =
    NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved | NSTrackingActiveInActiveApp;

@implementation NCCommandPopoverTableView {
    NSTrackingArea *m_TrackingArea;
}

- (instancetype)initWithFrame:(NSRect)_frame
{
    self = [super initWithFrame:_frame];
    if( self ) {
        m_TrackingArea = [[NSTrackingArea alloc] initWithRect:self.bounds
                                                      options:g_TrackingOptions
                                                        owner:self
                                                     userInfo:nil];
        [self addTrackingArea:m_TrackingArea];
    }
    return self;
}

- (void)keyDown:(NSEvent *)_event
{
    NCCommandPopoverViewController *ctrl = static_cast<NCCommandPopoverViewController *>(self.delegate);
    assert(ctrl != nil);
    const unsigned short keycode = _event.keyCode;
    if( keycode == kVK_Return || keycode == kVK_ANSI_KeypadEnter || keycode == kVK_Space ) {
        const long selected = self.selectedRow;
        if( selected != -1 ) {
            [ctrl tableView:self didClickTableRow:selected];
        }
        else {
            NSBeep();
        }
    }
    else if( keycode == kVK_Home ) {
        const long rows = self.numberOfRows;
        for( long row = 0; row < rows; ++row )
            if( [ctrl tableView:self shouldSelectRow:row] ) {
                [self selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:false];
                [self scrollRowToVisible:row];
                break;
            }
    }
    else if( keycode == kVK_End ) {
        const long rows = self.numberOfRows;
        for( long row = rows - 1; row >= 0; --row )
            if( [ctrl tableView:self shouldSelectRow:row] ) {
                [self selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:false];
                [self scrollRowToVisible:row];
                break;
            }
    }
    else if( keycode == g_LeftArrowKeyCode || keycode == g_RightArrowKeyCode ) {
        // In a grid, left/right move the keyboard focus between columns.
        [ctrl moveFocusFrom:self byColumns:(keycode == g_RightArrowKeyCode ? 1 : -1)];
    }
    else if( auto idx = [ctrl itemIndexFromKeyDown:_event] ) {
        // itemIndexFromKeyDown returns a *flat* index into m_FilteredItems
        // (the numeric hotkeys are assigned in flat order), so bypass the
        // (column,row) mapping and activate it directly.
        [ctrl activateItemAtFlatIndex:static_cast<NSInteger>(*idx)];
    }
    else if( [ctrl processKeyDown:_event] ) {
        /*nothing - already processed*/
    }
    else {
        [super keyDown:_event];
    }
}

- (void)updateTrackingAreas
{
    [super updateTrackingAreas];
    [self removeTrackingArea:m_TrackingArea];
    m_TrackingArea = [[NSTrackingArea alloc] initWithRect:self.bounds
                                                  options:g_TrackingOptions
                                                    owner:self
                                                 userInfo:nil];
    [self addTrackingArea:m_TrackingArea];
}

- (void)processMouseMoved:(NSPoint)_local_coords
{
    NCCommandPopoverViewController *ctrl = static_cast<NCCommandPopoverViewController *>(self.delegate);
    const long row = [self rowAtPoint:_local_coords];
    const bool over_selectable = row >= 0 && row < self.numberOfRows && [ctrl tableView:self shouldSelectRow:row];
    if( over_selectable ) {
        // Only one cell across the whole grid may be highlighted at a time.
        [ctrl clearSelectionInOtherTableViews:self];
        if( row != self.selectedRow )
            [self selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:false];
    }
    else {
        [self selectRowIndexes:[NSIndexSet indexSet] byExtendingSelection:false];
    }
}

- (void)mouseMoved:(NSEvent *)_event
{
    const NSPoint global = _event.locationInWindow;
    const NSPoint local = [self convertPoint:global fromView:nil];
    [self processMouseMoved:local];
}

- (void)mouseEntered:(NSEvent *)_event
{
    [self mouseMoved:_event];
}

- (void)mouseExited:(NSEvent *)_event
{
    [self selectRowIndexes:[NSIndexSet indexSet] byExtendingSelection:false];
}

- (void)mouseDown:(NSEvent *)_event
{
    [super mouseDown:_event];
    const NSPoint global = _event.locationInWindow;
    const NSPoint local = [self convertPoint:global fromView:nil];
    if( const long row = [self rowAtPoint:local]; row != -1 && [self.delegate tableView:self shouldSelectRow:row] ) {
        [static_cast<NCCommandPopoverViewController *>(self.delegate) tableView:self didClickTableRow:row];
    }
}

@end

@implementation NCCommandPopoverWindow {
    id m_GlobalEventMonitor;
    id m_LocalEventMonitor;
}

- (instancetype)initWithContentRect:(NSRect)contentRect
{
    self = [super initWithContentRect:contentRect
                            styleMask:NSWindowStyleMaskBorderless
                              backing:NSBackingStoreBuffered
                                defer:true];
    if( self ) {
        self.opaque = false;
        self.backgroundColor = NSColor.clearColor;
        self.level = NSPopUpMenuWindowLevel;
        self.ignoresMouseEvents = false;
        self.hasShadow = true;
        self.releasedWhenClosed = false;
    }
    return self;
}

- (BOOL)canBecomeKeyWindow
{
    return true;
}

- (void)makeKeyAndOrderFront:(nullable id)_sender
{
    [super makeKeyAndOrderFront:_sender];

    __weak NCCommandPopoverWindow *weak_self = self;
    const NSEventMask mask = NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown | NSEventMaskOtherMouseDown;
    m_GlobalEventMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:mask
                                                                  handler:^(NSEvent *_Nonnull _event) {
                                                                    if( NCCommandPopoverWindow *me = weak_self )
                                                                        [me closeIfNeededWithMouseEvent:_event];
                                                                  }];
    m_LocalEventMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:mask
                                                                handler:^(NSEvent *_Nonnull _event) {
                                                                  if( NCCommandPopoverWindow *me = weak_self )
                                                                      [me closeIfNeededWithMouseEvent:_event];
                                                                  return _event;
                                                                }];
}

- (void)closeIfNeededWithMouseEvent:(NSEvent *)_event
{
    const NSPoint global = [_event locationInWindow];
    const NSPoint local = [self.contentView convertPoint:global fromView:nil];
    if( !NSPointInRect(local, self.contentView.bounds) )
        [self close];
}

- (void)keyDown:(NSEvent *)_event
{
    if( _event.keyCode == kVK_Escape )
        [self close];
    else
        [super keyDown:_event];
}

- (void)close
{
    if( m_GlobalEventMonitor ) {
        [NSEvent removeMonitor:m_GlobalEventMonitor];
        m_GlobalEventMonitor = nil;
    }
    if( m_LocalEventMonitor ) {
        [NSEvent removeMonitor:m_LocalEventMonitor];
        m_LocalEventMonitor = nil;
    }

    [super close];
}

@end
@implementation NCCommandPopoverContentView

- (instancetype)initWithFrame:(NSRect)_rect
{
    self = [super initWithFrame:_rect];
    if( self ) {
        self.wantsLayer = true;
        self.layer.cornerRadius = g_ContentViewCornerRadius;
        self.layer.masksToBounds = true;
    }
    return self;
}

- (void)drawRect:(NSRect)_rc
{
    [super drawRect:_rc];
    [NSColor.clearColor setFill];
    NSRectFill(self.bounds);

    [NSColor.windowBackgroundColor setFill];
    [[NSBezierPath bezierPathWithRoundedRect:self.bounds
                                     xRadius:g_ContentViewCornerRadius
                                     yRadius:g_ContentViewCornerRadius] fill];
}

@end

@implementation NCCommandPopover {
    std::vector<NCCommandPopoverItem *> m_Items;
    NCCommandPopoverViewController *m_Controller;
    NCCommandPopoverWindow *m_Window;
    NSSize m_ContentSize;
    __weak id<NCCommandPopoverDelegate> m_Delegate;
    bool m_FuzzyFiltering;
    int m_Columns;
}

@synthesize delegate = m_Delegate;
@synthesize fuzzyFiltering = m_FuzzyFiltering;
@synthesize columns = m_Columns;

- (instancetype _Nonnull)initWithTitle:(NSString *_Nonnull)_title
{
    self = [super init];
    if( self ) {
        m_Columns = 1; // default: classic single-column list
        m_Controller = [[NCCommandPopoverViewController alloc] initWithPopover:self andTitle:_title];
    }
    return self;
}

- (void)dealloc
{
    if( m_Window ) {
        m_Window.delegate = nil;
        [m_Window close];
    }
}

- (void)addItem:(NCCommandPopoverItem *_Nonnull)_new_item
{
    assert(std::ranges::find(m_Items, _new_item) == m_Items.end());
    m_Items.push_back(_new_item);
}

- (void)showRelativeToRect:(NSRect)_positioning_rect
                    ofView:(NSView *_Nonnull)_positioning_view
                 alignment:(NCCommandPopoverAlignment)_alignment
{
    NSView *view = m_Controller.view;
    m_ContentSize = view.fittingSize;

    const NSRect rect_in_window = [_positioning_view convertRect:_positioning_rect toView:nil];
    const NSRect rect_on_screen = [_positioning_view.window convertRectToScreen:rect_in_window];
    const double sx = m_ContentSize.width;
    const double sy = m_ContentSize.height;
    const double initial_x = [&] {
        if( _alignment == NCCommandPopoverAlignment::Left )
            return NSMinX(rect_on_screen);
        else if( _alignment == NCCommandPopoverAlignment::Right )
            return NSMaxX(rect_on_screen) - sx;
        else
            return NSMinX(rect_on_screen) + ((rect_on_screen.size.width - sx) / 2.);
    }();
    const double y = NSMinY(rect_on_screen) - m_ContentSize.height;
    NSScreen *screen = _positioning_view.window.screen;
    const NSRect screen_rect = screen.visibleFrame;
    const double x = [&] {
        if( initial_x < screen_rect.origin.x )
            return screen_rect.origin.x;
        else if( initial_x + sx > NSMaxX(screen_rect) )
            return NSMaxX(screen_rect) - sx;
        else
            return initial_x;
    }();
    m_Window = [[NCCommandPopoverWindow alloc] initWithContentRect:NSMakeRect(x, y, sx, sy)];
    m_Window.contentView = view;
    m_Window.delegate = self;
    [m_Window makeKeyAndOrderFront:nil];
}

- (std::span<NCCommandPopoverItem *const>)commandItems
{
    return m_Items;
}

- (void)close
{
    [m_Window close];
}

- (void)windowDidResignKey:(NSNotification *)_notification
{
    [self close];
}

- (void)windowWillClose:(NSNotification *)_notification
{
    if( id<NCCommandPopoverDelegate> delegate = m_Delegate;
        delegate != nil && [delegate respondsToSelector:@selector(commandPopoverDidClose:)] ) {
        [delegate commandPopoverDidClose:self];
    }

    m_Window = nil;
    m_Controller = nil;
    m_Items.clear();
}

- (NSSize)contentSize
{
    return m_ContentSize;
}

- (void)setContentSize:(NSSize)contentSize
{
    if( !NSEqualSizes(m_ContentSize, contentSize) ) {
        m_ContentSize = contentSize;
        const NSRect frame = m_Window.frame;
        NSRect new_frame = NSMakeRect(frame.origin.x,
                                      frame.origin.y - (m_ContentSize.height - frame.size.height),
                                      m_ContentSize.width,
                                      m_ContentSize.height);
        [m_Window setFrame:new_frame display:true animate:false];
    }
}

@end
