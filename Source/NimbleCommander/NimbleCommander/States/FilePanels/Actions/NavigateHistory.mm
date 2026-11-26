// Copyright (C) 2017-2019 Michael Kazakov. Subject to GNU General Public License version 3.
#include "NavigateHistory.h"
#include "../PanelController.h"
#include "../PanelHistory.h"
#include <NimbleCommander/Core/VFSInstanceManager.h>
#include <Base/dispatch_cpp.h>

namespace nc::panel::actions {

bool GoBack::Predicate(PanelController *_target) const
{
    return _target.history.CanMoveBack();
}

void GoBack::Perform(PanelController *_target, id /*_sender*/) const
{
    auto &history = _target.history;
    if( !history.CanMoveBack() )
        return;
    history.MoveBack();

    if( auto listing_promise = history.CurrentPlaying() )
        nc::panel::ListingPromiseLoader::Load(*listing_promise, _target);
}

bool GoForward::Predicate(PanelController *_target) const
{
    return _target.history.CanMoveForth();
}

void GoForward::Perform(PanelController *_target, id /*_sender*/) const
{
    auto &history = _target.history;
    if( !history.CanMoveForth() )
        return;
    history.MoveForth();

    if( auto listing_promise = history.CurrentPlaying() )
        nc::panel::ListingPromiseLoader::Load(*listing_promise, _target);
}

} // namespace nc::panel::actions

namespace nc::panel {

void ListingPromiseLoader::Load(const ListingPromise &_promise, PanelController *_panel)
{
    auto task = [=](const std::function<bool()> &_cancelled) {
        const uint64_t epoch = _panel.navigationEpoch;
        const auto vfs_adapter = [&](const core::VFSInstancePromise &_promise) {
            return _panel.vfsInstanceManager.RetrieveVFS(_promise, _cancelled);
        };

        try {
            const auto listing = _promise.Restore(_panel.vfsFetchingFlags, vfs_adapter, _cancelled);
            if( listing )
                dispatch_to_main_queue([=] {
                    // A newer Back/Forward or GoTo may have completed while this restore was
                    // running; never install an older listing over the newer view.
                    if( _panel.navigationEpoch == epoch )
                        [_panel loadListing:listing];
                });
        } catch( ... ) {
            //...
        }
    };
    [_panel commitCancelableLoadingTask:std::move(task)];
}

} // namespace nc::panel
