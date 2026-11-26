// Copyright (C) 2019-2026 Michael Kazakov. Subject to GNU General Public License version 3.
#include <Utility/UTIImpl.h>
#include <Foundation/Foundation.h>
#include <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <string>

namespace nc::utility {

namespace {

NSString *StringFromView(std::string_view _view)
{
    return [[NSString alloc] initWithBytes:_view.data() length:_view.size() encoding:NSUTF8StringEncoding];
}

std::string StringFromNSString(NSString *_string)
{
    return _string.length != 0 ? std::string(_string.UTF8String) : std::string{};
}

} // namespace

std::string UTIDBImpl::UTIForExtension(std::string_view _extension) const
{
    const std::lock_guard lock{m_ExtensionToUTILock};
    if( const auto i = m_ExtensionToUTI.find(_extension); i != std::end(m_ExtensionToUTI) )
        return i->second;

    @autoreleasepool {
        NSString *const extension = StringFromView(_extension);
        UTType *const type = extension.length != 0 ? [UTType typeWithFilenameExtension:extension] : nil;
        if( type != nil ) {
            const std::string uti = StringFromNSString(type.identifier);
            m_ExtensionToUTI.emplace(std::string(_extension), uti);
            return uti;
        }
    }
    return {};
}

bool UTIDBImpl::IsDeclaredUTI(std::string_view _uti) const
{
    if( IsDynamicUTI(_uti) )
        return false; // dynamic UTIs are never declared

    const std::lock_guard lock{m_DeclaredLock};
    if( const auto it = m_DeclaredUTIs.find(_uti); it != m_DeclaredUTIs.end() )
        return it->second;

    @autoreleasepool {
        NSString *const identifier = StringFromView(_uti);
        UTType *const type = identifier.length != 0 ? [UTType typeWithIdentifier:identifier] : nil;
        const bool declared = type != nil && type.isDeclared;
        m_DeclaredUTIs.emplace(std::string(_uti), declared);
        return declared;
    }
}

bool UTIDBImpl::IsDynamicUTI(std::string_view _uti) const
{
    constexpr std::string_view prefix = "dyn.a";
    return _uti.starts_with(prefix);
}

bool UTIDBImpl::ConformsTo(std::string_view _uti, std::string_view _conforms_to) const
{
    const std::lock_guard lock{m_ConformsToLock};
    if( const auto it = m_ConformsTo.find(_uti); it != m_ConformsTo.end() )
        return it->second.contains(_conforms_to);

    ankerl::unordered_dense::set<std::string, UnorderedStringHashEqual, UnorderedStringHashEqual> conforming_utis;
    @autoreleasepool {
        NSString *const identifier = StringFromView(_uti);
        UTType *const type = identifier.length != 0 ? [UTType typeWithIdentifier:identifier] : nil;
        for( UTType *const supertype in type.supertypes )
            conforming_utis.emplace(StringFromNSString(supertype.identifier));
    }

    const bool does_conform = conforming_utis.contains(_conforms_to);
    m_ConformsTo.emplace(std::string(_uti), std::move(conforming_utis));
    return does_conform;
}

} // namespace nc::utility
