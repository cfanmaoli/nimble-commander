// Copyright (C) 2014-2026 Michael Kazakov. Subject to GNU General Public License version 3.
#include <Security/Security.h>
#include <Utility/SystemInformation.h>
#include <RoutedIO/RoutedIO.h>
#include <RoutedIO/Log.h>
#include <iostream>
#include <string>
#include <unistd.h>
#include "RoutedIOInterfaces.h"
#include "Internal.h"

namespace nc::routedio {

static PosixIOInterface &IODirectCreateProxy();
static PosixIOInterface &IOWrappedCreateProxy();

PosixIOInterface &RoutedIO::Direct = IODirectCreateProxy();
PosixIOInterface &RoutedIO::Default = IOWrappedCreateProxy();

static const char *g_HelperLabel = "info.filesmanager.Files.PrivilegedIOHelperV3";
static const char *g_HelperPlistName = "info.filesmanager.Files.PrivilegedIOHelperV3.plist";
static const char *g_LegacyHelperLabel = "info.filesmanager.Files.PrivilegedIOHelperV2";
static const char *g_LegacyPlistPath = "/Library/LaunchDaemons/info.filesmanager.Files.PrivilegedIOHelperV2.plist";
static const char *g_LegacyBinaryPath = "/Library/PrivilegedHelperTools/info.filesmanager.Files.PrivilegedIOHelperV2";

static const char *AuthRCToString(OSStatus _rc) noexcept;

static PosixIOInterface &IODirectCreateProxy()
{
    [[clang::no_destroy]] static PosixIOInterfaceNative direct;
    return direct;
}

static PosixIOInterface &IOWrappedCreateProxy()
{
    static PosixIOInterface *interface = []() -> PosixIOInterface * {
        return !nc::utility::IsThisProcessSandboxed() ? new PosixIOInterfaceRouted(RoutedIO::Instance())
                                                      : new PosixIOInterfaceNative();
    }();
    return *interface;
}

RoutedIO::RoutedIO() : m_Sandboxed(nc::utility::IsThisProcessSandboxed())
{
}

RoutedIO &RoutedIO::Instance()
{
    [[clang::no_destroy]] static RoutedIO inst;
    return inst;
}

bool RoutedIO::RequiresApproval() const noexcept
{
    return m_RequiresApproval;
}

void RoutedIO::OpenSystemSettingsLoginItems() noexcept
{
    nc::routedio::OpenSystemSettingsLoginItems();
}

bool RoutedIO::EnsureHelperRegistered()
{
    if( m_Sandboxed ) {
        Log::Error("RoutedIO::EnsureHelperRegistered() was called in a sandboxed process");
        return false;
    }

    DaemonServiceStatus status = QueryDaemonServiceStatus(g_HelperPlistName);
    if( status == DaemonServiceStatus::Enabled )
        return true;

    if( status == DaemonServiceStatus::NotRegistered || status == DaemonServiceStatus::NotFound ) {
        const DaemonServiceResult res = RegisterDaemonService(g_HelperPlistName);
        status = res.status;
        if( res.ok && status == DaemonServiceStatus::Enabled ) {
            Log::Info("Registered privileged helper daemon via SMAppService");
            return true;
        }
        if( status == DaemonServiceStatus::RequiresApproval ) {
            Log::Info("Privileged helper daemon registered; awaiting user approval in System Settings");
            m_RequiresApproval = true;
            return false;
        }
        if( !res.ok ) {
            Log::Error("Failed to register privileged helper daemon via SMAppService: {}", res.error);
            return false;
        }
    }

    if( status == DaemonServiceStatus::RequiresApproval ) {
        Log::Info("Privileged helper daemon requires approval in System Settings");
        m_RequiresApproval = true;
        return false;
    }

    return status == DaemonServiceStatus::Enabled;
}

bool RoutedIO::ReRegisterHelper()
{
    Log::Warn("Re-registering privileged helper daemon via SMAppService");
    const DaemonServiceResult unreg = UnregisterDaemonService(g_HelperPlistName);
    if( !unreg.ok )
        Log::Warn("SMAppService unregister returned: {}", unreg.error);

    const DaemonServiceResult reg = RegisterDaemonService(g_HelperPlistName);
    if( reg.status == DaemonServiceStatus::RequiresApproval ) {
        m_RequiresApproval = true;
        return false;
    }
    if( !reg.ok && reg.status != DaemonServiceStatus::Enabled ) {
        Log::Error("SMAppService re-register failed: {}", reg.error);
        return false;
    }
    return reg.status == DaemonServiceStatus::Enabled;
}

void RoutedIO::CleanupLegacyHelperIfPresent()
{
    if( !m_Connection )
        return;

    const auto unlink_via_helper = [this](const char *_path) {
        if( access(_path, F_OK) != 0 )
            return;
        xpc_object_t message = xpc_dictionary_create(nullptr, nullptr, 0);
        xpc_dictionary_set_string(message, "operation", "unlink");
        xpc_dictionary_set_string(message, "path", _path);
        xpc_object_t reply = xpc_connection_send_message_with_reply_sync(m_Connection, message);
        xpc_release(message);
        if( xpc_get_type(reply) != XPC_TYPE_ERROR && xpc_dictionary_get_bool(reply, "ok") )
            Log::Info("Removed legacy SMJobBless helper artifact: {}", _path);
        xpc_release(reply);
    };

    unlink_via_helper(g_LegacyPlistPath);
    unlink_via_helper(g_LegacyBinaryPath);
}

bool RoutedIO::TurnOn()
{
    Log::Info("RoutedIO::TurnOn() called");

    if( m_Sandboxed ) {
        Log::Error("RoutedIO::TurnOn() was called in the sandboxed process.");
        return false;
    }

    if( m_Enabled )
        return true;

    m_RequiresApproval = false;

    if( !EnsureHelperRegistered() )
        return false;

    if( !AuthenticateAsAdmin() ) {
        Log::Error("Failed to authenticate as admin, cannot turn RoutedIO on");
        return false;
    }

    if( !Connect() || !IsHelperAlive() ) {
        if( m_Connection ) {
            xpc_connection_cancel(m_Connection);
            xpc_release(m_Connection);
            m_Connection = nullptr;
        }
        // Per SMAppService documentation, updating the app bundle can require unregistering and
        // re-registering the daemon before launchd will bootstrap the updated binary.
        if( !ReRegisterHelper() )
            return false;
        if( !Connect() || !IsHelperAlive() ) {
            if( m_Connection ) {
                xpc_connection_cancel(m_Connection);
                xpc_release(m_Connection);
                m_Connection = nullptr;
            }
            Log::Error("Failed to connect to privileged helper after re-registration.");
            return false;
        }
    }

    m_Enabled = true;
    CleanupLegacyHelperIfPresent();

    Log::Info("RoutedIO enabled={}", m_Enabled.load());
    return m_Enabled;
}

void RoutedIO::TurnOff()
{
    Log::Info("RoutedIO::Turnoff() called");

    if( m_Connection ) {
        xpc_connection_cancel(m_Connection);
        xpc_release(m_Connection);
        m_Connection = nullptr;
    }
    m_Enabled = false;
    m_RequiresApproval = false;
    m_AuthenticatedAsAdmin = false;

    Log::Info("RoutedIO enabled={}", m_Enabled.load());
}

bool RoutedIO::SayImAuthenticated(xpc_connection_t _connection) noexcept
{
    xpc_object_t message = xpc_dictionary_create(nullptr, nullptr, 0);
    xpc_dictionary_set_bool(message, "auth", m_AuthenticatedAsAdmin);

    xpc_object_t reply = xpc_connection_send_message_with_reply_sync(_connection, message);
    xpc_release(message);

    bool result = false;
    if( xpc_get_type(reply) != XPC_TYPE_ERROR )
        if( xpc_dictionary_get_bool(reply, "ok") )
            result = true;

    xpc_release(reply);
    return result;
}

bool RoutedIO::AuthenticateAsAdmin()
{
    Log::Debug("RoutedIO::AuthenticateAsAdmin() called");

    if( m_Sandboxed ) {
        Log::Error("RoutedIO::AuthenticateAsAdmin() was called in a sandboxed process");
        return false;
    }

    if( m_AuthenticatedAsAdmin ) {
        Log::Debug("Already authenticated");
        return true;
    }

    // Request to auth as admin
    AuthorizationItem auth_rights_item = {
        .name = kAuthorizationRuleAuthenticateAsAdmin, .valueLength = 0, .value = nullptr, .flags = 0};
    const AuthorizationRights auth_rights = {.count = 1, .items = &auth_rights_item};

    // Provide a text prompt for the request
    std::string prompt = MessageAuthAsAdmin();
    AuthorizationItem auth_env_item = {
        .name = kAuthorizationEnvironmentPrompt, .valueLength = prompt.size(), .value = prompt.data(), .flags = 0};
    const AuthorizationEnvironment auth_env = {.count = 1, .items = &auth_env_item};

    // What to auth now
    const AuthorizationFlags flags =
        kAuthorizationFlagInteractionAllowed | kAuthorizationFlagPreAuthorize | kAuthorizationFlagExtendRights;

    const OSStatus status = AuthorizationCreate(&auth_rights, &auth_env, flags, nullptr);

    if( status == errAuthorizationSuccess ) {
        Log::Info("Successfully authenticated as administrator");
        m_AuthenticatedAsAdmin = true;
    }
    else {
        Log::Error("RoutedIO::AuthenticateAsAdmin() failed to execute AuthorizationCreate() with "
                   "the error: {}",
                   AuthRCToString(status));
    }

    return m_AuthenticatedAsAdmin;
}

bool RoutedIO::Connect()
{
    if( m_Connection )
        return true;

    if( !m_AuthenticatedAsAdmin ) {
        Log::Error("RoutedIO::Connect() was called without being authenticated as admin");
        return false;
    }

    xpc_connection_t connection =
        xpc_connection_create_mach_service(g_HelperLabel, nullptr, XPC_CONNECTION_MACH_SERVICE_PRIVILEGED);
    if( !connection ) {
        Log::Error("RoutedIO::Connect() failed to call xpc_connection_create_mach_service()");
        return false;
    }

    xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
      xpc_type_t type = xpc_get_type(event);
      if( type == XPC_TYPE_ERROR ) {
          if( event == XPC_ERROR_CONNECTION_INVALID ) {
              m_Connection = nullptr;
          }
      }
    });

    xpc_connection_resume(connection);

    if( !SayImAuthenticated(connection) ) {
        Log::Error("RoutedIO::Connect() failed to call SayImAuthenticated()");
        xpc_connection_cancel(connection);
        xpc_release(connection);
        return false;
    }

    m_Connection = connection;
    return true;
}

bool RoutedIO::ConnectionAvailable()
{
    return m_Connection != nullptr;
}

xpc_connection_t RoutedIO::Connection()
{
    if( ConnectionAvailable() )
        return m_Connection;
    if( Connect() )
        return m_Connection;
    return nullptr;
}

bool RoutedIO::IsHelperAlive()
{
    xpc_connection_t connection = Connection();
    if( !connection )
        return false;

    xpc_object_t message = xpc_dictionary_create(nullptr, nullptr, 0);
    xpc_dictionary_set_string(message, "operation", "heartbeat");

    xpc_object_t reply = xpc_connection_send_message_with_reply_sync(connection, message);
    xpc_release(message);

    bool result = false;
    if( xpc_get_type(reply) != XPC_TYPE_ERROR )
        if( xpc_dictionary_get_bool(reply, "ok") )
            result = true;

    xpc_release(reply);
    return result;
}

PosixIOInterface &RoutedIO::InterfaceForAccess(const char *_path, int _mode) noexcept
{
    const auto &instance = Instance();
    if( instance.m_Sandboxed )
        return Direct;

    if( !instance.m_Enabled )
        return Direct;

    return access(_path, _mode) == 0 ? RoutedIO::Direct : RoutedIO::Default;
}

bool RoutedIO::Enabled() const noexcept
{
    return m_Enabled;
}

void RoutedIO::InstallViaRootCLI()
{
    if( utility::IsThisProcessSandboxed() ) {
        std::cerr << "must be not a sandboxed process." << '\n';
        return;
    }

    const DaemonServiceResult res = RegisterDaemonService(g_HelperPlistName);
    if( res.status == DaemonServiceStatus::Enabled ) {
        std::cout << "Privileged helper daemon is registered and enabled." << '\n';
    }
    else if( res.status == DaemonServiceStatus::RequiresApproval ) {
        std::cout << "Privileged helper daemon registered. Approve Nimble Commander-Fork in "
                     "System Settings -> General -> Login Items & Extensions."
                  << '\n';
    }
    else {
        std::cerr << "Failed to register privileged helper daemon: " << res.error << '\n';
    }
}

void RoutedIO::UninstallViaRootCLI()
{
    using namespace std::string_literals;

    if( utility::IsThisProcessSandboxed() ) {
        std::cerr << "must be not a sandboxed process." << '\n';
        return;
    }

    const DaemonServiceResult res = UnregisterDaemonService(g_HelperPlistName);
    if( !res.ok )
        std::cerr << "SMAppService unregister: " << res.error << '\n';

    // Also remove any legacy SMJobBless V2 helper left behind by older releases when run as root.
    if( geteuid() == 0 && (access(g_LegacyPlistPath, F_OK) == 0 || access(g_LegacyBinaryPath, F_OK) == 0) ) {
        system(("launchctl bootout system/"s + g_LegacyHelperLabel).c_str());
        unlink(g_LegacyPlistPath);
        unlink(g_LegacyBinaryPath);
    }
}

PosixIOInterface::~PosixIOInterface() = default;

static const char *AuthRCToString(OSStatus _rc) noexcept
{
    switch( _rc ) {
        case errAuthorizationSuccess:
            return "errAuthorizationSuccess";
        case errAuthorizationInvalidSet:
            return "errAuthorizationInvalidSet";
        case errAuthorizationInvalidRef:
            return "errAuthorizationInvalidRef";
        case errAuthorizationInvalidTag:
            return "errAuthorizationInvalidTag";
        case errAuthorizationInvalidPointer:
            return "errAuthorizationInvalidPointer";
        case errAuthorizationDenied:
            return "errAuthorizationDenied";
        case errAuthorizationCanceled:
            return "errAuthorizationCanceled";
        case errAuthorizationInteractionNotAllowed:
            return "errAuthorizationInteractionNotAllowed";
        case errAuthorizationInternal:
            return "errAuthorizationInternal";
        case errAuthorizationExternalizeNotAllowed:
            return "errAuthorizationExternalizeNotAllowed";
        case errAuthorizationInternalizeNotAllowed:
            return "errAuthorizationInternalizeNotAllowed";
        case errAuthorizationInvalidFlags:
            return "errAuthorizationInvalidFlags";
        case errAuthorizationToolExecuteFailure:
            return "errAuthorizationToolExecuteFailure";
        case errAuthorizationToolEnvironmentError:
            return "errAuthorizationToolEnvironmentError";
        case errAuthorizationBadAddress:
            return "errAuthorizationBadAddress";
        default:
            return "Unknown OSStatus";
    }
}

} // namespace nc::routedio
