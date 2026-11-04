// Copyright (C) 2026 The Nimble Commander-Fork Authors. Subject to GNU General Public License version 3.
#include "ToggleFlatView.h"
#include "../PanelController.h"
#include "../PanelController+DataAccess.h"

namespace nc::panel::actions {

bool ToggleFlatView::Predicate(PanelController *_target) const
{
    // Entering the flat view only makes sense for a real directory listing, leaving it always does.
    return _target.isFlatView || (_target.isUniform && _target.vfs != nullptr);
}

bool ToggleFlatView::ValidateMenuItem(PanelController *_target, NSMenuItem *_item) const
{
    _item.state = _target.isFlatView ? NSControlStateValueOn : NSControlStateValueOff;
    return Predicate(_target);
}

void ToggleFlatView::Perform(PanelController *_target, id /*_sender*/) const
{
    [_target toggleFlatView];
}

} // namespace nc::panel::actions
