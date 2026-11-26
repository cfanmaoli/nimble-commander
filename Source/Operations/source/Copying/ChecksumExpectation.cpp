// Copyright (C) 2017-2024 Michael Kazakov. Subject to GNU General Public License version 3.
#include "ChecksumExpectation.h"

#include <algorithm>

namespace nc::ops::copying {

ChecksumExpectation::ChecksumExpectation(int _source_ind, std::string _destination, const std::vector<uint8_t> &_digest)
    : destination_path(std::move(_destination)), original_item(_source_ind)
{
    if( _digest.empty() || _digest.size() > digest.size() )
        throw std::invalid_argument("ChecksumExpectation: unsupported digest size");
    std::ranges::copy(_digest, digest.begin());
    digest_size = static_cast<uint8_t>(_digest.size());
}

bool operator==(const ChecksumExpectation &_lhs, const std::vector<uint8_t> &_rhs) noexcept
{
    return _rhs.size() == _lhs.digest_size && std::equal(_rhs.begin(), _rhs.end(), _lhs.digest.begin());
}

bool operator==(const std::vector<uint8_t> &_rhs, const ChecksumExpectation &_lhs) noexcept
{
    return _lhs == _rhs;
}

} // namespace nc::ops::copying
