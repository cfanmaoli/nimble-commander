English | [简体中文](Help.zh-Hans.md)

# Getting Started

## Introduction

Nimble Commander-Fork is a free dual-pane file manager for macOS, designed with a focus on speed, keyboard-based navigation, and flexibility.
The project aims to blend the user experience of classic file managers from the '80s and '90s with the modern look and feel of Mac computers.
Nimble Commander-Fork follows the design principles of [orthodox file managers](https://en.wikipedia.org/wiki/File_manager#Orthodox_file_managers), specifically dual-pane file managers.
This website contains an in-depth study of this kind of software: [Less is More: Orthodox File Managers as Sysadmin IDE](https://softpanorama.org/OFM/index.shtml).

## System Requirements

The current version of Nimble Commander-Fork supports any Apple Silicon Mac running one of the following versions of macOS:

- macOS 27 Golden Gate
- macOS 26 Tahoe
- macOS 15 Sequoia
- macOS 14 Sonoma
- macOS 13 Ventura

While not a strict policy, a maintenance goal is to support the recent major releases of macOS.

Nimble Commander-Fork 2.0+ runs natively on Apple Silicon (ARM64) Macs only.

Below is the compatibility table for current and older releases:

| Versions       | Architecture | Minimum macOS Version  |
| -------------- | ------------ | ---------------------- |
| 2.0+           | ARM64        | macOS 13 Ventura       |
| 1.9.0 - 1.9.3c | x64 & ARM64  | macOS 12 Monterey      |
| 1.8.0          | x64 & ARM64  | macOS 11 Big Sur       |
| 1.2.9 - 1.7.0  | x64 & ARM64  | macOS 10.15 Catalina   |
| 1.2.0 - 1.2.7  | x64          | OS X 10.11 El Capitan  |
| 1.1.0 - 1.1.5  | x64          | OS X 10.10 Yosemite    |
| 1.0.7 - 1.0.9  | x64          | OS X 10.9 Mavericks    |
| 1.0.5 - 1.0.6  | x64          | OS X 10.8 Mountain Lion |
| 0.1.0 - 1.0.4  | x64          | Mac OS X 10.7 Lion     |

## Installation

Nimble Commander-Fork is portable; it doesn't require the installation of additional components and can run from any folder.
The fork ships the standalone build only (Apple Silicon, ARM64); drag the app icon into `/Applications` to install it.
You can also run Nimble Commander-Fork directly from a `.dmg` disk image.

![Copying NC from a dmg](Help-install-dmg.png)

## Running the Application

Simply double-click on the Nimble Commander-Fork icon to start it.

Because builds of this fork are not notarised, macOS may block the first launch of a downloaded copy. You can allow it in `System Settings > Privacy & Security` ("Open Anyway"), or remove the quarantine attribute after verifying the release SHA-256 checksum:

```sh
xattr -dr com.apple.quarantine "/Applications/Nimble Commander-Fork.app"
```

## Access Permissions

Accessing certain locations on macOS requires granting permissions.
This list of protected locations includes:

- Desktop Folder
- Documents Folder
- Downloads Folder
- Removable Volumes
- Network Volumes
- iCloud Drive

To browse and manage files in these locations, grant the necessary permissions in `System Settings > Privacy & Security > Files and Folders`.
Alternatively, you can grant Nimble Commander-Fork Full Disk Access in `System Settings > Privacy & Security > Full Disk Access`.

## Version Differences & Builds

This fork ships a single standalone, non-sandboxed build (see [Building](Building.md)) — the sandboxed Mac App Store build of the upstream project is not part of it. That is why Admin Mode, the integrated terminal, network shares, and the F1..F19 keys work without sandbox restrictions.

- **Stable releases** published on [GitHub Releases](https://github.com/cfanmaoli/nimble-commander/releases) are signed with the maintainer's Apple Development certificate (team `359W39ZS37`) and the hardened runtime, so **Admin Mode works**. They are not notarised, so macOS prompts once on first launch. Automatic update checks (Sparkle) follow stable releases via `appcast.xml`.
- **Nightly pre-releases** published by CI are unsigned and not notarised; Admin Mode is unavailable in unsigned builds because macOS only loads the privileged helper for a team-signed application. See [Release.md](Release.md) for signing details.

## Admin Mode

Admin Mode lets Nimble Commander-Fork perform privileged filesystem operations (reading or modifying root-owned directories, changing ownership/flags, or signaling other users' processes) via a bundled `SMAppService` launchd daemon (`Contents/Library/LaunchDaemons/info.filesmanager.Files.PrivilegedIOHelperV3.plist`).

- Toggle it from the menu bar: `Nimble Commander-Fork > Turn Admin Mode On` / `Turn Admin Mode Off`.
- On the first activation, macOS asks you to approve **Nimble Commander-Fork** under `System Settings > General > Login Items & Extensions` and authenticate as an administrator.
- While Admin Mode is active, Nimble Commander-Fork tries direct POSIX I/O first and escalates to the privileged helper only when direct access is denied with `EACCES` or `EPERM`. This keeps files in TCC-protected folders and on removable volumes accessible using the app's own permissions without requiring Full Disk Access (grant Full Disk Access only if you need Admin Mode to touch root-restricted files inside TCC-protected locations).

## Language Packs & Importing Settings

- **Language Packs** (`Preferences > Language`): Nimble Commander-Fork ships with built-in English, Russian, and Simplified Chinese localizations, and supports exporting, translating, and importing custom language packs. Community-maintained packs are available in [nc-language](https://github.com/cfanmaoli/nc-language).
- **Import Settings** (`Preferences > General > Import Settings`): You can import preferences, saved tabs, network connections, language packs, and syntax highlighting from an existing installation of the original Nimble Commander app.

# File Panels

## Introduction
Below is a screenshot of a typical interface of Nimble Commander-Fork:

![Example of the interface](Help-main-ui.png)

The main window is typically split vertically between the two panels.
Sometimes these panels are called panes; both words will be used interchangeably later on.
Only one panel is active at a time, which is indicated by highlighting.
To change the active panel, you can click on the desired panel or use hotkeys:

- `Tab`: focuses on the opposite panel
- `Shift + Cmd + Left`: focuses on the left panel
- `Shift + Cmd + Right`: focuses on the right panel

The proportion between the left and right panels can be changed by either dragging a vertical separator line or by using the hotkeys `Ctrl + Opt + Left` and `Ctrl + Opt + Right`.
A panel can also be collapsed entirely so that only one is visible.
This can be achieved by dragging the splitter all the way to one side or by using the hotkey `Shift + Cmd + P`, which toggles between dual-pane and single-pane modes.

Each panel is vertically divided into three logical parts:

- Header: contains the path of the current location and the indicator of the sorting mode.
- File items: displays a list of the file items in the location of this panel.
- Footer: shows the filename of the focused item, its size and modification date, the total number of items in the panel, and the free space available on this storage.

## Navigation
Nimble Commander-Fork supports both mouse-based and keyboard-based navigation inside the file panel, although the keyboard is preferred.
Use a single mouse click to change the cursor position (i.e., the focused item) and scroll gestures to scroll through the contents of the file panel without changing the cursor position.
The navigation hotkeys are the following:

- `Up`: moves the cursor up
- `Down`: moves the cursor down
- `Left`: moves the cursor left
- `Right`: moves the cursor right
- `Home`: moves the cursor to the first element
- `Opt + Home`: scrolls the contents to the first element
- `End`: moves the cursor to the last element
- `Opt + End`: scrolls the contents to the last element
- `Page Up`: moves the cursor to the previous page
- `Opt + Page Up`: scrolls the contents to the previous page
- `Page Down`: moves the cursor to the next page
- `Opt + Page Down`: scrolls the contents to the next page

To navigate to a different folder inside the file panel, either double-click on it or press `Return` when the folder is focused.
To go to a parent folder, do the same with the `..` [pseudo-folder](https://en.wikipedia.org/wiki/Path_(computing)#Representations_of_paths_by_operating_system_and_shell) located at the beginning of the items.
Displaying the `..` folder is optional and can be turned off in `Preferences`.
Pressing `Backward Delete` (Backspace) or `Cmd + Up` navigates to the parent folder, regardless of the current cursor position.

Nimble Commander-Fork stores location history for each file panel.
To navigate the history back and forth, use the `Cmd + [` and `Cmd + ]` hotkeys.

There are some locations that can be navigated to using hotkeys:

- `/`: Root of the filesystem
- `~` (`Shift + ~`) and `Shift + Cmd + H`: Home folder
- `Shift + Cmd + O`: Documents folder
- `Shift + Cmd + D`: Desktop folder
- `Opt + Cmd + L`: Downloads folder
- `Shift + Cmd + A`: Applications folder
- `Shift + Cmd + U`: Utilities folder
- `Opt + Cmd + P`: Processes list

To navigate to a commonly used location, you can use the Go To popup, which can be opened by pressing `F1` / `F2` or via the menu `Go > Left Panel...` / `Go > Right Panel...`.
This popup provides quick access to favorite locations, volumes, connections, and locations of other panels.
Elements of this popup have hotkeys associated with them in the order of appearance: `1`, `2`, ..., `9`, `0`, `-`, `=`.
Any text typed while the Go To popup is open will act as a filter, hiding locations that do not contain the typed text in their names.
Once you click on the selected location, the panel will navigate there and become focused if it wasn’t already.
Here is what the popup looks like:

![GoTo popup](Help-goto-popup.png)

To navigate to an arbitrary location on the filesystem, you can use the Go To Folder dialog opened by `Shift + Cmd + G` or through the menu `Go > Go To Folder...`.
In this dialog, you can type any path, and after clicking the Go button Nimble Commander-Fork will navigate to the specified folder.
Below is the view of this dialog box:

![GoTo dialog](Help-goto-dialog.png)

If the cursor is currently pointing to a file that is a symbolic link, the `Cmd + Right` hotkey (`Go > Follow Symlink`) can be used to navigate to the location the symlink points to.

## Opening Items
The `Return` key does more than just navigate into folders.
The action performed when you press `Return` depends on the type of item:

- For regular folders, it navigates into them.
- For archive files, it opens the archive and takes you to its root directory.
- For executable items, it runs the file inside the built-in terminal emulator.
- For all other items, the default macOS association is used to open them.

If you need to open an archive with a non-standard extension (`.xlsx`, `.pak`, etc.), you can force Nimble Commander-Fork to navigate into it instead of opening the item with an external application by using the `Cmd + Down` hotkey or the `Go > Into Folder` menu item.

The `Shift + Return` hotkey opens an item in macOS using its default association, regardless of the item type.

To open an item outside of Nimble Commander-Fork using a specific application, select the application from the `Open With` menu, which is available in the context menu or the `File` menu.

## Panel Management
You can swap the contents of the left and right panels using the `Cmd + U` hotkey or the menu item `View > Swap Panels`.
This operation also transfers the focus to the opposite panel.  
To sync the contents of the opposite panel with the contents of the current panel, you can use the `Opt + Cmd + U` hotkey or the menu item `View > Sync Panels`.  
In most cases, Nimble Commander-Fork will automatically refresh the contents of the file panel whenever the underlying part of the filesystem changes.
Sometimes, however, it's not possible to automatically detect these changes.
In such cases, the panel can be manually refreshed using the `Cmd + R` hotkey or the menu item `View > Refresh`.

The two panels in a Nimble Commander-Fork window normally have the same width.
If needed, this proportion can be changed by either dragging the splitter located between them or by using the `Ctrl + Opt + Left` / `Ctrl + Opt + Right` hotkeys.
Here is an example of panels with different widths:

![Panels proportion](Help-panel-proportion.png)

A panel can be collapsed entirely, turning the UI into single-pane mode.
This can also be done via the `Shift + Cmd + P` hotkey or the `View > Switch Dual/Single Pane` menu item.
To return to dual-pane mode, expand the collapsed panel the same way it was previously collapsed, or press `Shift + Cmd + P` again.
The following screenshot provides an example of how single-pane mode looks:

![Single-pane mode](Help-panel-collapsed.png)

## Selection
Nimble Commander-Fork follows the UX of orthodox file managers and diverges from the typical macOS UX when it comes to item selection.
It treats item selection and cursor position separately, which means moving the cursor does not change the selection of items in the panel.
Below is an example of a panel with some selected items and the cursor focused on an item that is not selected:

![Items selection](Help-panel-selection.png)

There are numerous ways to manipulate the item selection using the keyboard or mouse in Nimble Commander-Fork:

- `Cmd + A`: selects all items.
- `Opt + Cmd + A`: deselects all items.
- `Ctrl + Cmd + A`: inverts the selection.
- `Shift + Up` / `Shift + Down`: inverts the selection of the currently focused item before moving the cursor. The behaviour (selection or deselection) is determined when the `Shift` key is pressed and persists while it is held down.
- `Shift + Cursor Movement`: changes the selection within the range starting at the current cursor position and ending at the new cursor position. The selection is inverted depending on the state of the initially focused item: if it was not selected, the entire range will be selected; if it was already selected, the whole range will be deselected.
- `Enter` (numeric keypad `Enter` or `Fn + Return`, distinct from `Return`): inverts the selection of the currently focused item and moves the cursor to the next item.
- `Cmd + Click`: inverts the selection of the clicked item.
- `Cmd + =`: selects all items with a filename matching the specified file mask or regular expression.
- `Cmd + -`: deselects all items with a filename matching the specified file mask or regular expression.
- `Opt + Cmd + =`: selects all items with the same extension as the currently focused item.
- `Opt + Cmd + -`: deselects all items with the same extension as the currently focused item.

## Sorting Modes
Nimble Commander-Fork offers various ways to organize items in a folder.
You can sort the items in ascending or descending order based on the following properties:

- Name
- Extension
- Size
- Modified Time
- Created Time
- Added Time
- Accessed Time

A letter indicator in the top-left corner of the file panel shows the current sorting criteria:

| Indicator | Criteria      | Order      | Example         |
| --------- | ------------- | ---------- | --------------- |
| `n`       | Name          | Ascending  | a ... z         |
| `N`       | Name          | Descending | z ... a         |
| `e`       | Extension     | Ascending  | csv ... zip     |
| `E`       | Extension     | Descending | zip ... csv     |
| `s`       | Size          | Descending | 10 MB ... 1 MB  |
| `S`       | Size          | Ascending  | 1 MB ... 10 MB  |
| `m`       | Modified Time | Descending | 20:43 ... 18:15 |
| `M`       | Modified Time | Ascending  | 18:15 ... 20:43 |
| `b`       | Created Time  | Descending | 20:43 ... 18:15 |
| `B`       | Created Time  | Ascending  | 18:15 ... 20:43 |
| `a`       | Added Time    | Descending | 20:43 ... 18:15 |
| `A`       | Added Time    | Ascending  | 18:15 ... 20:43 |
| `x`       | Accessed Time | Descending | 20:43 ... 18:15 |
| `X`       | Accessed Time | Ascending  | 18:15 ... 20:43 |

This is an example of the sorting pop-up menu shown after clicking on the sorting indicator:

![Sorting pop-up](Help-panel-sorting.png)

You can change the sorting order by clicking on the indicator and selecting a new option in the pop-up menu, by using the menu `View > Sorting`, by clicking the column headers in List View mode, or via the following hotkeys:

- `Ctrl + Cmd + 1`: Sort by Name.
- `Ctrl + Cmd + 2`: Sort by Extension.
- `Ctrl + Cmd + 3`: Sort by Modified Time.
- `Ctrl + Cmd + 4`: Sort by Size.
- `Ctrl + Cmd + 5`: Sort by Creation Time.
- `Ctrl + Cmd + 6`: Sort by Added Time.
- `Ctrl + Cmd + 7`: Sort by Accessed Time.

When changing the sorting order via hotkeys or the menu, the behavior depends on the previous sorting order.
If the criteria are different, it will switch to the selected criteria with its default order (as shown in the table above).
Selecting the same sorting criteria again will toggle the order between ascending and descending.

Nimble Commander-Fork also provides customization options to fine-tune sorting:

- `Separate Folders from Files` places all folders before any regular files.
- `Extensionless Folders` forces extension-based sorting to treat any folder as if it doesn't have an extension.
- `Comparison` affects how filenames are compared when determining the order:
  - `Natural`: takes into account locale-specific collation rules and treats digits as numbers. This is the same ordering used by Finder and approximately follows the [Unicode collation algorithm](https://en.wikipedia.org/wiki/Unicode_collation_algorithm). The slowest of the three.
  - `Case-Insensitive`: a Unicode-based comparison that ignores the case of letters in filenames.
  - `Case-Sensitive`: a simple Unicode-based comparison that compares characters one by one without transformations. The fastest of the three.

## Hidden Items
In Nimble Commander-Fork, items are considered hidden if their filenames begin with a dot (`"."`) or if they have the hidden file attribute (`UF_HIDDEN`) set.
The special parent folder entry (`".."`) is never treated as hidden.
By default, hidden items are not shown in the file panels.
You can toggle their visibility using the `Shift + Cmd + .` hotkey or by selecting `View > Show Hidden Files` from the menu.

## Quick Search
Nimble Commander-Fork offers a fast way to locate a file in a folder by typing a few letters from its name.
This keyboard-based navigation is called Quick Search.
It's highly customizable and can behave differently based on your settings, but at its core, the idea is simple: any keyboard input can be used to filter folder items.
To remove the filtering, press the `Esc` key to clear the search query.

Quick Search underscores the items with matching filenames and offers two ways to handle non-matching items: either continue showing them or hide them from the listing.
This behavior can be changed in `Preferences > Panels > Quick Search > When searching`: `Show all items` or `Show only matching items`.
The following screenshot shows how Quick Search filters out all items except the two that match the input query `'color'`:

![Quick search](Help-panel-quicksearch.png)

An optional key modifier can be specified so that only keypresses with the chosen modifier will be registered as input for Quick Search.
There are 5 options for the modifier in `Preferences > Panels > Quick Search > Key modifier`:

- `Opt`
- `Ctrl + Opt`
- `Shift + Opt`
- `No modifier` (default)
- `Disabled` (turns off Quick Search altogether)

The input query can be interpreted in different ways.
There are 5 options for matching filenames against it, configurable in `Preferences > Panels > Quick Search > Where to search`:

- `Fuzzy`: letters from the input query must appear anywhere in the filename, in the same order.
- `Anywhere` (default): the input query must appear as a whole anywhere in the filename.
- `Beginning`: the filename must start with the input query.
- `Ending`: the filename must end with the input query.
- `Beginning or ending`: the filename must start or end with the input query.

When filtered-out items are configured to still be shown, and a key modifier is set, it can be used to lock navigation within the matching files.
Using normal keyboard navigation (Arrows, Home, End, etc.) while holding the modifier will restrict the cursor movement to only the matching files.

## View Modes
Nimble Commander-Fork can display the contents of a panel in three modes: Brief, List, and Gallery.

- Brief mode shows only basic item information, such as the filename, icon, and tag colors, and arranges the items in consecutive columns.
  This allows more items to fit on the screen and enables the cursor to move both vertically and horizontally.
- List mode displays panel items in a table format, where each row represents a single item and each column represents an attribute.
  This mode allows only vertical cursor movement.
- Gallery mode displays items horizontally as labeled icons at the bottom of the panel, along with an interactive Quick Look preview of the currently focused item.

The screenshot below shows how the same folder, `/usr/bin`, is displayed in Brief and List modes:

![Brief and List modes](Help-panel-modes.png)

This screenshot shows Gallery mode with the other panel collapsed:

![Gallery mode](Help-panel-gallery.png)

By default, Nimble Commander-Fork has 5 preconfigured modes, which you can switch using the `View > View Mode` menu or via the hotkeys listed below:

- `Ctrl + 1` - `Short`: a Brief mode that shows 3 equal-sized columns per panel.
- `Ctrl + 2` - `Medium`: a Brief mode that uses dynamically sized columns depending on the widths of filenames.
- `Ctrl + 3` - `Full`: a List mode that shows filename, size, date created, date modified, and date added.
- `Ctrl + 4` - `Wide`: a List mode that shows two columns: filename and size.
- `Ctrl + 5` - `Gallery`: a Gallery mode that shows icons and uses two lines to display filenames.

You can fine-tune, rearrange, and add up to 10 custom panel layouts in `Preferences > Panels > Layout`.

## Flat View

Flat View lists everything underneath the current directory — files and folders from all levels — in a single panel, instead of showing just the immediate children. It is handy for working with a deep folder tree without jumping in and out of directories.

Toggle it with `View > Flat View` or the `Opt + Cmd + B` hotkey. The panel's path bar keeps showing the directory the view was flattened from, and toggling the view off — or navigating anywhere — restores the regular listing. Symbolic links to directories are listed but not followed, and the traversal is capped to keep a huge tree from locking up the panel.

## Quick Lists
Quick Lists is another mechanism in Nimble Commander-Fork for accessing specific locations with minimal keypresses, tailored for keyboard use.
It is similar to the Go To popup but provides more locations and does not mix different types of locations.
A Quick List popup is shown inside the focused panel, and its content can depend on the panel itself.
There are 6 kinds of Quick Lists, accessible via `Go > Quick Lists` or the hotkeys below:

- `Cmd + 1` - `Parent Folders`: a list of parent folders up to the root of the filesystem.
- `Cmd + 2` - `History`: a history of recent locations visited in this panel.
- `Cmd + 3` - `Favorites`: favorite and frequently visited locations.
- `Cmd + 4` - `Volumes`: currently attached system volumes.
- `Cmd + 5` - `Connections`: network locations that Nimble Commander-Fork can connect to. Clicking on a connection establishes it and navigates the panel to the default location on that remote resource.
- `Cmd + 6` - `Tags`: a list of known file tags. Clicking on a tag shows all items with the selected tag in the panel.

This screenshot shows a `Volumes` Quick List:

![Quick List](Help-panel-quicklist.png)

## Tabs
File panels support a tabbed interface, allowing multiple locations to be opened simultaneously on either the left or right pane.
The tab bar appears automatically if more than one tab is open in a pane, and can also be forced to always show via `View > Show/Hide Tab Bar` or the `Shift + Cmd + T` hotkey.
The screenshot below shows Nimble Commander-Fork's window with two tabs in the left pane and three tabs in the right pane:

![Tabbed Interface](Help-panel-tabs.png)

A new tab can be opened in several ways:

- Menu `File > New Tab` or `Cmd + T` creates a new tab with the same location.
- Clicking the `+` button next to the tab bar. A long click or right-click displays a list of recently closed locations.
- Pressing `Shift + Cmd + R` restores the last closed tab and activates it.
- `Opt + Cmd + Return` reveals the currently focused item in a new tab on the opposite pane.

To switch the active tab, use these hotkeys:

- `Shift + Cmd + ]` or `Ctrl + Tab` to switch to the next tab.
- `Shift + Cmd + [` or `Ctrl + Shift + Tab` to switch to the previous tab.
- The `File Panels > Show Tab №1..№10` hotkeys can be assigned in `Preferences > Hotkeys` to activate a specific tab.

To close tabs:

- `Cmd + W` - closes the current tab.
- `Opt + Cmd + W` - closes all other tabs.

## Favorites
Favorites is a list of frequently accessed locations, similar to those in other software. Nimble Commander-Fork provides quick access to these locations through:

- The `Go > Favorites` menu.
- Go To popups (`F1` / `F2`).
- The Favorites quick list (`Cmd + 3`).

You can manage the list of favorite locations in the Favorites window, opened via `Go > Favorites > Manage Favorites...` or `Ctrl + Cmd + B`.
To add a directory to the list, click the `+` button in this window and select a path from the drop-down list, or press `Cmd + B` (`File > Add to Favorites`).
Use the `-` button in the Favorites window to remove a location, or reset the list to the default set of locations.
A favorite location can represent any path available in the macOS filesystem or any virtual filesystem supported by Nimble Commander-Fork, such as network filesystems, archive contents, file extended attributes, or the process list.

This screenshot shows the `Favorites` window:

![Favorites Window](Help-panel-favorites.png)

## Searching for Files
To recursively search for filesystem items that meet specific criteria, use the `Find Files` dialog. Press `Cmd + F` or select `File > Find...` to open it.

![Find Files](Help-panel-findfiles.png)

This dialog allows you to search for files based on:

- **Filename Matching**: search for files whose names match a specified pattern. Both file masks and regular expressions are supported.
- **Content Search**: find files containing or not containing specific text. You can customize case sensitivity, whole-word matching, and text encoding.
- **File Size**: search for files smaller than, equal to, or larger than a specified size.

Once files are found, you can:

- Quickly view a selected file with the built-in viewer while keeping the dialog open.
- Navigate to a selected item in the file panel, which closes the dialog automatically.
- Reveal all found items in a temporary file panel (`Panelize`) for further actions, closing the dialog in the process.

# Operations

## Introduction
Nimble Commander-Fork executes file operations in the background whenever possible to ensure the user interface remains responsive.
Most operations are tied to the window where they originated, allowing you to monitor progress and pause or cancel as needed.
When file operations are in progress, they are displayed in the central part of the window, just above the file panels:

![File Operations](Help-file-operations.png)

## Copy
You can initiate copying filesystem items in several ways:

- Using `F5` or `Command > Copy To...`: opens the Copy dialog, where you can choose the destination (defaulting to the opposite panel), select which file attributes to retain, and decide whether to verify the copy (using SHA-256).
- Using `Shift + F5` or `Command > Copy As...`: pre-fills the dialog with the original item's name, allowing you to quickly duplicate the item with a new name.
- Using `Cmd + V`: if the pasteboard currently holds a filesystem path, copies that item into the active panel's folder.
- Dragging items with the mouse while holding `Opt`: copies the selected item(s) to the destination.

## Duplicate
Pressing `Cmd + D` or selecting `File > Duplicate` duplicates the selected item(s) in the active panel within their current folder.

## Move
To move items from one location to another:

- Using `F6` or `Command > Rename/Move To...`: opens the Move dialog. Similar to copying, it lets you select which file attributes to preserve when moving across filesystems and whether to verify the result (using SHA-256).
- Using `Shift + F6` or `Command > Rename/Move As...`: pre-fills the dialog with the original item's name to quickly rename or move into a subfolder.
- Using `Opt + Cmd + V`: moves the item(s) currently on the pasteboard into the active panel's folder.
- Dragging items with the mouse: moves the selected item(s) to the destination.

## Rename
To quickly rename an item in place, single-click its filename or press `Ctrl + F6` (`Command > Rename In Place`).

## Batch Rename
Nimble Commander-Fork allows you to rename multiple items at once by applying a rename pattern. Select the items you want to rename, then press `Ctrl + M` or choose `Command > Batch Rename...`:

![Batch Rename](Help-batch-rename.png)

The renaming process consists of three steps:

  1. Decomposing the original filename and constructing a new one by combining a sequence of placeholders.
  2. (Optional) Searching and replacing parts of the filename.
  3. (Optional) Transforming the letter case.

The placeholders mini-language includes the following elements:

  - Based on the original filename:
    - `[N]`: file name without extension (e.g., `example.txt` → `example`).
    - `[E]`: file extension (e.g., `example.txt` → `txt`).
    - `[A]`: full filename (e.g., `example.txt` → `example.txt`).
    - `[P]`: parent folder name (e.g., `Parent/example.txt` → `Parent`).
    - `[G]`: grandparent folder name (e.g., `Grandparent/Parent/example.txt` → `Grandparent`).
    - All these placeholders support substring slicing:
      - `[Nx]`: the **x**th character of the string.  
        `example.txt → [N4] → m`
      - `[Nx-y]`: characters from the **x**th to the **y**th position.  
        `example.txt → [N2-4] → xam`
      - `[Nx,y]`: **y** characters starting from the **x**th position.  
        `example.txt → [N5,2] → pl`
      - `[Nx-]`: characters starting from the **x**th position to the end.  
        `example.txt → [N5-] → ple`
      - `[N0x-y]`: characters from the **x**th to the **y**th position, padded with zeros.  
        `example.txt → [N05-10] → 000ple`
      - `[N x-y]`: characters from the **x**th to the **y**th position, padded with spaces.  
        `example.txt → [N 5-10] → ␣␣␣ple`
      - `[N-x,y]`: **y** characters starting from the **x**th-last position.  
        `example.txt → [N-5,3] → amp`
      - `[N-x-y]`: characters from the **x**th-last to the **y**th-last position.  
        `example.txt → [N-5-2] → ampl`
      - `[Nx--y]`: characters from the **x**th to the **y**th-last position.  
        `example.txt → [N2--2] → xampl`
      - `[N-x-]`: characters starting from the **x**th-last position to the end.  
        `example.txt → [N-4-] → mple`
  - Based on the file's modification time:
    - `[d]`: localized date (e.g., `07-12-2024`).
    - `[Y]`: year in 4-digit format (e.g., `2024`).
    - `[y]`: year in 2-digit format (e.g., `24`).
    - `[M]`: month in 2-digit format (e.g., `12`).
    - `[D]`: day in 2-digit format (e.g., `07`).
    - `[t]`: localized time (e.g., `13.58`).
    - `[h]`: hours in 2-digit, 24-hour format (e.g., `13`).
    - `[m]`: minutes in 2-digit format (e.g., `58`).
    - `[s]`: seconds in 2-digit format (e.g., `43`).
  - Based on the counter settings:
    - `[C]`: default counter; all settings are taken from the dialog.  
      `[C] → 1, 2, 3, 4, 5...`
    - `[Cx]`: counter starting at **x**.  
      `[C5] → 5, 6, 7, 8, 9...`
    - `[Cx+y]`: counter starting at **x** and incrementing by **y**.  
      `[C5+5] → 5, 10, 15, 20, 25...`
    - `[Cx+y/z]`: counter starting at **x**, incrementing by **y**, and grouping every **z** items.  
      `[C5+5/2] → 5, 5, 10, 10, 15...`
    - `[Cx+y/z:w]`: counter starting at **x**, incrementing by **y**, grouping every **z** items, and padding to **w** digits.  
      `[C5+5/2:3] → 005, 005, 010, 010, 015...`
    - Custom settings are optional and can be omitted. For instance, `[C:w]` or `[C+y:w]` are valid.
  - Capitalization commands:
    - `[U]`: converts the following text to UPPERCASE.
    - `[L]`: converts the following text to lowercase.
    - `[F]`: capitalizes the first letter of each word in the following text.
    - `[n]`: resets capitalization; the following text retains its original case.
  - Other placeholders:
    - `[[`: inserts an opening square bracket (`[`).
    - `]]`: inserts a closing square bracket (`]`).

The Rename Dialog provides a live preview of how the renamed list of files will look.
No renaming takes place until you click `OK` or press `Cmd + Return`.

## Delete & Trash
Nimble Commander-Fork lets you move items to the Trash or delete them permanently:

- Press `Cmd + Backward Delete` (`Command > Move To Trash`) to move selected items to the Trash. If the current volume doesn't support a Trash folder, a Delete confirmation dialog appears instead.
- Press `F8` (`Command > Delete...`) or `Shift + F8` (`Command > Delete Permanently...`) to open the Delete dialog, where the default action differs between moving to Trash and permanent deletion. In context menus, holding `Opt` reveals **Delete Permanently** highlighted in red.
- Open the Trash folder with `Go > Trash`, restore trashed items with `Command > Put Back`, or empty the Trash with `Command > Empty Trash…` (which intentionally has no keyboard shortcut to prevent accidental triggers).

## Create Folder
There are two ways to create a folder in Nimble Commander-Fork:

- Using `F7` (`Command > Create Directory...`): opens the Create Directory dialog, where you can specify the folder name (including nested paths such as `New 1/New 2/New 3`) before creating it. Use `Shift + F7` (`Command > Create Directory In Opposite Panel...`) to create the folder in the opposite panel.
- Using `Shift + Cmd + N` (`File > New Folder`): creates a new empty folder with a temporary name and opens an in-place rename editor immediately.

## Create File
Press `Opt + Cmd + N` or select `File > New File` to create a new empty file with a temporary name and rename it in place immediately.

## Change Attributes
You can change an item's attributes using `Ctrl + A` or `Command > File Attributes`:

![Attributes](Help-attr-change.png)

This dialog displays permissions, flags, ownership, and timestamps, and supports editing multiple items simultaneously (differences across selected items appear as indeterminate checkboxes).
If any selected item is a folder, you can apply changes recursively to all nested items.
Changing certain attributes requires administrator rights and needs Admin Mode enabled.

## Compress
Nimble Commander-Fork includes a built-in compression tool that supports **ZIP**, **7z**, and **tar** containers. Configure the format, compression method, and level in `Preferences > Compression`. Only ZIP supports password protection (AES-256) — the password controls are disabled for other formats.

- Press `F9` (`Command > Compress...`) to create an archive in the active panel's folder.
- Press `Shift + F9` (`Command > Compress To...`) to place the archive in the opposite panel's folder.

## Manage Links
You can create hard links and create or edit symbolic links via `Command > Links` (no default hotkeys):

- `Create Hard Link`
- `Create Symbolic Link`
- `Edit Symbolic Link`

# Virtual File Systems
In addition to browsing the native macOS filesystem, Nimble Commander-Fork lets you interact with other resources as if they were normal folders.
Most operations — browsing, searching, viewing, and modifying (where writable) — work seamlessly with these virtual filesystems (VFS).
Opening a file stored on a VFS with an external application copies it to a temporary location first (automatically for small files, with confirmation for larger files).
When a file on a writable VFS is modified in an external editor, Nimble Commander-Fork automatically uploads the changes back to the underlying VFS.

Currently supported virtual filesystems:

- **Archives and Compressed files**  
  Supported formats include `ar`, `bz2`, `bzip2`, `cab`, `cpgz`, `cpio`, `gz`, `gzip`, `iso`, `jar`, `lha`, `lz`, `lzma`, `lzo`, `lz4`, `mtree`, `pax`, `rar`, `tar`, `xar`, `xz`, `z`, `zip`, `zst`, and `7z`.
  Archives are opened read-only; paths inside an archive include a prefix derived from the archive's path.
  For full RAR support (solid archives, encrypted headers/payloads, and multi-volume sets), you can install the optional `ncrar-helper` component and manage it in `Preferences > Compression` — see [RarSupport.md](RarSupport.md).
- **Network protocols**
  - **FTP**: connects to FTP servers (`ftp://` prefix).
  - **SFTP**: connects over SSH using the SSH File Transfer Protocol (`sftp://` prefix).
  - **WebDAV**: connects to WebDAV servers (`http://` or `https://` prefix).
  - **Network Share**: mounts SMB/AFP/NFS network shares via macOS NetFS.
- **Extended attributes**  
  Open an item's [extended attributes (xattrs)](https://en.wikipedia.org/wiki/Extended_file_attributes#macOS) (`Opt + Cmd + X` or `Command > Open Extended Attributes`) as a read-write folder and manipulate attributes like regular files.
- **Process list**  
  Displays running processes (`Opt + Cmd + P` or `Go > Processes List`) as files containing process details. Deleting a file in this VFS terminates the corresponding process.

# External Editors
Configure a list of editor applications under `Preferences > Editors`.
Press `F4` or select `Command > External Editor` to open the currently focused file with the matching editor based on its filename mask/extension.
External editors can run either as standalone macOS applications or as command-line tools inside Nimble Commander-Fork's built-in terminal emulator.

# Tools
Similar to external editors, tools let you define external applications or commands with full control over startup parameters.
Tools can be assigned custom hotkeys and placed on the toolbar. Configure them under `Preferences > Tools`.

To execute a tool:

- Press its assigned hotkey.
- Click its icon in the toolbar.
- Select it from `Command > Tools`.

External tools can only be executed when a panel points to a native macOS filesystem location (VFS locations are not supported).

Tools run in one of two modes depending on `Startup Mode`:

- `Run Detached`: launches the tool as a standalone macOS application.
- `Run in Terminal`: executes the tool inside Nimble Commander-Fork's built-in terminal emulator.

Supported parameter placeholders:

- Insert the focused item:
  - From the source (current) panel:
    - `%p`: item's path.
    - `%f`: item's filename.
    - `%n`: item's filename without the extension.
    - `%e`: item's extension.
    - `%r`: panel's path.
  - From the target (opposite) panel:
    - `%-p`: item's path.
    - `%-f`: item's filename.
    - `%-n`: item's filename without the extension.
    - `%-e`: item's extension.
    - `%-r`: panel's path.
- Insert the selected items:
  - From the source (current) panel:
    - `%P`: file paths as parameters.
    - `%xP`: file paths as parameters, limited to **x** files.
    - `%LP`: file paths in a temporary text file.
    - `%xLP`: file paths in a temporary text file, limited to **x** files.
    - `%F`: filenames as parameters.
    - `%xF`: filenames as parameters, limited to **x** files.
    - `%LF`: filenames in a temporary text file.
    - `%xLF`: filenames in a temporary text file, limited to **x** files.
  - From the target (opposite) panel:
    - `%-P`: file paths as parameters.
    - `%-xP`: file paths as parameters, limited to **x** files.
    - `%-LP`: file paths in a temporary text file.
    - `%-xLP`: file paths in a temporary text file, limited to **x** files.
    - `%-F`: filenames as parameters.
    - `%-xF`: filenames as parameters, limited to **x** files.
    - `%-LF`: filenames in a temporary text file.
    - `%-xLF`: filenames in a temporary text file, limited to **x** files.
- Ask for a value when executed:
  - `%?`: prompts for the parameter value.
  - `%"message"?`: prompts for the parameter value with a custom **message**.
- Other placeholders:
  - `%%`: inserts a literal `%` character.
  - `%-`: switches between source/target panels and left/right panels.
  - `%xT`: limits the total number of files passed to the tool to **x**.

# Integrated Viewer
Nimble Commander-Fork features a built-in viewer that lets you examine files without leaving the application:

![Integrated Viewer](Help-intergrated-viewer.png)

The viewer works with both native and virtual filesystems (for example, viewing files inside archives without unpacking them first).
For large files, it loads only a small window of data at a time to keep memory usage minimal.
If a file changes on disk while open, the viewer refreshes automatically; when positioned at the tail of an actively growing file (such as a log), it scrolls automatically to follow new data.

The built-in viewer supports three modes:

- **Text Mode (`Cmd + 1`)**: displays file contents as text using the selected encoding, with syntax highlighting based on the file extension.
- **Hex Mode (`Cmd + 2`)**: displays file contents in 16-byte rows showing offsets, two 8-byte hex blocks, and decoded text.
- **Preview Mode (`Cmd + 3`)**: renders the file using Quick Look.

The viewer can open embedded inside the active window (replacing the file panels) or as a separate floating window (configurable in `Preferences > Viewer`).
Open it with `F3` (`Command > Internal Viewer`) and close it with `Esc`.

# Integrated Terminal
Nimble Commander-Fork includes a built-in terminal emulator supporting most VT100 sequences, 256 colors, and mouse input:

![Terminal Emulator](Help-terminal.png)

The terminal is context-aware and synchronizes the active panel's folder with the shell's working directory bi-directionally: running `cd` in the terminal updates the panel, and navigating in the panel updates the terminal.
Supported shells include `bash`, `zsh`, `csh`, and `tcsh`.

There are two ways to use the terminal emulator:

- **Full-Window Mode**: occupies the entire window, hiding the file panels. Toggle with `Opt + Cmd + O` or `View > Show/Hide Terminal`.
- **Overlapped Mode**: sits underneath the file panels so both stay visible. Reveal it with `Ctrl + Opt + Up`, hide it with `Ctrl + Opt + Down`, or toggle full panel visibility with `Ctrl + Opt + O`. You can optionally redirect keyboard input to the overlapped terminal even when unfocused in `Preferences > Panels > Behavior`.

# Hotkeys
Below are the default hotkeys, all customizable in `Preferences > Hotkeys`.
Up to four hotkeys ("key equivalents") can be assigned to a single action.
Actions with an empty key column have no default hotkey and can be invoked from the menu bar or bound manually.

| Action                                       | Key Equivalent            |
| -------------------------------------------- | ------------------------- |
| _**Nimble Commander-Fork Menu**_             |                           |
| &nbsp; About Nimble Commander-Fork           |                           |
| &nbsp; Preferences…                          | Cmd + ,                   |
| &nbsp; Turn Admin Mode On / Off              |                           |
| &nbsp; Hide Nimble Commander-Fork            | Cmd + H                   |
| &nbsp; Hide Others                           | Opt + Cmd + H             |
| &nbsp; Show All                              |                           |
| &nbsp; Quit Nimble Commander-Fork            | Cmd + Q                   |
| _**File Menu**_                              |                           |
| &nbsp; New Window                            | Cmd + N                   |
| &nbsp; New Folder                            | Shift + Cmd + N           |
| &nbsp; New Folder with Selection             | Ctrl + Cmd + N            |
| &nbsp; New File                              | Opt + Cmd + N             |
| &nbsp; New Tab                               | Cmd + T                   |
| &nbsp; Enter                                 | Return                    |
| &nbsp; Open                                  | Shift + Return            |
| &nbsp; Reveal In Opposite Panel              | Opt + Return              |
| &nbsp; Reveal In Opposite Panel Tab          | Opt + Cmd + Return        |
| &nbsp; Paste Filename to Terminal            | Ctrl + Opt + Return       |
| &nbsp; Paste Filenames to Terminal...        | Ctrl + Opt + Cmd + Return |
| &nbsp; Calculate Folders Sizes               | Shift + Opt + Return      |
| &nbsp; Calculate All Folders Sizes           | Ctrl + Shift + Return     |
| &nbsp; Duplicate                             | Cmd + D                   |
| &nbsp; Add to Favorites                      | Cmd + B                   |
| &nbsp; Close                                 | Cmd + W                   |
| &nbsp; Close Window                          | Shift + Cmd + W           |
| &nbsp; Close Other Tabs                      | Opt + Cmd + W             |
| &nbsp; Find...                               | Cmd + F                   |
| &nbsp; Find Next                             | Cmd + G                   |
| &nbsp; Find with Spotlight...                | Opt + Cmd + F             |
| _**Edit Menu**_                              |                           |
| &nbsp; Copy                                  | Cmd + C                   |
| &nbsp; Paste                                 | Cmd + V                   |
| &nbsp; Move Item Here                        | Opt + Cmd + V             |
| &nbsp; Select All                            | Cmd + A                   |
| &nbsp; Deselect All                          | Opt + Cmd + A             |
| &nbsp; Invert Selection                      | Ctrl + Cmd + A            |
| _**View Menu**_                              |                           |
| &nbsp; Switch Dual/Single Pane               | Shift + Cmd + P           |
| &nbsp; Swap Panels                           | Cmd + U                   |
| &nbsp; Sync Panels                           | Opt + Cmd + U             |
| &nbsp; Refresh                               | Cmd + R                   |
| &nbsp; _**View Mode Submenu**_               |                           |
| &nbsp; &nbsp; Toggle Short View Mode         | Ctrl + 1                  |
| &nbsp; &nbsp; Toggle Medium View Mode        | Ctrl + 2                  |
| &nbsp; &nbsp; Toggle Full View Mode          | Ctrl + 3                  |
| &nbsp; &nbsp; Toggle Wide View Mode          | Ctrl + 4                  |
| &nbsp; &nbsp; Toggle Gallery View Mode       | Ctrl + 5                  |
| &nbsp; &nbsp; Toggle View Mode VI            | Ctrl + 6                  |
| &nbsp; &nbsp; Toggle View Mode VII           | Ctrl + 7                  |
| &nbsp; &nbsp; Toggle View Mode VIII          | Ctrl + 8                  |
| &nbsp; &nbsp; Toggle View Mode IX            | Ctrl + 9                  |
| &nbsp; &nbsp; Toggle View Mode X             | Ctrl + 0                  |
| &nbsp; _**Sorting Submenu**_                 |                           |
| &nbsp; &nbsp; Sort by Name                   | Ctrl + Cmd + 1            |
| &nbsp; &nbsp; Sort by Extension              | Ctrl + Cmd + 2            |
| &nbsp; &nbsp; Sort by Modified Time          | Ctrl + Cmd + 3            |
| &nbsp; &nbsp; Sort by Size                   | Ctrl + Cmd + 4            |
| &nbsp; &nbsp; Sort by Creation Time          | Ctrl + Cmd + 5            |
| &nbsp; &nbsp; Sort by Added Time             | Ctrl + Cmd + 6            |
| &nbsp; &nbsp; Sort by Accessed Time          | Ctrl + Cmd + 7            |
| &nbsp; &nbsp; Separate Folders from Files    |                           |
| &nbsp; &nbsp; Extensionless Folders          |                           |
| &nbsp; &nbsp; Natural Comparison             |                           |
| &nbsp; &nbsp; Case-Insensitive Comparison    |                           |
| &nbsp; &nbsp; Case-Sensitive Comparison      |                           |
| &nbsp; Show Hidden Files                     | Shift + Cmd + .           |
| &nbsp; Flat View                             | Opt + Cmd + B             |
| &nbsp; _**Panels Position Submenu**_         |                           |
| &nbsp; &nbsp; Move Left                      | Ctrl + Opt + Left         |
| &nbsp; &nbsp; Move Right                     | Ctrl + Opt + Right        |
| &nbsp; &nbsp; Move Up                        | Ctrl + Opt + Up           |
| &nbsp; &nbsp; Move Down                      | Ctrl + Opt + Down         |
| &nbsp; &nbsp; Show/Hide Panels               | Ctrl + Opt + O            |
| &nbsp; &nbsp; Focus Overlapped Terminal      | Ctrl + Opt + Tab          |
| &nbsp; Show/Hide Tab Bar                     | Shift + Cmd + T           |
| &nbsp; Show/Hide Toolbar                     | Opt + Cmd + T             |
| &nbsp; Show/Hide Terminal                    | Opt + Cmd + O             |
| _**Go Menu**_                                |                           |
| &nbsp; Left Panel...                         | F1                        |
| &nbsp; Right Panel...                        | F2                        |
| &nbsp; Back                                  | Cmd + [                   |
| &nbsp; Forward                               | Cmd + ]                   |
| &nbsp; Enclosing Folder                      | Cmd + Up                  |
| &nbsp; Into Folder                           | Cmd + Down                |
| &nbsp; Follow Symlink                        | Cmd + Right               |
| &nbsp; Documents                             | Shift + Cmd + O           |
| &nbsp; Desktop                               | Shift + Cmd + D           |
| &nbsp; Downloads                             | Opt + Cmd + L             |
| &nbsp; Home                                  | Shift + Cmd + H           |
| &nbsp; Trash                                 |                           |
| &nbsp; Library                               |                           |
| &nbsp; Applications                          | Shift + Cmd + A           |
| &nbsp; Utilities                             | Shift + Cmd + U           |
| &nbsp; Root                                  |                           |
| &nbsp; Processes List                        | Opt + Cmd + P             |
| &nbsp; _**Favorites Submenu**_               |                           |
| &nbsp; &nbsp; Manage Favorites...            | Ctrl + Cmd + B            |
| &nbsp; _**Recently Closed Submenu**_         |                           |
| &nbsp; &nbsp; Restore Closed Tab             | Shift + Cmd + R           |
| &nbsp; _**Quick Lists Submenu**_             |                           |
| &nbsp; &nbsp; Parent Folders                 | Cmd + 1                   |
| &nbsp; &nbsp; History                        | Cmd + 2                   |
| &nbsp; &nbsp; Favorites                      | Cmd + 3                   |
| &nbsp; &nbsp; Volumes                        | Cmd + 4                   |
| &nbsp; &nbsp; Connections                    | Cmd + 5                   |
| &nbsp; &nbsp; Tags                           | Cmd + 6                   |
| &nbsp; Go To Folder...                       | Shift + Cmd + G           |
| &nbsp; _**Connect To Submenu**_              |                           |
| &nbsp; &nbsp; FTP Server...                  |                           |
| &nbsp; &nbsp; SFTP Server...                 |                           |
| &nbsp; &nbsp; WebDAV Server...               |                           |
| &nbsp; &nbsp; Network Share...               |                           |
| &nbsp; &nbsp; Manage Connections...          | Cmd + K                   |
| _**Command Menu**_                           |                           |
| &nbsp; Brief System Overview                 | Cmd + L                   |
| &nbsp; Detailed Volume Information           |                           |
| &nbsp; File Attributes                       | Ctrl + A                  |
| &nbsp; Open Extended Attributes              | Opt + Cmd + X             |
| &nbsp; Copy Item Name                        | Shift + Cmd + C           |
| &nbsp; Copy Item Path                        | Opt + Cmd + C             |
| &nbsp; Copy Item Directory                   | Shift + Opt + Cmd + C     |
| &nbsp; Select by Mask...                     | Cmd + =                   |
| &nbsp; Select by Extension                   | Opt + Cmd + =             |
| &nbsp; Deselect by Mask...                   | Cmd + -                   |
| &nbsp; Deselect by Extension                 | Opt + Cmd + -             |
| &nbsp; Preview                               | Cmd + Y                   |
| &nbsp; Internal Viewer                       | F3                        |
| &nbsp; External Editor                       | F4                        |
| &nbsp; Eject Volume                          | Cmd + E                   |
| &nbsp; Batch Rename...                       | Ctrl + M                  |
| &nbsp; Copy To...                            | F5                        |
| &nbsp; Copy As...                            | Shift + F5                |
| &nbsp; Rename/Move To...                     | F6                        |
| &nbsp; Rename/Move As...                     | Shift + F6                |
| &nbsp; Rename In Place                       | Ctrl + F6                 |
| &nbsp; Create Directory...                   | F7                        |
| &nbsp; Create Directory In Opposite Panel... | Shift + F7                |
| &nbsp; Move To Trash                         | Cmd + Backward Delete     |
| &nbsp; Put Back                              |                           |
| &nbsp; Empty Trash…                          |                           |
| &nbsp; Delete...                             | F8                        |
| &nbsp; Delete Permanently...                 | Shift + F8                |
| &nbsp; Compress...                           | F9                        |
| &nbsp; Compress To...                        | Shift + F9                |
| &nbsp; _**Links Submenu**_                   |                           |
| &nbsp; &nbsp; Create Hard Link               |                           |
| &nbsp; &nbsp; Create Symbolic Link           |                           |
| &nbsp; &nbsp; Edit Symbolic Link             |                           |
| _**Window Menu**_                            |                           |
| &nbsp; Minimize                              | Cmd + M                   |
| &nbsp; Enter Full Screen                     | Ctrl + Cmd + F            |
| &nbsp; Zoom                                  |                           |
| &nbsp; Show Previous Tab                     | Shift + Ctrl + Tab        |
| &nbsp; Show Next Tab                         | Ctrl + Tab                |
| &nbsp; Bring All to Front                    |                           |
| _**Special Hotkeys**_                        |                           |
| &nbsp; _**File Panels**_                     |                           |
| &nbsp; &nbsp; Move Up                        | Up                        |
| &nbsp; &nbsp; Move Down                      | Down                      |
| &nbsp; &nbsp; Move Left                      | Left                      |
| &nbsp; &nbsp; Move Right                     | Right                     |
| &nbsp; &nbsp; Move to the First Element      | Home                      |
| &nbsp; &nbsp; Scroll to the First Element    | Opt + Home                |
| &nbsp; &nbsp; Move to the Last Element       | End                       |
| &nbsp; &nbsp; Scroll to the Last Element     | Opt + End                 |
| &nbsp; &nbsp; Move to the Next Page          | Page Down                 |
| &nbsp; &nbsp; Scroll to the Next Page        | Opt + Page Down           |
| &nbsp; &nbsp; Move to the Previous Page      | Page Up                   |
| &nbsp; &nbsp; Scroll to the Previous Page    | Opt + Page Up             |
| &nbsp; &nbsp; Toggle Selection               |                           |
| &nbsp; &nbsp; Toggle Selection and Move Down | Enter (Fn + Return)       |
| &nbsp; &nbsp; Change Active Panel            | Tab                       |
| &nbsp; &nbsp; Previous Tab                   | Shift + Cmd + [           |
| &nbsp; &nbsp; Next Tab                       | Shift + Cmd + ]           |
| &nbsp; &nbsp; Go into Enclosing Folder       | Backward Delete           |
| &nbsp; &nbsp; Go into Folder                 |                           |
| &nbsp; &nbsp; Go to Home Folder              | Shift + ~                 |
| &nbsp; &nbsp; Go to Root Folder              | /                         |
| &nbsp; &nbsp; Show Preview                   | Space                     |
| &nbsp; &nbsp; Show Tab №1..№10               |                           |
| &nbsp; &nbsp; Focus Left Panel               | Shift + Cmd + Left        |
| &nbsp; &nbsp; Focus Right Panel              | Shift + Cmd + Right       |
| &nbsp; &nbsp; Show Context Menu              | Ctrl + Return             |
| &nbsp; _**Viewer**_                          |                           |
| &nbsp; &nbsp; Toggle Text                    | Cmd + 1                   |
| &nbsp; &nbsp; Toggle Hex                     | Cmd + 2                   |
| &nbsp; &nbsp; Toggle Preview                 | Cmd + 3                   |
| &nbsp; &nbsp; Show GoTo                      | Cmd + L                   |
| &nbsp; &nbsp; Refresh                        | Cmd + R                   |

# Frequently Asked Questions

**Q**: I have an idea for Nimble Commander-Fork!  
**A**: Feel free to open a discussion or pull request in [the repository](https://github.com/cfanmaoli/nimble-commander).
Be sure to read [CONTRIBUTING.md](https://github.com/cfanmaoli/nimble-commander/blob/main/CONTRIBUTING.md) before submitting changes.

---

**Q**: Can you implement a specific feature or request?  
**A**: Maintainer time is limited, so not every feature request can be prioritized immediately.
Well-tested pull requests from the community are welcome — see [CONTRIBUTING.md](https://github.com/cfanmaoli/nimble-commander/blob/main/CONTRIBUTING.md).

---

**Q**: Nimble Commander-Fork crashes or behaves unexpectedly. Can you fix it?  
**A**: Please open an issue with your macOS version, app build number, and clear reproduction steps (plus crash report or logs if available). That makes diagnosing and fixing the problem much faster.

---

**Q**: Preview lacks a feature XYZ, is it possible to add it?  
**A**: Preview rendering is managed by macOS through the [Quick Look framework](https://en.wikipedia.org/wiki/Quick_Look).
Rendering and behavior for individual file types depend on the Quick Look extensions installed on macOS, so Nimble Commander-Fork has limited control over it.

---

**Q**: Can Nimble Commander-Fork access iCloud storage?  
**A**: Nimble Commander-Fork does not provide dedicated CloudKit/iCloud integration, but you can navigate directly to `~/Library/Mobile Documents/com~apple~CloudDocs` and work with files there through the normal panel UI.

---

**Q**: Does Nimble Commander-Fork 2.0 run on Intel Macs or macOS 12 Monterey?  
**A**: No. Starting with version 2.0, Nimble Commander-Fork requires an Apple Silicon (`arm64`) Mac running macOS 13 Ventura or newer. If you need Intel (`x64`) or macOS 12 support, use version 1.9.3c from [GitHub Releases](https://github.com/cfanmaoli/nimble-commander/releases).

---

**Q**: How can I download a previous version?  
**A**: Previous stable releases are available on [GitHub Releases](https://github.com/cfanmaoli/nimble-commander/releases). You can also check out any git tag and build from source — see [Building.md](Building.md).

---

**Q**: Do you plan to add capabilities to modify existing archives?  
**A**: There are no plans to add in-place archive modification at the moment unless someone steps up to implement it.

---

**Q**: How can I make Nimble Commander-Fork restore the state of its windows after restarting?  
**A**: Turn off `System Settings > Desktop & Dock > Close windows when quitting an application`.

---

**Q**: Can I see hidden files and folders (such as `.git` or `.folder`)?  
**A**: Yes. Toggle hidden items via `View > Show Hidden Files` or press `Shift + Cmd + .`.

---

**Q**: Can I open an archive that has a non-standard extension (for example, `.xlsx`, `.pak`, etc.)?  
**A**: Yes. Select `Go > Into Folder` or press `Cmd + Down`.

---

**Q**: Do dialogs in Nimble Commander-Fork have hotkeys?  
**A**: Yes, many dialog controls have hotkeys using the `Ctrl` (`^`) modifier. Hovering the mouse cursor over a control displays a tooltip showing its shortcut when available.

---

**Q**: Where does Nimble Commander-Fork store its state?  
**A**: In these locations:

- Main configuration files (managed by NC):  
  `~/Library/Application Support/Nimble Commander-Fork/Config`
- Volatile state file (managed by NC):  
  `~/Library/Application Support/Nimble Commander-Fork/State`
- Windows state (managed by macOS):  
  `~/Library/Saved Application State/info.filesmanager.Files.savedState`
- Application defaults (managed by macOS):  
  `~/Library/Preferences/info.filesmanager.Files.plist`
- Admin Mode helper daemon (managed by macOS via `SMAppService`):  
  embedded inside the application bundle (`Contents/Library/LaunchDaemons/info.filesmanager.Files.PrivilegedIOHelperV3.plist` and `Contents/Library/LaunchServices/info.filesmanager.Files.PrivilegedIOHelperV3`) and controlled in `System Settings > General > Login Items & Extensions`

---

**Q**: Why does Nimble Commander-Fork keep switching back from the theme I selected?  
**A**: Most likely, automatic theme switching is enabled and switches themes whenever macOS changes between Light and Dark appearance (or when the app restarts).
You can change or disable this under `Preferences > Themes > (...) > Configure automatic switching...`.

---

**Q**: Where can I find the logs?  
**A**: Hold `Opt` and select `Help > Debug > Show Logs...`.
Click the settings (gear) icon in the Logs window to choose the desired log level per subsystem or globally. By default, logging is set to `Off`.
