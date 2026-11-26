# MeldMac

MeldMac is an independent file and folder comparison app for Apple Silicon. Its native interface uses SwiftUI and AppKit. The matching algorithm from Meld 3.24.1 determines which lines and characters differ.

## Install on macOS

Requires an Apple Silicon Mac running macOS 14 or later and Python 3 from the Xcode Command Line Tools. If you need the tools, run `xcode-select --install`.

1. [Download the v0.1.0 DMG](https://github.com/melichron/meld-macos-silicon-native/releases/download/v0.1.0/MeldMac-0.1.0-arm64.dmg) or get a newer DMG from the [latest release](https://github.com/melichron/meld-macos-silicon-native/releases/latest).
2. Open the DMG and drag **MeldMac** onto the **Applications** shortcut.
3. Eject the disk image and open **MeldMac** from **Applications**.

## Build and run

You need macOS 14 or later and Xcode Command Line Tools with Swift and Python 3. From the project directory, run:

```sh
./build.sh
open MeldMac.app
```

To open two files or two folders directly, pass their paths at launch:

```sh
open -n MeldMac.app --args "/path/to/left" "/path/to/right"
```

## Recent comparisons and appearance

The start screen lists up to 20 recent pairs. Each launch adds only the first pair you successfully open. Opening that pair first on a later launch moves it to the top. Press **⌘N** to return to the list and **⌘W** to close the active tab. The theme selector applies to all windows and remembers your choice.

## Compare folders

Matching entries appear in gray, changed entries in blue, and entries present on only one side in green. By default, the scan skips entries named `.git` at every directory level. Enable the `.git` checkbox to include them for the current pair.

Click a filename to compare its two versions in a separate tab. Click the arrow on a green file row to copy the whole file to the missing side. This writes the file to disk immediately.

## Compare and edit text

You can edit either pane. After a short pause in typing, the app updates the changed blocks and highlights differences within lines. The editors scroll together by matching block. When you scroll through a one-sided insertion, the other pane stays at the corresponding insertion point.

Colored ribbons connect the edges of corresponding blocks and taper to a point for insertions and deletions. Use the block menu to jump to a difference in both panes, or switch to the block view to see aligned rows.

Place the caret in a changed block to show a copy arrow on the ribbon beside that line. Clicking it copies the entire block from the active pane to the other pane **in memory**. Press **⌘S** to save or **⌘Z** to undo. The editor supports UTF-8 files up to 4 MB, with one consistent line-ending style per file.

## License and credits

MeldMac's code is licensed under GPL-2.0-or-later. See [LICENSE](LICENSE) for the license text and [NOTICE](NOTICE) for the original Meld module and its authors. The application bundle includes both files. When distributing a binary release, provide the corresponding source code, including the build script.

The application icon uses the original Meld artwork by the GNOME Design Team, converted to the macOS icon format under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/). The [original SVG](Resources/Meld.svg) is included in this repository.
