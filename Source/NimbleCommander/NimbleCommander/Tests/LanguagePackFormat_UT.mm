// Copyright (C) 2026 cfanmaoli. Subject to GNU General Public License version 3.
#include <catch2/catch_test_macros.hpp>
#include "../Core/LanguagePackFormat.h"

TEST_CASE("LanguagePack format validation preserves argument types")
{
    using nc::lang::detail::PlaceholdersCompatible;
    const struct {
        NSString *source;
        NSString *translation;
        bool compatible;
    } cases[] = {
        {.source = @"Unable to run the external tool \"%s\"",
         .translation = @"Unable to run the external tool \"%S\"",
         .compatible = false},
        {.source = @"%s", .translation = @"%ls", .compatible = false},
        {.source = @"%S", .translation = @"%s", .compatible = false},
        {.source = @"Layout #%ld", .translation = @"Layout #%d", .compatible = false},
        {.source = @"%lld", .translation = @"%ld", .compatible = false},
        {.source = @"%lu", .translation = @"%u", .compatible = false},
        {.source = @"%d", .translation = @"%u", .compatible = false},
        {.source = @"%hhd", .translation = @"%d", .compatible = false},
        {.source = @"%f", .translation = @"%Lf", .compatible = false},
        {.source = @"Temporary Panel (%@)", .translation = @"Temporary Panel (%n)", .compatible = false},
        {.source = @"Temporary Panel (%@)", .translation = @"Temporary Panel (%2$@)", .compatible = false},
        {.source = @"%@ %ld", .translation = @"%1$@ %d", .compatible = false},
        {.source = @"Progress 100%", .translation = @"%n", .compatible = false},
        {.source = @"%s", .translation = @"[%s]", .compatible = true},
        {.source = @"%S", .translation = @"[%S]", .compatible = true},
        {.source = @"%ls", .translation = @"[%ls]", .compatible = true},
        {.source = @"%d", .translation = @"%i", .compatible = true},
        {.source = @"%lld", .translation = @"%qd", .compatible = true},
        {.source = @"%lu", .translation = @"%lx", .compatible = true},
        {.source = @"%@ %ld", .translation = @"%2$ld %1$@", .compatible = true},
        {.source = @"%@", .translation = @"%1$@ %1$@", .compatible = true},
        {.source = @"%f", .translation = @"%lf", .compatible = true},
        {.source = @"Progress 100%%", .translation = @"100%% complete", .compatible = true},
    };
    for( const auto &tc : cases ) {
        INFO(tc.source.UTF8String);
        INFO(tc.translation.UTF8String);
        CHECK(PlaceholdersCompatible(tc.source, tc.source, tc.translation) == tc.compatible);
    }
}
