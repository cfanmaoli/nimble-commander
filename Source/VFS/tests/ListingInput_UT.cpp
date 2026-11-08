// Copyright (C) 2020-2025 Michael Kazakov. Subject to GNU General Public License version 3.
#include "Tests.h"
#include "TestEnv.h"
#include <VFSListingInput.h>
#include <Native.h>
#include <VFSDeclarations.h>
#include <Base/mach_time.h>
#include <Base/variable_container.h>
#include <dirent.h>
#include <thread>

#define PREFIX "nc::vfs::ListingInput "

namespace {

using namespace nc;
using namespace nc::vfs;
using nc::base::variable_container;

TEST_CASE(PREFIX "Title is preserved after building")
{
    ListingInput input;
    input.title = "Test";
    input.hosts.insert(0, TestEnv().vfs_native);
    input.directories.insert(0, "/");
    auto listing = Listing::Build(std::move(input));
    REQUIRE(listing);
    CHECK(listing->Title() == "Test");
}

TEST_CASE(PREFIX "Title is preserved after updating")
{
    ListingInput input;
    input.title = "Test";
    input.hosts.insert(0, TestEnv().vfs_native);
    input.directories.insert(0, "/");
    auto orig_listing = Listing::Build(std::move(input));
    REQUIRE(orig_listing);
    auto updated_listing = Listing::ProduceUpdatedTemporaryPanelListing(*orig_listing, {});
    REQUIRE(updated_listing);
    CHECK(updated_listing->Title() == "Test");
}

TEST_CASE(PREFIX "Prodives a correct ticks timestamp")
{
    ListingInput input;
    input.hosts.insert(0, TestEnv().vfs_native);
    input.directories.insert(0, "/");
    const auto old_ts = nc::base::machtime();
    std::this_thread::sleep_for(std::chrono::microseconds(1));
    const auto listing = Listing::Build(std::move(input));
    std::this_thread::sleep_for(std::chrono::microseconds(1));
    const auto new_ts = nc::base::machtime();
    CHECK(listing->BuildTicksTimestamp() >= old_ts);
    CHECK(listing->BuildTicksTimestamp() <= new_ts);
}

TEST_CASE(PREFIX "ProducePatchedListing preserves the surviving entries")
{
    const auto build = [](const std::vector<std::string> &_names, bool _with_times) {
        ListingInput input;
        input.hosts.insert(0, TestEnv().vfs_native);
        input.directories.insert(0, "/dir/");
        if( _with_times ) {
            input.sizes.reset(variable_container<>::type::dense);
            input.inodes.reset(variable_container<>::type::dense);
            input.mtimes.reset(variable_container<>::type::dense);
        }
        for( size_t i = 0; i != _names.size(); ++i ) {
            input.filenames.emplace_back(_names[i]);
            input.unix_modes.emplace_back(S_IFREG | 0644);
            input.unix_types.emplace_back(DT_REG);
            if( _with_times ) {
                input.sizes.insert(i, 100 + i);
                input.inodes.insert(i, 1000 + i);
                input.mtimes.insert(i, 1'700'000'000 + static_cast<time_t>(i));
            }
        }
        return Listing::Build(std::move(input));
    };

    const auto base = build({"a", "b", "c"}, true);
    REQUIRE(base);
    REQUIRE(base->Count() == 3);

    const auto appended = build({"d"}, true);
    REQUIRE(appended);

    const std::vector<unsigned> removed = {1}; // drop "b"
    const auto patched = Listing::ProducePatchedListing(*base, removed, {appended});
    REQUIRE(patched);
    REQUIRE(patched->Count() == 3);
    CHECK(patched->Filename(0) == "a");
    CHECK(patched->Filename(1) == "c");
    CHECK(patched->Filename(2) == "d");
    CHECK(patched->Size(0) == 100);
    CHECK(patched->Size(1) == 102);
    CHECK(patched->HasMTime(1));
    CHECK(patched->MTime(1) == 1'700'000'002);
    CHECK(patched->Directory(0) == "/dir/");
    CHECK(patched->IsReg(0));
}

TEST_CASE(PREFIX "ProducePatchedListing bails out on the listings with extras")
{
    ListingInput input;
    input.hosts.insert(0, TestEnv().vfs_native);
    input.directories.insert(0, "/dir/");
    input.filenames.emplace_back("a");
    input.unix_modes.emplace_back(S_IFREG | 0644);
    input.unix_types.emplace_back(DT_REG);
    input.display_filenames.insert(0, "display");
    const auto base = Listing::Build(std::move(input));
    REQUIRE(base);

    const auto patched = Listing::ProducePatchedListing(*base, {}, {});
    CHECK(!patched);
}

} // namespace

#undef PREFIX
