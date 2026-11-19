// Copyright (C) 2026 cfanmaoli. Subject to GNU General Public License version 3.
#include <catch2/catch_test_macros.hpp>
#include "Tests.h"
#include "../Core/UpstreamSettingsImport.h"

#include <fstream>
#include <iterator>
#include <string>
#include <string_view>

namespace {

namespace fs = std::filesystem;

void WriteFile(const fs::path &_path, std::string_view _content)
{
    fs::create_directories(_path.parent_path());
    std::ofstream out(_path, std::ios::binary | std::ios::trunc);
    out.write(_content.data(), static_cast<std::streamsize>(_content.size()));
}

std::string ReadFile(const fs::path &_path)
{
    std::ifstream in(_path, std::ios::binary);
    std::string result;
    result.assign(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
    return result;
}

std::size_t CountBackups(const fs::path &_directory)
{
    std::size_t count = 0;
    for( const auto &entry : fs::directory_iterator(_directory) )
        if( entry.path().filename().string().contains(".pre-upstream-import-") )
            ++count;
    return count;
}

fs::path OriginalSupportDirectory(const fs::path &_home)
{
    return _home / "Library/Application Support/Nimble Commander";
}

} // namespace

TEST_CASE("Upstream import discovers the original app's support directory")
{
    TempTestDir temp;
    const fs::path home = temp.directory / "home";
    const fs::path fork = temp.directory / "fork";
    const fs::path original = OriginalSupportDirectory(home);
    WriteFile(original / "Config/Config.json", R"({"general":{"theme":"old"}})");
    WriteFile(original / "State/State.json", R"({"filePanel":{"left":1}})");

    const auto plan = nc::upstream::DiscoverIn(home, fork);
    REQUIRE(plan.has_value());
    CHECK(plan->source_root == original);
    CHECK(plan->relative_paths.size() >= 2);
}

TEST_CASE("Upstream import stages and applies settings with backups")
{
    TempTestDir temp;
    const fs::path home = temp.directory / "home";
    const fs::path fork = temp.directory / "fork";
    const fs::path original = OriginalSupportDirectory(home);
    WriteFile(original / "Config/Config.json", R"({"general":{"theme":"old"}})");
    WriteFile(original / "State/State.json", R"({"filePanel":{"left":1}})");
    WriteFile(original / "LanguagePacks/chinese.json", R"({"format":"nimble-commander-language-pack"})");
    WriteFile(fork / "Config/Config.json", R"({"general":{"theme":"new"}})");

    const auto plan = nc::upstream::DiscoverIn(home, fork);
    REQUIRE(plan.has_value());

    std::string error;
    REQUIRE(nc::upstream::StagePendingImport(*plan, fork, error));
    CHECK(error.empty());
    CHECK(nc::upstream::HasPendingImport(fork));

    REQUIRE(nc::upstream::ApplyPendingImport(fork, error));
    CHECK(error.empty());
    CHECK_FALSE(nc::upstream::HasPendingImport(fork));
    CHECK(ReadFile(fork / "Config/Config.json") == R"({"general":{"theme":"old"}})");
    CHECK(ReadFile(fork / "State/State.json") == R"({"filePanel":{"left":1}})");
    CHECK(ReadFile(fork / "LanguagePacks/chinese.json") == R"({"format":"nimble-commander-language-pack"})");
    CHECK(CountBackups(fork / "Config") == 1);
}

TEST_CASE("Upstream import rejects malformed settings files")
{
    TempTestDir temp;
    const fs::path home = temp.directory / "home";
    const fs::path fork = temp.directory / "fork";
    const fs::path original = OriginalSupportDirectory(home);
    WriteFile(original / "Config/Config.json", "{not json");
    WriteFile(original / "State/State.json", "{}");

    const auto plan = nc::upstream::DiscoverIn(home, fork);
    REQUIRE(plan.has_value());
    std::string error;
    CHECK_FALSE(nc::upstream::StagePendingImport(*plan, fork, error));
    CHECK_FALSE(error.empty());
    CHECK_FALSE(nc::upstream::HasPendingImport(fork));
}
