// Copyright (C) 2018-2024 Michael Kazakov. Subject to GNU General Public License version 3.
#include "PanelBriefViewFixedWidthLayoutEngine.h"
#include <algorithm>
#include <cmath>
#include <numeric>

namespace nc::panel::view::brief {

void FixedWidthLayoutEngine::Layout(const FixedWidthLayoutEngine::Params &_params)
{
    CopyInputData(_params);
    BuildGrid(_params);
}

void FixedWidthLayoutEngine::CopyInputData(const Params &_params)
{
    if( _params.items_number < 0 || _params.item_height < 1 || _params.item_width < 1 )
        throw std::logic_error("FixedWidthLayoutEngine: invalid input data");
    m_ItemsNumber = _params.items_number;
    m_ItemWidth = _params.item_width;
    m_ItemHeight = _params.item_height;
}

static void FillColumnsPositions(std::vector<int> &_pos, int _number, int _item_width)
{
    const auto generator = [pos = 0, step = _item_width]() mutable {
        const auto ret = pos;
        pos += step;
        return ret;
    };
    _pos.resize(_number);
    std::ranges::generate(_pos, generator);
}

static void FillColumnsWidths(std::vector<int> &_widths, int _number, int _item_width)
{
    _widths.resize(_number);
    std::ranges::fill(_widths, _item_width);
}

void FixedWidthLayoutEngine::BuildGrid(const Params &_params)
{
    m_RowsNumber = NumberOfRowsForViewHeight(_params.clip_view_bounds.size.height, m_ItemHeight);
    if( m_RowsNumber == 0 ) {
        // the view is shorter than a single item - everything goes into one column
        m_ColumnsNumber = m_ItemsNumber > 0 ? 1 : 0;
        m_ContentSize = NSMakeSize(0.0, 0.0);
        m_ColumnsPositions.assign(m_ColumnsNumber, 0);
        m_ColumnsWidths.assign(m_ColumnsNumber, m_ItemWidth);
    }
    else {
        m_ColumnsNumber =
            (m_ItemsNumber % m_RowsNumber != 0) ? ((m_ItemsNumber / m_RowsNumber) + 1) : (m_ItemsNumber / m_RowsNumber);
        m_ContentSize = NSMakeSize(m_ColumnsNumber * m_ItemWidth, m_RowsNumber * m_ItemHeight);
        FillColumnsPositions(m_ColumnsPositions, m_ColumnsNumber, m_ItemWidth);
        FillColumnsWidths(m_ColumnsWidths, m_ColumnsNumber, m_ItemWidth);
    }
}

bool FixedWidthLayoutEngine::ShouldRelayoutForNewBounds(const NSRect clip_view_bounds) const noexcept
{
    const auto height = clip_view_bounds.size.height;
    const auto projected_rows_number = NumberOfRowsForViewHeight(height, m_ItemHeight);
    return projected_rows_number != m_RowsNumber;
}

NSArray<NSCollectionViewLayoutAttributes *> *
FixedWidthLayoutEngine::AttributesForItemsInRect(NSRect _rect) const noexcept
{
    return LogarithmicSearchForItemsInRect(_rect);
}

} // namespace nc::panel::view::brief
