// Copyright (C) 2013-2026 Michael Kazakov. Subject to GNU General Public License version 3.
#pragma once

#include <libarchive/archive.h>
#include <libarchive/archive_entry.h>
#include <VFS/VFSFile.h>
#include <deque>

namespace nc::vfs::arc {

constexpr inline uint32_t SyntheticArUID = std::numeric_limits<uint32_t>::max();

// Streams the content of a single entry out of a local RAR archive with the help of the UnRAR
// library. UnRAR delivers the data through a callback while it processes an entry, so the
// decompression runs on a worker thread and the bytes are handed over through a bounded buffer.
class UnrarStream
{
public:
    // Returns nullptr if the archive can't be opened.
    static std::unique_ptr<UnrarStream>
    Open(const std::string &_archive_path, const std::string &_entry_path, const VFSCancelChecker &_cancel_checker);
    UnrarStream(const UnrarStream &) = delete;
    UnrarStream &operator=(const UnrarStream &) = delete;
    ~UnrarStream();

    // Reads at most _size bytes. Returns the number of bytes read, 0 at the end of the entry and
    // -1 if the decompression has failed or has been cancelled.
    long Read(void *_buffer, size_t _size);

private:
    class Impl;
    UnrarStream(std::string _archive_path, std::string _entry_path, const VFSCancelChecker &_cancel_checker);
    std::unique_ptr<Impl> I;
};

struct Mediator {
    std::shared_ptr<VFSFile> file;

    // Optional cancellation token. It is polled from the read callback, since some archives (e.g. solid RARs)
    // have to be decompressed end-to-end just to enumerate their entries - without it a scan of a big archive
    // cannot be aborted at all.
    VFSCancelChecker cancel_checker;
    bool cancelled = false;

    enum {
        bufsz = 65536 * 4
    };
    char buf[bufsz];

    static ssize_t myread(struct ::archive *a, void *client_data, const void **buff);
    static off_t myseek(struct ::archive *a, void *client_data, off_t offset, int whence);

    void setup(struct archive *a);
};

struct State {
    // passes ownership of _arc
    State(const VFSFilePtr &_file, struct archive *_arc);
    State(const State &) = delete;
    ~State();

    struct ::archive *Archive() { return m_Archive; }
    struct ::archive_entry *Entry() { return m_Entry; }
    uint32_t UID() { return m_UID; }
    bool Consumed() { return m_Consumed; }

    // assumes that this call is in  archive_read_next_header cycle. sets consumed flag to false
    void SetEntry(struct ::archive_entry *_e, uint32_t _uid);
    void ConsumeEntry() { m_Consumed = true; }

    // libarchive API wrapping
    // any error codes are raw libarchive one, not converted to VFSError
    int Open();
    int Errno();

private:
    void Setup();
    static ssize_t myread(struct ::archive *a, void *client_data, const void **buff);
    static off_t myseek(struct ::archive *a, void *client_data, off_t offset, int whence);

    enum {
        BufferSize = 65536 * 4
    };
    VFSFilePtr m_File;
    struct ::archive *m_Archive = nullptr;
    struct ::archive_entry *m_Entry = nullptr; // entry for current archive state
    uint32_t m_UID = 0;
    bool m_Consumed = false;
    char m_Buf[BufferSize];
};

struct DirEntry {
    std::string name;
    struct stat st;
    uint32_t aruid = 0; // unique number inside archive in same order as appearance in archive
};

struct Dir {
    std::string full_path;      // should always be with a trailing slash
    std::string name_in_parent; // can be "" only for root directory, full_path will be "/"
    uint64_t content_size = 0;
    std::vector<DirEntry> entries;
};

} // namespace nc::vfs::arc
