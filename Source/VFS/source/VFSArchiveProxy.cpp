// Copyright (C) 2014-2026 Michael Kazakov. Subject to GNU General Public License version 3.
#include "../include/VFS/VFSArchiveProxy.h"
#include "ArcHelper/Helper.h"
#include "ArcHelper/Host.h"
#include "ArcLA/Host.h"
#include "ArcLARaw/Host.h"
#include <optional>

namespace nc::vfs {

namespace {

// The external ncrar-helper is optional and has a say only on RAR archives: it isn't linked into
// the app, and a missing helper must not affect any other archive format. Returns nullptr when the
// helper doesn't apply, throws when it applies but fails to open the archive.
VFSHostPtr OpenWithRarHelper(const std::string &_path,
                             const VFSHostPtr &_parent,
                             const std::optional<std::string> &_password,
                             const VFSCancelChecker &_cancel_checker)
{
    if( !rar::FindHelper() )
        return nullptr;
    if( !rar::LooksLikeRarArchive(*_parent, _path, _cancel_checker) )
        return nullptr;
    return std::make_shared<RarHelperHost>(_path, _parent, _password, _cancel_checker);
}

} // namespace

VFSHostPtr VFSArchiveProxy::OpenFileAsArchive(const std::string &_path,
                                              const VFSHostPtr &_parent,
                                              std::function<std::string()> _passwd,
                                              VFSCancelChecker _cancel_checker)
{
    // A RAR archive gets the helper's first go, as libarchive has to decompress the payload of a
    // solid archive just to walk its headers and has no support for multi-volume archives at all.
    // Any failure falls through to the libarchive-based host below - the helper is a bonus, not a
    // requirement.
    std::optional<std::string> password;
    try {
        if( VFSHostPtr archive = OpenWithRarHelper(_path, _parent, std::nullopt, _cancel_checker) )
            return archive;
    } catch( ErrorException &e ) {
        if( e.error() == Error{Error::POSIX, ECANCELED} ) {
            // The caller has asked to stop - don't attempt any fallbacks, just give up.
            return nullptr;
        }
        if( e.error() == Error{Error::POSIX, ENEEDAUTH} && _passwd ) {
            // The archive is encrypted, ask for the password once and let the helper have another go.
            password = _passwd();
            if( password->empty() )
                return nullptr;
            try {
                if( VFSHostPtr archive = OpenWithRarHelper(_path, _parent, password, _cancel_checker) )
                    return archive;
            } catch( ErrorException & ) {
            }
        }
    }

    try {
        auto archive = std::make_shared<nc::vfs::ArchiveHost>(_path, _parent, password, _cancel_checker);
        return archive;
    } catch( ErrorException &e ) {
        if( e.error() == Error{Error::POSIX, ECANCELED} ) {
            // The caller has asked to stop - don't attempt any fallbacks, just give up.
            return nullptr;
        }
        if( e.error() == Error{Error::POSIX, ENEEDAUTH} && _passwd ) {
            auto passwd = _passwd();
            if( passwd.empty() )
                return nullptr;
            try {
                auto archive = std::make_shared<nc::vfs::ArchiveHost>(_path, _parent, passwd, _cancel_checker);
                return archive;
            } catch( ErrorException &e ) {
            }
            return nullptr;
        }
    }

    if( nc::vfs::ArchiveRawHost::HasSupportedExtension(_path) ) {
        try {
            auto archive = std::make_shared<nc::vfs::ArchiveRawHost>(_path, _parent, _cancel_checker);
            return archive;
        } catch( ErrorException &e ) {
        }
    }

    return nullptr;
}

} // namespace nc::vfs
