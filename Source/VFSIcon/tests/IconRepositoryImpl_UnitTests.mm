// Copyright (C) 2018-2026 Michael Kazakov. Subject to GNU General Public License version 3.
#include <VFSIcon/IconRepositoryImpl.h>
#include <VFSIcon/QLThumbnailsCacheImpl.h>
#include <VFS/VFSListingInput.h>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <mutex>
#include "Tests.h"

using namespace nc::vfsicon;
using ::testing::_;
using ::testing::AnyNumber;
using ::testing::NiceMock;
using ::testing::Return;
using base = detail::IconRepositoryImplBase;

namespace {

struct IconBuilderMock : IconBuilder {
    MOCK_METHOD2(LookupExistingIcon, LookupResult(const VFSListingItem &, int));
    MOCK_METHOD3(BuildRealIcon, BuildResult(const VFSListingItem &, int, const CancelChecker &));

    void BuildRealIconAsync(const VFSListingItem &_item,
                            int _icon_px_size,
                            BuildCallback _callback,
                            const CancelChecker &_cancel_checker) override
    {
        _callback(BuildRealIcon(_item, _icon_px_size, _cancel_checker));
    }
};

struct ExecutorMock : base::Executor {
    MOCK_METHOD1(Execute, void(std::function<void()>));
};

struct LimitedConcurrentQueueMock : base::LimitedConcurrentQueue {
    MOCK_METHOD1(Execute, void(std::function<void()>));
    MOCK_CONST_METHOD0(QueueLength, int());
};

} // namespace

static VFSListingItem CookListingItem();
static VFSListingItem CookListingItem(uint64_t _size, time_t _mtime, mode_t _mode);
static IconBuilder::BuildResult CookSomeBuildResult();

TEST_CASE("IconRepositoryImpl allocates a valid slot")
{
    const auto icon_builder = std::make_shared<IconBuilderMock>();
    const auto executor = std::make_shared<ExecutorMock>();
    auto queue = std::make_unique<NiceMock<LimitedConcurrentQueueMock>>();
    EXPECT_CALL(*icon_builder, LookupExistingIcon);
    IconRepositoryImpl repository{icon_builder, std::move(queue), executor};

    const auto key = repository.Register(CookListingItem());

    CHECK(repository.IsValidSlot(key));
}

TEST_CASE("IconRepositoryImpl tracks its capacity")
{
    const auto icon_builder = std::make_shared<IconBuilderMock>();
    const auto executor = std::make_shared<ExecutorMock>();
    auto queue = std::make_unique<NiceMock<LimitedConcurrentQueueMock>>();
    EXPECT_CALL(*icon_builder, LookupExistingIcon);
    const auto some_big_max_length = 500;
    IconRepositoryImpl repository{icon_builder, std::move(queue), executor, some_big_max_length, 1};

    const auto item = CookListingItem();
    CHECK(repository.IsValidSlot(repository.Register(item)) == true);
    CHECK(repository.IsValidSlot(repository.Register(item)) == false);
}

TEST_CASE("IconRepositoryImpl does lookup for existing icon when registering")
{
    const auto icon_builder = std::make_shared<IconBuilderMock>();
    const auto executor = std::make_shared<ExecutorMock>();
    auto queue = std::make_unique<LimitedConcurrentQueueMock>();

    EXPECT_CALL(*icon_builder, LookupExistingIcon).Times(1);

    IconRepositoryImpl repository{icon_builder, std::move(queue), executor};

    repository.Register(CookListingItem());
}

TEST_CASE("IconRepositoryImpl returns lookup results got from IconBuilder")
{
    const auto icon_builder = std::make_shared<IconBuilderMock>();
    const auto executor = std::make_shared<ExecutorMock>();
    auto queue = std::make_unique<LimitedConcurrentQueueMock>();

    SECTION("only generic")
    {
        IconBuilder::LookupResult lr;
        lr.generic = [[NSImage alloc] init];
        EXPECT_CALL(*icon_builder, LookupExistingIcon).WillRepeatedly(Return(lr));
        IconRepositoryImpl repository{icon_builder, std::move(queue), executor};

        const auto key = repository.Register(CookListingItem());
        const auto image = repository.AvailableIconForSlot(key);

        CHECK(image == lr.generic);
    }
    SECTION("only filetype")
    {
        IconBuilder::LookupResult lr;
        lr.filetype = [[NSImage alloc] init];
        EXPECT_CALL(*icon_builder, LookupExistingIcon).WillRepeatedly(Return(lr));
        IconRepositoryImpl repository{icon_builder, std::move(queue), executor};

        const auto key = repository.Register(CookListingItem());
        const auto image = repository.AvailableIconForSlot(key);

        CHECK(image == lr.filetype);
    }
    SECTION("only thumbnail")
    {
        IconBuilder::LookupResult lr;
        lr.thumbnail = [[NSImage alloc] init];
        EXPECT_CALL(*icon_builder, LookupExistingIcon).WillRepeatedly(Return(lr));
        IconRepositoryImpl repository{icon_builder, std::move(queue), executor};

        const auto key = repository.Register(CookListingItem());
        const auto image = repository.AvailableIconForSlot(key);

        CHECK(image == lr.thumbnail);
    }
    SECTION("all three")
    {
        IconBuilder::LookupResult lr;
        lr.thumbnail = [[NSImage alloc] init];
        lr.filetype = [[NSImage alloc] init];
        lr.generic = [[NSImage alloc] init];
        EXPECT_CALL(*icon_builder, LookupExistingIcon).WillRepeatedly(Return(lr));
        IconRepositoryImpl repository{icon_builder, std::move(queue), executor};

        const auto key = repository.Register(CookListingItem());
        const auto image = repository.AvailableIconForSlot(key);

        CHECK(image == lr.thumbnail);
    }
}

TEST_CASE("IconRepositoryImpl returns a valid array of registered slot keys")
{
    const auto icon_builder = std::make_shared<IconBuilderMock>();
    const auto executor = std::make_shared<ExecutorMock>();
    auto queue = std::make_unique<LimitedConcurrentQueueMock>();
    EXPECT_CALL(*icon_builder, LookupExistingIcon).Times(2);
    IconRepositoryImpl repository{icon_builder, std::move(queue), executor};

    const auto item = CookListingItem();
    const auto key1 = repository.Register(item);
    const auto key2 = repository.Register(item);

    const auto all_keys = repository.AllSlots();
    REQUIRE(all_keys.size() == 2);
    CHECK(all_keys[0] == key1);
    CHECK(all_keys[1] == key2);
}

TEST_CASE("IconRepositoryImpl makes an unregistered key invalid")
{
    const auto icon_builder = std::make_shared<IconBuilderMock>();
    const auto executor = std::make_shared<ExecutorMock>();
    auto queue = std::make_unique<LimitedConcurrentQueueMock>();
    EXPECT_CALL(*icon_builder, LookupExistingIcon);
    IconRepositoryImpl repository{icon_builder, std::move(queue), executor};

    const auto key = repository.Register(CookListingItem());
    repository.Unregister(key);

    CHECK(repository.IsValidSlot(key) == false);
    CHECK(repository.AllSlots().empty());
}

TEST_CASE("IconRepositoryImpl reuses unregistered keys")
{
    const auto icon_builder = std::make_shared<IconBuilderMock>();
    const auto executor = std::make_shared<ExecutorMock>();
    auto queue = std::make_unique<LimitedConcurrentQueueMock>();
    EXPECT_CALL(*icon_builder, LookupExistingIcon).Times(AnyNumber());
    IconRepositoryImpl repository{icon_builder, std::move(queue), executor};

    const auto item = CookListingItem();
    SECTION("1,2,(2),2")
    {
        repository.Register(item);
        const auto key2 = repository.Register(item);
        repository.Unregister(key2);
        const auto key3 = repository.Register(item);
        CHECK(key3 == key2);
    }
    SECTION("1,2,(1),1")
    {
        const auto key1 = repository.Register(item);
        repository.Register(item);
        repository.Unregister(key1);
        const auto key3 = repository.Register(item);
        CHECK(key3 == key1);
    }
}

TEST_CASE("IconRepositoryImpl passes the right icon size to IconBuilder")
{
    const auto icon_builder = std::make_shared<IconBuilderMock>();
    const auto executor = std::make_shared<ExecutorMock>();
    auto queue = std::make_unique<LimitedConcurrentQueueMock>();
    const auto px_size = 96;
    EXPECT_CALL(*icon_builder, LookupExistingIcon(_, px_size));
    IconRepositoryImpl repository{icon_builder, std::move(queue), executor};
    repository.SetPxSize(px_size);
    repository.Register(CookListingItem());
}

TEST_CASE("IconRepositoryImpl uses a concurrent queue to produce real icons")
{
    const auto icon_builder = std::make_shared<IconBuilderMock>();
    const auto executor = std::make_shared<ExecutorMock>();
    auto queue = std::make_unique<NiceMock<LimitedConcurrentQueueMock>>();
    EXPECT_CALL(*icon_builder, LookupExistingIcon);
    EXPECT_CALL(*queue, Execute);
    IconRepositoryImpl repository{icon_builder, std::move(queue), executor};
    const auto item = CookListingItem();
    const auto key = repository.Register(item);
    repository.ScheduleIconProduction(key, item);
}

TEST_CASE("IconRepositoryImpl uses updated results from IconBuilder")
{
    const auto icon_builder = std::make_shared<IconBuilderMock>();
    const auto executor = std::make_shared<ExecutorMock>();
    auto queue = std::make_unique<NiceMock<LimitedConcurrentQueueMock>>();
    EXPECT_CALL(*queue, Execute).WillRepeatedly([](const std::function<void()> &f) { f(); });
    EXPECT_CALL(*executor, Execute).WillRepeatedly([](const std::function<void()> &f) { f(); });
    EXPECT_CALL(*icon_builder, LookupExistingIcon);

    SECTION("Thumbnail passage")
    {
        IconBuilder::BuildResult br;
        br.thumbnail = [[NSImage alloc] init];
        EXPECT_CALL(*icon_builder, BuildRealIcon).WillRepeatedly(Return(br));

        IconRepositoryImpl repository{icon_builder, std::move(queue), executor};
        const auto item = CookListingItem();
        const auto key = repository.Register(item);
        repository.ScheduleIconProduction(key, item);

        const auto img = repository.AvailableIconForSlot(key);
        CHECK(img == br.thumbnail);
    }
    SECTION("Filetype passage")
    {
        IconBuilder::BuildResult br;
        br.filetype = [[NSImage alloc] init];
        EXPECT_CALL(*icon_builder, BuildRealIcon).WillRepeatedly(Return(br));

        IconRepositoryImpl repository{icon_builder, std::move(queue), executor};
        const auto item = CookListingItem();
        const auto key = repository.Register(item);
        repository.ScheduleIconProduction(key, item);

        const auto img = repository.AvailableIconForSlot(key);
        CHECK(img == br.filetype);
    }
}

TEST_CASE("IconRepositoryImpl doesn't call IconBuilder concurrently for a single item")
{
    const auto icon_builder = std::make_shared<IconBuilderMock>();
    const auto executor = std::make_shared<ExecutorMock>();
    auto queue = std::make_unique<NiceMock<LimitedConcurrentQueueMock>>();
    EXPECT_CALL(*queue, Execute).WillRepeatedly([](const std::function<void()> &f) { f(); });
    EXPECT_CALL(*executor, Execute).WillRepeatedly([](const std::function<void()> &) { /* no-op */ });
    EXPECT_CALL(*icon_builder, LookupExistingIcon);

    const auto br = CookSomeBuildResult();
    EXPECT_CALL(*icon_builder, BuildRealIcon).Times(1).WillRepeatedly(Return(br));

    IconRepositoryImpl repository{icon_builder, std::move(queue), executor};
    const auto item = CookListingItem();
    const auto key = repository.Register(item);
    repository.ScheduleIconProduction(key, item);
    repository.ScheduleIconProduction(key, item);
}

TEST_CASE("IconRepositoryImpl doesn't call IconBuilder again if entry didn't change")
{
    const auto icon_builder = std::make_shared<IconBuilderMock>();
    const auto executor = std::make_shared<ExecutorMock>();
    auto queue = std::make_unique<NiceMock<LimitedConcurrentQueueMock>>();
    EXPECT_CALL(*queue, Execute).WillRepeatedly([](const std::function<void()> &f) { f(); });
    EXPECT_CALL(*executor, Execute).WillRepeatedly([](const std::function<void()> &f) { f(); });
    EXPECT_CALL(*icon_builder, LookupExistingIcon);

    const auto br = CookSomeBuildResult();
    EXPECT_CALL(*icon_builder, BuildRealIcon).Times(1).WillRepeatedly(Return(br));

    IconRepositoryImpl repository{icon_builder, std::move(queue), executor};
    const auto item = CookListingItem();
    const auto key = repository.Register(item);
    repository.ScheduleIconProduction(key, item);
    repository.ScheduleIconProduction(key, item);
}

TEST_CASE("IconRepositoryImpl call IconBuilder again if entry did change")
{
    const auto icon_builder = std::make_shared<IconBuilderMock>();
    const auto executor = std::make_shared<ExecutorMock>();
    auto queue = std::make_unique<NiceMock<LimitedConcurrentQueueMock>>();
    EXPECT_CALL(*queue, Execute).WillRepeatedly([](const std::function<void()> &f) { f(); });
    EXPECT_CALL(*executor, Execute).WillRepeatedly([](const std::function<void()> &f) { f(); });
    EXPECT_CALL(*icon_builder, LookupExistingIcon);

    const auto br = CookSomeBuildResult();
    EXPECT_CALL(*icon_builder, BuildRealIcon).Times(2).WillRepeatedly(Return(br));

    IconRepositoryImpl repository{icon_builder, std::move(queue), executor};
    const auto item1 = CookListingItem(1234, 4567, 2467);
    const auto key = repository.Register(item1);
    repository.ScheduleIconProduction(key, item1);
    SECTION("Changed size")
    {
        const auto item2 = CookListingItem(3456, 4567, 2467);
        repository.ScheduleIconProduction(key, item2);
    }
    SECTION("Changed mtime")
    {
        const auto item2 = CookListingItem(1234, 3244, 2467);
        repository.ScheduleIconProduction(key, item2);
    }
    SECTION("Changed mode")
    {
        const auto item2 = CookListingItem(1234, 3244, 453);
        repository.ScheduleIconProduction(key, item2);
    }
}

TEST_CASE("IconRepositoryImpl calls a callback when icon changes")
{
    const auto icon_builder = std::make_shared<IconBuilderMock>();
    const auto executor = std::make_shared<ExecutorMock>();
    auto queue = std::make_unique<NiceMock<LimitedConcurrentQueueMock>>();
    EXPECT_CALL(*queue, Execute).WillRepeatedly([](const std::function<void()> &f) { f(); });
    EXPECT_CALL(*executor, Execute).WillRepeatedly([](const std::function<void()> &f) { f(); });
    EXPECT_CALL(*icon_builder, LookupExistingIcon);

    const auto br = CookSomeBuildResult();
    EXPECT_CALL(*icon_builder, BuildRealIcon).Times(1).WillRepeatedly(Return(br));

    IconRepositoryImpl repository{icon_builder, std::move(queue), executor};
    const auto item = CookListingItem();
    const auto key = repository.Register(item);
    bool called = false;
    const auto callback = [&called, key, br](IconRepository::SlotKey _key, NSImage *_img) -> void {
        called = true;
        CHECK(_key == key);
        CHECK(_img == br.thumbnail);
    };
    repository.SetUpdateCallback(callback);
    repository.ScheduleIconProduction(key, item);
    CHECK(called == true);
}

TEST_CASE("IconRepositoryImpl doesn't call a callback when icon is the same")
{
    const auto icon_builder = std::make_shared<IconBuilderMock>();
    const auto executor = std::make_shared<ExecutorMock>();
    auto queue = std::make_unique<NiceMock<LimitedConcurrentQueueMock>>();
    EXPECT_CALL(*queue, Execute).WillRepeatedly([](const std::function<void()> &f) { f(); });
    EXPECT_CALL(*executor, Execute).WillRepeatedly([](const std::function<void()> &f) { f(); });
    const auto img = [[NSImage alloc] init];
    IconBuilder::LookupResult lr;
    lr.thumbnail = img;
    EXPECT_CALL(*icon_builder, LookupExistingIcon).WillRepeatedly(Return(lr));

    IconBuilder::BuildResult br;
    br.thumbnail = img;
    EXPECT_CALL(*icon_builder, BuildRealIcon).WillRepeatedly(Return(br));

    IconRepositoryImpl repository{icon_builder, std::move(queue), executor};
    const auto item = CookListingItem();
    const auto key = repository.Register(item);
    bool called = false;
    const auto callback = [&called](IconRepository::SlotKey, NSImage *) -> void { called = true; };
    repository.SetUpdateCallback(callback);
    repository.ScheduleIconProduction(key, item);
    CHECK(called == false);
}

TEST_CASE("IconRepositoryImpl doesn't call IconBuilder concurrently when prod queue is too long")
{
    const auto icon_builder = std::make_shared<IconBuilderMock>();
    const auto executor = std::make_shared<ExecutorMock>();
    auto queue = std::make_unique<NiceMock<LimitedConcurrentQueueMock>>();
    EXPECT_CALL(*queue, Execute).Times(1);
    EXPECT_CALL(*queue, QueueLength).WillOnce(Return(0)).WillOnce(Return(1));
    EXPECT_CALL(*icon_builder, LookupExistingIcon).Times(2);

    IconRepositoryImpl repository{icon_builder, std::move(queue), executor, 1};
    const auto item = CookListingItem();
    const auto key1 = repository.Register(item);
    const auto key2 = repository.Register(item);
    repository.ScheduleIconProduction(key1, item);
    repository.ScheduleIconProduction(key2, item);
}

TEST_CASE("IconRepositoryImpl teardown does not hang on stalled async builder and ignores late callbacks")
{
    struct StalledIconBuilder final : IconBuilder {
        LookupResult LookupExistingIcon(const VFSListingItem & /*_item*/, int /*_icon_px_size*/) override { return {}; }
        void BuildRealIconAsync(const VFSListingItem & /*_item*/,
                                int /*_icon_px_size*/,
                                BuildCallback _callback,
                                const CancelChecker & /*_cancel_checker*/) override
        {
            const std::lock_guard lock{mutex};
            captured_callbacks.emplace_back(std::move(_callback));
            cv.notify_all();
        }
        std::mutex mutex;
        std::condition_variable cv;
        std::vector<BuildCallback> captured_callbacks;
    };

    const auto icon_builder = std::make_shared<StalledIconBuilder>();
    const auto executor = std::make_shared<ExecutorMock>();
    std::vector<std::function<void()>> queued_ui_blocks;
    EXPECT_CALL(*executor, Execute).WillRepeatedly([&](std::function<void()> f) {
        queued_ui_blocks.emplace_back(std::move(f));
    });

    bool updated = false;
    const auto begin = [&] {
        auto queue = std::make_unique<base::GCDLimitedConcurrentQueue>(2);
        IconRepositoryImpl repository{icon_builder, std::move(queue), executor};
        repository.SetUpdateCallback([&](IconRepository::SlotKey, NSImage *) { updated = true; });

        const auto item1 = CookListingItem(1, 2, 3);
        const auto item2 = CookListingItem(4, 5, 6);
        const auto key1 = repository.Register(item1);
        const auto key2 = repository.Register(item2);
        repository.ScheduleIconProduction(key1, item1);
        repository.ScheduleIconProduction(key2, item2);

        {
            std::unique_lock lock{icon_builder->mutex};
            REQUIRE(icon_builder->cv.wait_for(
                lock, std::chrono::seconds{5}, [&] { return icon_builder->captured_callbacks.size() == 2; }));
        }

        // Unregister one slot before destroying to ensure already-unregistered in-flight workers
        // are woken up as well.
        repository.Unregister(key2);

        return std::chrono::steady_clock::now();
    }();
    const auto elapsed = std::chrono::steady_clock::now() - begin;
    CHECK(elapsed < std::chrono::seconds{2});

    // Late callbacks arriving after repository destruction must be ignored safely.
    const auto result = CookSomeBuildResult();
    for( auto &cb : icon_builder->captured_callbacks )
        cb(result);
    for( auto &block : queued_ui_blocks )
        block();
    CHECK_FALSE(updated);
}

TEST_CASE("QLThumbnailsCacheImpl stores and validates externally decoded thumbnails")
{
    QLThumbnailsCacheImpl cache;
    const std::string path = "/tmp/nonexistent-direct-image.png";
    const QLThumbnailsCache::FileStateHint hint1{.size = 1024, .mtime = 1700000000};
    const QLThumbnailsCache::FileStateHint hint2{.size = 2048, .mtime = 1700000001};
    NSImage *const img1 = [[NSImage alloc] initWithSize:NSMakeSize(64, 48)];
    NSImage *const img2 = [[NSImage alloc] initWithSize:NSMakeSize(64, 36)];

    CHECK(cache.ThumbnailIfHas(path, 64) == nil);
    CHECK(cache.ThumbnailIfFresh(path, 64, hint1) == nil);

    cache.StoreThumbnail(path, 64, hint1, img1);
    CHECK(cache.ThumbnailIfHas(path, 64) == img1);
    CHECK(cache.ThumbnailIfFresh(path, 64, hint1) == img1);
    CHECK(cache.ThumbnailIfFresh(path, 64, hint2) == nil);
    CHECK(cache.ThumbnailIfHas(path, 32) == nil);

    cache.StoreThumbnail(path, 64, hint2, img2);
    CHECK(cache.ThumbnailIfHas(path, 64) == img2);
    CHECK(cache.ThumbnailIfFresh(path, 64, hint2) == img2);
    CHECK(cache.ThumbnailIfFresh(path, 64, hint1) == nil);
}

static IconBuilder::BuildResult CookSomeBuildResult()
{
    IconBuilder::BuildResult br;
    br.thumbnail = [[NSImage alloc] init];
    br.filetype = [[NSImage alloc] init];
    return br;
}

static VFSListingItem CookListingItem()
{
    return CookListingItem(1234, 4567, 2467);
}

static VFSListingItem CookListingItem(uint64_t _size, time_t _mtime, mode_t _mode)
{
    nc::vfs::ListingInput l;
    l.directories[0] = "/DOESN'T MATTER/";
    l.hosts[0] = VFSHost::DummyHost();
    l.filenames.emplace_back("SOME FILENAME");
    l.unix_modes.emplace_back(_mode);
    l.unix_types.emplace_back(0);
    l.sizes.insert(0, _size);
    l.mtimes.insert(0, _mtime);

    const auto listing = VFSListing::Build(std::move(l));
    return listing->Item(0);
}
