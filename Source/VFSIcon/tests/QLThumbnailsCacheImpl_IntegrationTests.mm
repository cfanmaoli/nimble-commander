// Copyright (C) 2018-2026 Michael Kazakov. Subject to GNU General Public License version 3.
#include "Tests.h"
#include <VFSIcon/QLThumbnailsCacheImpl.h>
#include <Base/algo.h>
#include <Base/dispatch_cpp.h>
#include <ImageIO/ImageIO.h>
#include <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <atomic>
#include <filesystem>
#include <mutex>
#include <string>
#include <unistd.h>
#include <vector>

using namespace nc::vfsicon;

namespace {

bool WriteTestPNG(const std::filesystem::path &_path, size_t _width, size_t _height, uint8_t _seed)
{
    std::vector<uint8_t> pixels(_width * _height * 4);
    for( size_t y = 0; y != _height; ++y ) {
        for( size_t x = 0; x != _width; ++x ) {
            const size_t idx = ((y * _width) + x) * 4;
            pixels[idx + 0] = static_cast<uint8_t>((x + _seed) & 0xFF);
            pixels[idx + 1] = static_cast<uint8_t>((y + (static_cast<size_t>(_seed) * 3)) & 0xFF);
            pixels[idx + 2] = static_cast<uint8_t>((static_cast<size_t>(_seed) * 17) & 0xFF);
            pixels[idx + 3] = 255;
        }
    }

    const CGColorSpaceRef color_space = CGColorSpaceCreateDeviceRGB();
    if( color_space == nullptr )
        return false;
    const auto release_cs = at_scope_end([&] { CGColorSpaceRelease(color_space); });

    const CGContextRef ctx = CGBitmapContextCreate(
        pixels.data(), _width, _height, 8, _width * 4, color_space, kCGImageAlphaPremultipliedLast);
    if( ctx == nullptr )
        return false;
    const auto release_ctx = at_scope_end([&] { CGContextRelease(ctx); });

    const CGImageRef cg_image = CGBitmapContextCreateImage(ctx);
    if( cg_image == nullptr )
        return false;
    const auto release_img = at_scope_end([&] { CGImageRelease(cg_image); });

    NSString *const ns_path = [NSString stringWithUTF8String:_path.c_str()];
    NSURL *const url = [NSURL fileURLWithPath:ns_path];
    const CGImageDestinationRef dest =
        CGImageDestinationCreateWithURL((__bridge CFURLRef)url, (__bridge CFStringRef)UTTypePNG.identifier, 1, nullptr);
    if( dest == nullptr )
        return false;
    const auto release_dest = at_scope_end([&] { CFRelease(dest); });

    CGImageDestinationAddImage(dest, cg_image, nullptr);
    return CGImageDestinationFinalize(dest);
}

} // namespace

TEST_CASE("QLThumbnailsCacheImpl doesn't crash under a concurrent load")
{
    const std::filesystem::path temp_dir =
        std::filesystem::temp_directory_path() / ("nc_ql_thumbnails_it_" + std::to_string(getpid()));
    std::error_code ec;
    std::filesystem::remove_all(temp_dir, ec);
    REQUIRE(std::filesystem::create_directories(temp_dir));
    const auto cleanup = at_scope_end([&] {
        std::error_code rm_ec;
        std::filesystem::remove_all(temp_dir, rm_ec);
    });

    constexpr std::pair<size_t, size_t> dims[] = {
        {128, 128},
        {160, 120},
        {192, 108},
    };
    constexpr size_t image_count = 24;
    std::vector<std::string> paths;
    paths.reserve(image_count);
    for( size_t i = 0; i != image_count; ++i ) {
        const auto [w, h] = dims[i % std::size(dims)];
        const auto file_path = temp_dir / ("fixture_" + std::to_string(i) + ".png");
        REQUIRE(WriteTestPNG(file_path, w, h, static_cast<uint8_t>(i + 1)));
        paths.emplace_back(file_path.native());
    }

    QLThumbnailsCacheImpl cache{};
    constexpr int runs = 4;
    const auto queue = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    auto m = std::mutex{};
    std::atomic_size_t produced_count{0};
    for( int i = 0; i < runs; ++i ) {
        dispatch_apply(paths.size(), queue, [&](size_t index) {
            constexpr int px_size = 32;
            const auto &path = paths[index];
            cache.ThumbnailIfHas(path, px_size);
            const dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
            NSImage *image = nil;
            cache.ProduceThumbnailAsync(path, px_size, std::nullopt, [&](NSImage *result) {
                image = result;
                dispatch_semaphore_signal(semaphore);
            });
            dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
            if( image != nil ) {
                produced_count.fetch_add(1);
                const auto lock = std::lock_guard{m};
                CHECK(static_cast<int>(image.size.width) == px_size);
                CHECK(static_cast<int>(image.size.height) == px_size);
            }
        });
    }
    CHECK(produced_count.load() > 0);
}
