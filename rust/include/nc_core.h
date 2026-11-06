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

// DT_* values used by nc_flat_batch::types
enum {
    NC_DT_UNKNOWN = 0,
    NC_DT_FIFO = 1,
    NC_DT_CHR = 2,
    NC_DT_DIR = 4,
    NC_DT_BLK = 6,
    NC_DT_REG = 8,
    NC_DT_LNK = 10,
    NC_DT_SOCK = 12,
    NC_DT_WHT = 14,
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

// One batch of entries of a single directory, as columns. Every pointer is only valid for the
// duration of the callback; names are NUL-terminated and name_lengths excludes the NUL.
// Anything the volume does not report is filled with a neutral value: sizes = UINT64_MAX for
// directories, add_times = -1, inodes = 0.
typedef struct nc_flat_batch {
    const char *dir_path;
    uint32_t dir_path_len;
    uint32_t count;
    const char *const *names;
    const uint32_t *name_lengths;
    const uint8_t *types;  // NC_DT_* values
    const uint32_t *modes; // full st_mode: file type bits + permission bits
    const uint64_t *sizes;
    const int64_t *mtimes;
    const int64_t *btimes;
    const int64_t *ctimes;
    const int64_t *atimes;
    const int64_t *add_times;
    const uint64_t *inodes;
    const uint32_t *uids;
    const uint32_t *gids;
    const uint32_t *flags;
} nc_flat_batch;

typedef struct nc_flat_stats {
    uint64_t files;
    uint64_t dirs;
    uint64_t entries;
    uint64_t directories_scanned;
} nc_flat_stats;

// Called from any worker thread, at most once per directory and only for the duration of the
// call.
typedef void (*nc_flat_batch_callback)(void *ctx, const nc_flat_batch *batch);

// Walks the tree under root in parallel (getattrlistbulk per directory) and reports every
// directory's entries as one batch. Only the local filesystem is covered.
int32_t nc_core_scan_flat(const char *root,
                          uint32_t threads,
                          nc_flat_batch_callback on_batch,
                          void *ctx,
                          const volatile int32_t *cancel_flag,
                          nc_flat_stats *stats);


// ---------------------------------------------------------------------------------------------
// Content search
// ---------------------------------------------------------------------------------------------

enum {
    NC_CONTENT_CASE_INSENSITIVE = 1 << 0,
    NC_CONTENT_WHOLE_PHRASE = 1 << 1,
};

typedef struct nc_content_params {
    const char *root;   // absolute UTF-8 path
    const char *needle; // raw bytes, usually UTF-8 text
    uint32_t needle_len;
    uint32_t options;       // NC_CONTENT_* bits
    uint32_t threads;       // 0 = auto
    uint64_t max_file_size; // 0 = no limit
} nc_content_params;

typedef struct nc_content_stats {
    uint64_t files_scanned;
    uint64_t files_skipped;
    uint64_t matches;
} nc_content_stats;

// Called for every file that contains the needle, possibly from any worker thread. rel_path is
// relative to the search root and only valid for the duration of the call.
typedef void (*nc_content_callback)(
    void *ctx, const char *rel_path, uint64_t offset, uint64_t bytes_len);

int32_t nc_core_search_content(const nc_content_params *params,
                               nc_content_callback on_found,
                               void *ctx,
                               const volatile int32_t *cancel_flag,
                               nc_content_stats *stats);

#ifdef __cplusplus
}
#endif
