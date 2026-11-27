// Copyright (C) 2018-2021 Michael Kazakov. Subject to GNU General Public License version 3.
#include <VFSIcon/IconRepositoryImpl.h>
#include <VFSIcon/Log.h>
#include <Base/algo.h>
#include <Base/dispatch_cpp.h>

namespace nc::vfsicon {

static NSImage *BestFromLookupResult(const IconBuilder::LookupResult &_lr);

IconRepositoryImpl::IconRepositoryImpl(const std::shared_ptr<IconBuilder> &_icon_builder,
                                       std::unique_ptr<LimitedConcurrentQueue> _production_queue,
                                       const std::shared_ptr<Executor> &_client_executor,
                                       int _max_prod_queue_length,
                                       int _capacity)
    : m_Capacity(_capacity), m_MaxQueueLength(_max_prod_queue_length), m_IconBuilder(_icon_builder),
      m_ClientExecutor(_client_executor), m_ProductionQueue(std::move(_production_queue))
{
    static_assert(sizeof(Slot) == 40);
    if( _capacity < 0 || _capacity > std::numeric_limits<SlotKey>::max() ) {
        auto msg = "IconRepositoryImpl: invalid capacity";
        throw std::invalid_argument(msg);
    }
    if( _max_prod_queue_length < 0 ) {
        auto msg = "IconRepositoryImpl: invalid max production queue length";
        throw std::invalid_argument(msg);
    }
}

IconRepositoryImpl::~IconRepositoryImpl()
{
    {
        const std::lock_guard lock{m_InFlightLock};
        m_Alive->store(false);
        for( const auto &slot : m_Slots ) {
            if( slot.state == SlotState::Production && slot.production != nullptr ) {
                slot.production->must_stop = true;
                slot.production->ReleaseWait();
            }
        }
        // Also wake workers whose slots were already unregistered (e.g. after navigating away),
        // otherwise m_ProductionQueue.reset() could stall the main thread until the 20s timeout.
        for( const auto &ctx : m_InFlightContexts ) {
            ctx->must_stop = true;
            ctx->ReleaseWait();
        }
    }
    m_ProductionQueue.reset();
}

bool IconRepositoryImpl::IsValidSlot(SlotKey _key) const
{
    return _key != InvalidKey && ToIndex(_key) < static_cast<int>(m_Slots.size()) && IsSlotUsed(m_Slots[ToIndex(_key)]);
}

NSImage *IconRepositoryImpl::AvailableIconForSlot(SlotKey _key) const
{
    if( !IsValidSlot(_key) )
        return nil;

    const auto slot_index = ToIndex(_key);
    const auto &slot = m_Slots[slot_index];
    return slot.icon;
}

NSImage *IconRepositoryImpl::AvailableIconForListingItem(const VFSListingItem &_item) const
{
    return BestFromLookupResult(m_IconBuilder->LookupExistingIcon(_item, m_IconPxSize));
}

IconRepositoryImpl::SlotKey IconRepositoryImpl::Register(const VFSListingItem &_item)
{
    if( NumberOfUsedSlots() == m_Capacity )
        return InvalidKey;

    const auto new_slot_ind = AllocateSlot();
    if( new_slot_ind < 0 )
        return InvalidKey;

    auto &slot = m_Slots[new_slot_ind];
    slot.state = SlotState::Initial;
    slot.icon = BestFromLookupResult(m_IconBuilder->LookupExistingIcon(_item, m_IconPxSize));

    return FromIndex(new_slot_ind);
}

std::vector<IconRepositoryImpl::SlotKey> IconRepositoryImpl::AllSlots() const
{
    std::vector<SlotKey> slot_keys;
    slot_keys.reserve(NumberOfUsedSlots());
    for( size_t i = 0, e = m_Slots.size(); i != e; ++i )
        if( IsSlotUsed(m_Slots[i]) )
            slot_keys.emplace_back(FromIndex(static_cast<int>(i)));
    return slot_keys;
}

void IconRepositoryImpl::Unregister(SlotKey _key)
{
    if( !IsValidSlot(_key) )
        return;
    const auto index = ToIndex(_key);
    auto &slot = m_Slots[index];
    if( slot.production )
        slot.production->must_stop = true;
    m_FreeSlotsIndices.push(index);
    slot = Slot{};
}

void IconRepositoryImpl::ScheduleIconProduction(SlotKey _key, const VFSListingItem &_item)
{
    if( !IsValidSlot(_key) )
        return;

    const auto slot_index = ToIndex(_key);
    auto &slot = m_Slots[slot_index];

    if( slot.production != nullptr )
        return; // there is an already ongoing production for this slot

    if( slot.state == SlotState::Production && !HasFileChanged(slot, _item) )
        return; // nothing to do

    if( m_ProductionQueue->QueueLength() >= m_MaxQueueLength )
        return; // sorry, too busy atm

    const auto context = base::intrusive_ptr{new WorkerContext};
    context->item = _item;

    slot.production = context;
    slot.file_size = _item.Size();
    slot.file_mtime = _item.MTime();
    slot.file_mode = _item.UnixMode();
    slot.state = SlotState::Production;

    auto work_block = [this, alive = m_Alive, slot_index, context] {
        if( !alive->load() || context->must_stop )
            return;

        StartRealIconProduction(slot_index, context);
    };
    m_ProductionQueue->Execute(std::move(work_block));
}

void IconRepositoryImpl::StartRealIconProduction(int _slot_index, const base::intrusive_ptr<WorkerContext> &_context)
{
    // Keep the production queue's concurrency slot occupied until the async builder completes,
    // while allowing teardown to wake all in-flight waiters immediately so closing a panel never
    // blocks the main thread on slow or stalled QuickLook requests.
    const auto alive = m_Alive;
    const auto client_executor = m_ClientExecutor;
    {
        const std::lock_guard lock{m_InFlightLock};
        if( !alive->load() || _context->must_stop )
            return;
        m_InFlightContexts.emplace_back(_context);
    }
    const auto unregister_inflight = at_scope_end([this, _context] {
        const std::lock_guard lock{m_InFlightLock};
        std::erase(m_InFlightContexts, _context);
    });

    m_IconBuilder->BuildRealIconAsync(
        _context->item,
        m_IconPxSize,
        [this, alive, client_executor, _slot_index, _context](IconBuilder::BuildResult result) {
            if( alive->load() && !_context->must_stop ) {
                _context->result_filetype = result.filetype;
                _context->result_thumbnail = result.thumbnail;
                client_executor->Execute([this, alive, _slot_index, _context] {
                    if( !alive->load() || _context->must_stop )
                        return;
                    if( IsValidSlot(FromIndex(_slot_index)) )
                        CommitProductionResult(_slot_index, *_context);
                });
            }
            _context->ReleaseWait();
        },
        [alive, _context] { return !alive->load() || _context->must_stop.load(); });
    const auto wait_result =
        dispatch_semaphore_wait(_context->wait_semaphore, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC));
    if( wait_result != 0 && alive->load() && !_context->must_stop )
        Log::Error("Icon production timed out for '{}'", _context->item.Path());
}

void IconRepositoryImpl::CommitProductionResult(int _slot_index, WorkerContext &_ctx)
{
    if( _ctx.must_stop )
        return;

    auto &slot = m_Slots[_slot_index];
    // A timed-out or superseded callback may arrive after a newer production has taken the slot.
    if( slot.production.get() != &_ctx )
        return;

    slot.production.reset();
    const bool updated = RefreshImages(slot, _ctx);

    if( updated ) {
        const auto callback = m_IconUpdatedCallback;
        if( callback && *callback )
            (*callback)(FromIndex(_slot_index), slot.icon);
    }
}

void IconRepositoryImpl::SetUpdateCallback(std::function<void(SlotKey, NSImage *)> _on_icon_updated)
{
    using F = std::function<void(SlotKey, NSImage *)>;
    m_IconUpdatedCallback = std::make_shared<F>(std::move(_on_icon_updated));
}

void IconRepositoryImpl::SetPxSize(int _px_size)
{
    m_IconPxSize = _px_size;
}

int IconRepositoryImpl::NumberOfUsedSlots() const
{
    assert(m_FreeSlotsIndices.size() <= m_Slots.size());
    return static_cast<int>(m_Slots.size() - m_FreeSlotsIndices.size());
}

int IconRepositoryImpl::AllocateSlot()
{
    if( !m_FreeSlotsIndices.empty() ) {
        const auto free_slot_index = m_FreeSlotsIndices.top();
        m_FreeSlotsIndices.pop();
        return free_slot_index;
    }
    else if( static_cast<int>(m_Slots.size()) < m_Capacity ) {
        m_Slots.emplace_back();
        return static_cast<int>(m_Slots.size()) - 1;
    }
    else
        return -1;
}

bool IconRepositoryImpl::RefreshImages(Slot &_slot, const WorkerContext &_ctx)
{
    if( _ctx.result_thumbnail != nil ) {
        if( _ctx.result_thumbnail != _slot.icon ) {
            _slot.icon = _ctx.result_thumbnail;
            return true;
        }
    }

    if( _ctx.result_filetype != nil ) {
        if( _ctx.result_filetype != _slot.icon ) {
            _slot.icon = _ctx.result_filetype;
            return true;
        }
    }

    return false;
}

bool IconRepositoryImpl::IsSlotUsed(const Slot &_slot)
{
    return _slot.state != SlotState::Empty;
}

IconRepository::SlotKey IconRepositoryImpl::FromIndex(int _index)
{
    assert(_index < std::numeric_limits<SlotKey>::max());
    return SlotKey(_index + 1);
}

int IconRepositoryImpl::ToIndex(SlotKey _key)
{
    return _key - 1;
}

bool IconRepositoryImpl::HasFileChanged(const Slot &_slot, const VFSListingItem &_item)
{
    return _slot.file_size != _item.Size() || _slot.file_mtime != _item.MTime() || _slot.file_mode != _item.UnixMode();
}

static NSImage *BestFromLookupResult(const IconBuilder::LookupResult &_lr)
{
    if( _lr.thumbnail != nil )
        return _lr.thumbnail;
    if( _lr.filetype != nil )
        return _lr.filetype;
    return _lr.generic;
}

} // namespace nc::vfsicon
