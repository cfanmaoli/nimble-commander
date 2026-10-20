[![Build and Test](https://github.com/mikekazakov/nimble-commander/actions/workflows/build.yml/badge.svg?branch=main)](https://github.com/mikekazakov/nimble-commander/actions/workflows/build.yml)
[![Nightly Build](https://github.com/mikekazakov/nimble-commander/actions/workflows/nightly.yml/badge.svg?branch=main)](https://github.com/mikekazakov/nimble-commander/actions/workflows/nightly.yml)

# Nimble Commander

> **This fork adds language packs.** A *Preferences → Language* tab exports the interface strings of
> the current language as JSON, imports a translation back, and switches between the built-in
> languages and any imported pack — so a language the app does not ship can be translated with an AI
> in a few minutes, without Xcode, a rebuild or a re-sign. See
> **[Tools/language-packs.md](Tools/language-packs.md)** for how it works and what it deliberately
> does not touch. The feature was offered upstream in
> [#746](https://github.com/mikekazakov/nimble-commander/issues/746) and not merged there, so it is
> not a pull-request candidate; everything else in this fork tracks upstream `main`.

![](Docs/nc.png)
Nimble Commander is a free dual-pane file manager for macOS, designed with a focus on speed, keyboard-based navigation, and flexibility.  
The project's aim is to blend the user experience of classic file managers from the '80s-'90s with the modern look and feel of Mac computers.  
Visit the project's website at: https://magnumbytes.com.  

# Getting Nimble Commander

## Nightly Builds
You can download the latest nightly build of the app from [GitHub Actions](https://github.com/mikekazakov/nimble-commander/actions/workflows/nightly.yml).  
Go to the most recent integration and select the `nimble-commander-nightly` in the `Artifacts` section (a GitHub account is required).

## Current Release
Direct download link: https://magnumbytes.com/downloads/releases/nimble-commander.dmg.  
Available on Mac App Store: https://itunes.apple.com/app/files-lite/id905202937?ls=1&mt=12.  
Install via Homebrew: `brew install nimble-commander`.  

## Past Releases
Access all previous releases at https://github.com/mikekazakov/nimble-commander-releases. 

# Documentation
The user guide can be found here: [Help.md](Docs/Help.md).

# Changelog
Details about each released version can be found in the [WHATS_NEW.md](WHATS_NEW.md) file.

# Building from Source
For build instructions and an overview of the source code, please refer to the [Building.md](Docs/Building.md) document.

# Contributing to the Project
Your contributions are welcome and greatly appreciated! For guidelines on how to contribute, including reporting bugs, suggesting features, and submitting code changes, please see the [CONTRIBUTING.md](CONTRIBUTING.md) file.

# License
Copyright (C) 2013-2026 Michael Kazakov (mike.kazakov@gmail.com)  
The source code is distributed under GNU General Public License version 3.
