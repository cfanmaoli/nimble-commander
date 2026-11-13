// Copyright (C) 2026 Michael Kazakov. Subject to GNU General Public License version 3.
#pragma once

#include "Host.h"
#include "Helper.h"
#include "Session.h"
#include <memory>
#include <optional>

namespace nc::vfs::rar {

// A file inside a RAR archive. The payload is streamed out of a persistent ncrar-helper session
// when one is available, and out of a dedicated one-shot helper process otherwise; both give the
// sequential access paradigm: reading goes forward only.
class File final : public VFSFile
{
public:
    File(std::string_view _relative_path, const std::shared_ptr<RarHelperHost> &_host);
    ~File() override;

    std::expected<void, Error> Open(unsigned long _open_flags, const VFSCancelChecker &_cancel_checker) override;
    bool IsOpened() const override;
    std::expected<void, Error> Close() override;
    std::expected<size_t, Error> Read(void *_buf, size_t _size) override;
    std::expected<void, Error> Skip(size_t _size) override;
    std::expected<uint64_t, Error> Seek(off_t _off, int _basis) override;
    ReadParadigm GetReadParadigm() const override;
    std::expected<uint64_t, Error> Pos() const override;
    std::expected<uint64_t, Error> Size() const override;
    bool Eof() const override;

private:
    void TerminateStream() noexcept;
    void ReleaseSession(bool _healthy) noexcept;

    std::optional<ChildProcess> m_Process; // one-shot "read" fallback
    std::unique_ptr<SessionLease> m_Session;
    uint64_t m_Position = 0;
    uint64_t m_Size = 0;
    bool m_Opened = false;
};

} // namespace nc::vfs::rar
