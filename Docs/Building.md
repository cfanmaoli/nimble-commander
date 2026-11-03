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

Admin Mode runs a privileged helper as a launchd daemon:

* `/Library/LaunchDaemons/info.filesmanager.Files.PrivilegedIOHelperV2.plist`
* `/Library/PrivilegedHelperTools/info.filesmanager.Files.PrivilegedIOHelperV2`

The application installs it with `SMJobBless()` the first time Admin Mode is enabled, and macOS asks
for administrator credentials. Both sides declare the code-signing requirement the other has to
satisfy:

* the application lists the helper in `SMPrivilegedExecutables` (`NimbleCommander-NonMAS-Info.plist`);
* the helper lists its clients in `SMAuthorizedClients` (`Source/RoutedIO/source/PrivilegedIOHelper-Info.plist`).

With a locally signed build both requirements point at the signing team rather than at a developer's
name - e.g. `certificate leaf[subject.OU] = "359W39ZS37"` - because the CN of an Apple Development
certificate contains the developer's Apple ID, which has no business being in the sources. If the
certificate or the team ever changes, update both plists, otherwise the helper will silently reject
the application.

Two things to keep in mind while developing:

* The helper lives outside the application bundle, so it is **not** replaced when the application is
  rebuilt and reinstalled - it is updated only when Admin Mode is enabled again.
  `Scripts/sign-install-fork.sh` prints a note when the bundled and the installed helpers differ; a
  fresh Admin Mode toggle (with an administrator password) updates it.
* `SMJobBless()` replaces an installed helper only when its `CFBundleVersion`
  (`Source/RoutedIO/source/PrivilegedIOHelper-Info.plist`) is greater - bump it whenever the helper's
  code changes.

The helper identifies its clients by the requirement above plus the fact that the client lives in an
application bundle. It deliberately does not match the executable's file name, which used to break
every time the application was renamed.

To check what is installed:

```sh
# is the installed helper the same as the bundled one?
shasum /Library/PrivilegedHelperTools/info.filesmanager.Files.PrivilegedIOHelperV2 \
       "/Applications/Nimble Commander-Fork.app/Contents/Library/LaunchServices/info.filesmanager.Files.PrivilegedIOHelperV2"

# is the daemon running?
launchctl print system/info.filesmanager.Files.PrivilegedIOHelperV2

# did the helper accept or reject a connection?
log show --last 10m --style compact --predicate 'process == "info.filesmanager.Files.PrivilegedIOHelperV2"'
```

If the application reports *"Failed to access the privileged helper."* and cannot recover by itself,
remove the outdated helper and enable Admin Mode again:

```sh
sudo launchctl bootout system/info.filesmanager.Files.PrivilegedIOHelperV2
sudo rm -f /Library/LaunchDaemons/info.filesmanager.Files.PrivilegedIOHelperV2.plist \
           /Library/PrivilegedHelperTools/info.filesmanager.Files.PrivilegedIOHelperV2
```

## Implementation Notes
  * [Syntax Highlighting](SyntaxHighlighting.md)
  * [Creating Image Templates from SF Symbols](ImageTemplatesFromSFSymbols.md)
  * [Unity Builds](https://kazakov.life/2025/12/12/nimble-commander-and-build-times/)
