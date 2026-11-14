// Copyright (C) 2026 Michael Kazakov. Subject to GNU General Public License version 3.
#pragma once

#include "../../include/VFS/Host.h"
#include "../../include/VFS/VFSFile.h"
#include "Protocol.h"
#include <memory>
#include <optional>
#include <string>
#include <string_view>

namespace nc::vfs {

// A read-only VFS over a RAR archive served by the external ncrar-helper program. Nothing from the
// UnRAR library is linked into the app: this host only knows the helper's text protocol.
class RarHelperHost final : public Host
{
public:
    // The fixed tag identifying this VFS class.
    static const char *const UniqueTag;

    RarHelperHost(std::string_view _path,
                  const VFSHostPtr &_parent,
                  std::optional<std::string> _password = std::nullopt,
                  VFSCancelChecker _cancel_checker = {});
    RarHelperHost(const VFSHostPtr &_parent, const VFSConfiguration &_config, VFSCancelChecker _cancel_checker = {});
    ~RarHelperHost() override;

    // Type-erased configuration that contains the data to restore this VFS.
    VFSConfiguration Configuration() const override;

    static VFSMeta Meta();

    bool IsImmutableFS() const noexcept override;

    bool IsWritable() const override;

    bool
    IsDirectory(std::string_view _path, unsigned long _flags, const VFSCancelChecker &_cancel_checker = {}) override;

    std::expected<VFSStat, Error>
    Stat(std::string_view _path, unsigned long _flags, const VFSCancelChecker &_cancel_checker = {}) override;

    std::expected<std::shared_ptr<VFSFile>, Error> CreateFile(std::string_view _path,
                                                              const VFSCancelChecker &_cancel_checker = {}) override;

    std::expected<VFSListingPtr, Error> FetchDirectoryListing(std::string_view _path,
                                                              unsigned long _flags,
                                                              const VFSCancelChecker &_cancel_checker = {}) override;

    std::expected<void, Error>
    IterateDirectoryListing(std::string_view _path,
                            const std::function<bool(const VFSDirEnt &_dirent)> &_handler) override;

    std::expected<std::string, Error> ReadSymlink(std::string_view _symlink_path,
                                                  const VFSCancelChecker &_cancel_checker = {}) override;

    bool ShouldProduceThumbnails() const override;

    // Resolves every symlink component of _path to the path of the entry it points at. With
    // _follow_last false a trailing symlink itself isn't followed.
    [[nodiscard]] std::expected<std::string, Error>
    ResolvePath(std::string_view _path, bool _follow_last, const VFSCancelChecker &_cancel_checker = {}) const;

    // True when the archive has at least one link entry, i.e. path resolution isn't a no-op.
    [[nodiscard]] bool NeedsPathResolving() const noexcept;

    // Path of the helper executable that was located when this host was built.
    [[nodiscard]] const std::string &HelperPath() const noexcept;

    // Password of the archive, empty when it isn't set.
    [[nodiscard]] std::string_view Password() const noexcept;

    // Index that the helper's "read" command expects for the entry at _path, if such an entry exists.
    [[nodiscard]] std::optional<uint32_t> IndexForPath(std::string_view _path) const noexcept;

    std::shared_ptr<RarHelperHost> SharedPtr();

private:
    struct Impl;

    std::expected<void, Error> DoInit(const VFSCancelChecker &_cancel_checker);
    std::expected<void, Error> ReadListing(const VFSCancelChecker &_cancel_checker);
    void BuildTree(const rar::Listing &_listing);
    const class RarHelperHostConfiguration &Config() const;

    std::unique_ptr<Impl> I;
    VFSConfiguration m_Configuration;
};

} // namespace nc::vfs
