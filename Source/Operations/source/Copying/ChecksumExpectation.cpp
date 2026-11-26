// Copyright (C) 2017-2024 Michael Kazakov. Subject to GNU General Public License version 3.
#include "ChecksumExpectation.h"

#include <algorithm>

namespace nc::ops::copying {

ChecksumExpectation::ChecksumExpectation(int _source_ind, std::string _destination, std::vector<uint8_t> _digest)
    : destination_path(std::move(_destination)), original_item(_source_ind), digest(std::move(_digest))
{
    if( digest.empty() )
        throw std::invalid_argument("ChecksumExpectation: digest must not be empty");
}

bool operator==(const ChecksumExpectation &_lhs, const std::vector<uint8_t> &_rhs) noexcept
{
    return _lhs.digest == _rhs;
}

bool operator==(const std::vector<uint8_t> &_rhs, const ChecksumExpectation &_lhs) noexcept
{
    return _lhs == _rhs;
}

} // namespace nc::ops::copying
