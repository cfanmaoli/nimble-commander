// The C ABI of the Rust core. Hand-written on purpose: the report in
// nc-rewrite-eval/research/03-spike-report.md documents that cbindgen cannot generate a usable
// header for opaque handles, and keeping this file small keeps the boundary auditable.
#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    NC_CORE_OK = 0,
    NC_CORE_ERR_UTF8 = -2,
    NC_CORE_ERR_PANIC = -5,
    NC_CORE_ERR_INVALID_ARG = -7,
};

// Bits for nc_search_params::options
enum {
    NC_CORE_SEARCH_FILES = 1 << 0,
    NC_CORE_SEARCH_DIRS = 1 << 1,
    NC_CORE_SEARCH_CASE_INSENSITIVE = 1 << 2,
};

typedef struct nc_search_stats {
    uint64_t files_seen;
    uint64_t dirs_seen;
    uint64_t matches;
} nc_search_stats;

// Called for every match, possibly from any worker thread. rel_path is relative to the search
// root, NUL-terminated and only valid for the duration of the call.
typedef void (*nc_found_callback)(
    void *ctx, const char *rel_path, bool is_dir, uint64_t size, int64_t mtime);

typedef struct nc_search_params {
    const char *root;       // absolute UTF-8 path
    const char *mask;       // UTF-8 glob (* and ?), may be NULL
    uint32_t options;       // NC_CORE_SEARCH_* bits
    uint32_t threads;       // 0 = auto
    nc_found_callback on_found;
    void *ctx;
    const volatile int32_t *cancel_flag; // may be NULL
} nc_search_params;

uint32_t nc_core_abi_version(void);

// Smoke test, returns x + 1.
int32_t nc_core_ping(int32_t x);

// Parallel filename search over the local filesystem. Returns NC_CORE_OK or a negative error
// code; panics are caught and reported as NC_CORE_ERR_PANIC.
int32_t nc_core_search_native(const nc_search_params *params, nc_search_stats *stats);

// Glob matching (whole name), for differential tests against the C++ matcher.
bool nc_core_glob_match(const char *pattern, const char *text, bool case_insensitive);

#ifdef __cplusplus
}
#endif
