# Building Nimble Commander-Fork
This guide outlines the steps to build Nimble Commander-Fork from its source code. Follow these instructions to set up your development environment and start contributing to or experimenting with NC.

## Getting the code
The source code for NC is available for cloning. Use the following command to clone the repository:  
`git clone https://github.com/cfanmaoli/nimble-commander`  
To minimize internet bandwidth, you can opt to fetch only the latest version with:  
`git clone https://github.com/cfanmaoli/nimble-commander --depth=1`

## Compiling the Project
After obtaining the source code, you'll need Xcode 27.2 to open and compile the project. Navigate to the `NimbleCommander.xcodeproj` folder within the source code and open it using either the Xcode GUI or the command line with:  
`open nimble-commander/Source/NimbleCommander/NimbleCommander.xcodeproj`  

![](schema.png)

Make sure to select the `NimbleCommander-Unsigned` schema in Xcode. Now, you are ready to build the project. Use `Cmd+B` to build and `Cmd+R` to run the project under Xcode's debugger.

## Exploring the Source Code
Nimble Commander-Fork has a medium-sized codebase (~150KSloC) written in C++, Objective-C++ and Swift. The project includes the main application and 10 sub-projects:
  * Base: Foundational, general-purpose tools.
  * Config: Configuration management.
  * CUI: Shared UI components.
  * Operations: File operation suite built on the VFS layer.
  * Panel: File panel components.
  * RoutedIO: Admin Mode functionality, including the privileged helper and its client interface.
  * Term: Integrated terminal emulator.
  * Utility: System-specific utilities.
  * VFS: Virtual File Systems, providing a generic interface along with various implementations.
  * VFSIcon: Generates icons and thumbnails for VFS entries.
  * Viewer: Integrated file viewer component.

## Testing
Nimble Commander-Fork employs two testing strategies: unit tests (`_UT` suffix) for individual components, and integration tests (`_IT` suffix) for checking how those components interact. Each type of test is easily identifiable by its unique filename suffix and corresponding build target. For example, `Term` represents the library, `TermUT` the unit tests for this library, and `TermIT` the integration tests.  
Unit tests are quick and standalone, not requiring any external setups. In contrast, integration tests might need specific conditions, like running Docker VMs (detailed in `Source/VFS/tests/data/docker/[start|stop].sh`), to properly execute.  

## Limitations
While this source code mirrors that of the official Nimble Commander-Fork builds, the public repository does not include sensitive information such as specific accounts, addresses, and keys. Consequently, some features might be restricted or unavailable:
  * Privileged Helper: Requires proper signing to be installed and function correctly - see
    [Admin Mode and the privileged helper](#admin-mode-and-the-privileged-helper).

## Admin Mode and the privileged helper

Admin Mode runs a privileged helper as a launchd daemon registered through `SMAppService` (macOS 13+):

* plist inside the app bundle: `Contents/Library/LaunchDaemons/info.filesmanager.Files.PrivilegedIOHelperV3.plist`
* helper executable inside the app bundle: `Contents/Library/LaunchServices/info.filesmanager.Files.PrivilegedIOHelperV2`

The first time Admin Mode is enabled, the application registers the daemon with `SMAppService` and
prompts you to approve **Nimble Commander-Fork** in *System Settings → General → Login Items &
Extensions*. Once approved, `launchd` starts the helper on demand directly from inside the
application bundle (no copy is placed in `/Library/PrivilegedHelperTools`).

The helper verifies incoming XPC clients against the team-bound code-signing requirement
(`certificate leaf[subject.OU] = "359W39ZS37"`) in `Source/RoutedIO/source/PrivilegedIOHelper.cpp`
using both `SecStaticCodeCheckValidity` and `xpc_connection_set_peer_code_signing_requirement`,
along with hardened runtime / library validation. Using `subject.OU` rather than a certificate's
common name keeps the requirement working across both Apple Development and Developer ID
certificates of the same team. If the signing team changes, update `g_SignatureRequirement` in
`Source/RoutedIO/source/PrivilegedIOHelper.cpp`.

To check or reset the registered daemon:

```sh
# is the SMAppService daemon loaded?
launchctl print system/info.filesmanager.Files.PrivilegedIOHelperV3

# did the helper accept or reject a connection?
log show --last 10m --style compact --predicate 'process == "info.filesmanager.Files.PrivilegedIOHelperV2"'

# unregister the SMAppService daemon (and remove any legacy 1.9.x SMJobBless helper when run with sudo)
sudo "/Applications/Nimble Commander-Fork.app/Contents/MacOS/Nimble Commander-Fork" --uninstall-privileged-helper
```

## Implementation Notes
  * [Syntax Highlighting](SyntaxHighlighting.md)
  * [Creating Image Templates from SF Symbols](ImageTemplatesFromSFSymbols.md)
  * [Unity Builds](https://kazakov.life/2025/12/12/nimble-commander-and-build-times/)
