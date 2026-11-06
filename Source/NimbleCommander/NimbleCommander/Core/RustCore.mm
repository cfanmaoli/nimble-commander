// Copyright (C) 2026 Michael Kazakov. Subject to GNU General Public License version 3.
#include "RustCore.h"
#include "nc_core.h"

#include <cstdio>
#include <cstdlib>
#include <stdexcept>

namespace nc::core {

unsigned RustCore::ABIversion()
{
    const unsigned version = nc_core_abi_version();
    if( version != 1u )
        throw std::runtime_error("the linked Rust core speaks an unexpected ABI version: " + std::to_string(version));
    return version;
}

int RustCore::Ping(const int _value)
{
    return nc_core_ping(_value);
}

bool RustCore::GlobMatch(const std::string &_pattern, const std::string &_text, const bool _case_insensitive)
{
    return nc_core_glob_match(_pattern.c_str(), _text.c_str(), _case_insensitive);
}

} // namespace nc::core
