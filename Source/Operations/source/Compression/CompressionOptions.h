// Copyright (C) 2026 Michael Kazakov. Subject to GNU General Public License version 3.
#pragma once

#include <algorithm>
#include <cstdint>
#include <optional>
#include <string_view>

namespace nc::ops {

enum class CompressionFormat : uint8_t {
    zip,
    sevenzip,
    tar,
};

enum class CompressionMethod : uint8_t {
    store,
    deflate,
    bzip2,
    lzma,
    zstd,
    none,
    gzip,
    xz,
};

struct CompressionOptions {
    CompressionFormat format = CompressionFormat::zip;
    CompressionMethod method = CompressionMethod::deflate;
    int level = 6; // 1..9
};

namespace compression_detail {

[[nodiscard]] constexpr std::optional<CompressionMethod> ParseMethod(std::string_view _method) noexcept
{
    if( _method == "store" )
        return CompressionMethod::store;
    if( _method == "deflate" )
        return CompressionMethod::deflate;
    if( _method == "bzip2" )
        return CompressionMethod::bzip2;
    if( _method == "lzma" )
        return CompressionMethod::lzma;
    if( _method == "zstd" )
        return CompressionMethod::zstd;
    if( _method == "none" )
        return CompressionMethod::none;
    if( _method == "gzip" )
        return CompressionMethod::gzip;
    if( _method == "xz" )
        return CompressionMethod::xz;
    return std::nullopt;
}

} // namespace compression_detail

// Turns the values stored in the "compression.format"/"compression.method" config entries into the
// options the operation understands. Every unsupported combination is resolved into a sane one
// instead of failing: an unknown format or an unknown method becomes zip + deflate, while a method
// that has a direct equivalent in the requested container is mapped onto it.
[[nodiscard]] inline CompressionOptions
ResolveCompressionOptions(std::string_view _format, std::string_view _method, int _level) noexcept
{
    CompressionOptions options;
    options.level = std::clamp(_level, 1, 9);

    const auto fallback = [level = options.level]() noexcept {
        CompressionOptions result;
        result.format = CompressionFormat::zip;
        result.method = CompressionMethod::deflate;
        result.level = level;
        return result;
    };

    const std::optional<CompressionMethod> method = compression_detail::ParseMethod(_method);
    if( !method )
        return fallback();

    if( _format == "zip" ) {
        switch( *method ) {
            case CompressionMethod::store:
            case CompressionMethod::deflate:
            case CompressionMethod::bzip2:
            case CompressionMethod::lzma:
            case CompressionMethod::zstd:
                options.format = CompressionFormat::zip;
                options.method = *method;
                return options;
            default:
                return fallback();
        }
    }

    if( _format == "7z" || _format == "7zip" ) {
        switch( *method ) {
            case CompressionMethod::store:
            case CompressionMethod::deflate:
            case CompressionMethod::bzip2:
            case CompressionMethod::lzma: // mapped onto lzma2 by the job
            case CompressionMethod::zstd:
                options.format = CompressionFormat::sevenzip;
                options.method = *method;
                return options;
            default:
                return fallback();
        }
    }

    if( _format == "tar" ) {
        switch( *method ) {
            case CompressionMethod::none:
            case CompressionMethod::store: // "no compression" has a direct tar equivalent
                options.format = CompressionFormat::tar;
                options.method = CompressionMethod::none;
                return options;
            case CompressionMethod::gzip:
            case CompressionMethod::bzip2:
            case CompressionMethod::xz:
            case CompressionMethod::zstd:
                options.format = CompressionFormat::tar;
                options.method = *method;
                return options;
            default:
                return fallback();
        }
    }

    return fallback();
}

[[nodiscard]] constexpr const char *CompressionFormatName(CompressionFormat _format) noexcept
{
    switch( _format ) {
        case CompressionFormat::zip:
            return "zip";
        case CompressionFormat::sevenzip:
            return "7z";
        case CompressionFormat::tar:
            return "tar";
    }
    return "zip";
}

[[nodiscard]] constexpr const char *CompressionMethodName(CompressionMethod _method) noexcept
{
    switch( _method ) {
        case CompressionMethod::store:
            return "store";
        case CompressionMethod::deflate:
            return "deflate";
        case CompressionMethod::bzip2:
            return "bzip2";
        case CompressionMethod::lzma:
            return "lzma";
        case CompressionMethod::zstd:
            return "zstd";
        case CompressionMethod::none:
            return "none";
        case CompressionMethod::gzip:
            return "gzip";
        case CompressionMethod::xz:
            return "xz";
    }
    return "deflate";
}

// The filename suffix (including the leading dot) matching the container and, for tar, the filter.
[[nodiscard]] inline std::string_view CompressionExtension(const CompressionOptions &_options) noexcept
{
    switch( _options.format ) {
        case CompressionFormat::zip:
            return ".zip";
        case CompressionFormat::sevenzip:
            return ".7z";
        case CompressionFormat::tar:
            switch( _options.method ) {
                case CompressionMethod::gzip:
                    return ".tar.gz";
                case CompressionMethod::bzip2:
                    return ".tar.bz2";
                case CompressionMethod::xz:
                    return ".tar.xz";
                case CompressionMethod::zstd:
                    return ".tar.zst";
                default:
                    return ".tar";
            }
    }
    return ".zip";
}

} // namespace nc::ops
