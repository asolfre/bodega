# Bodega

A small native macOS app (SwiftUI) for Homebrew. It lists what brew has installed and runs brew for you:
install, update, uninstall, pin, clean up and update all. Every action is a plain `brew` command; Bodega
changes nothing that brew itself would not.

## Requirements

- macOS 14 or later (tested on Apple silicon only)
- Swift 5.9+ (Command Line Tools are enough; Xcode is not needed)
- Homebrew in `/opt/homebrew` or `/usr/local`

## Build and install

```sh
./build.sh            # builds build.noindex/Bodega.app
./build.sh --install  # also copies it to ~/Applications (Spotlight finds that copy only)
```

The SwiftPM build folder lives in `$TMPDIR/bodega-build`, outside Google Drive. The app is signed ad hoc,
so it runs on this Mac but is not set up for distribution.

## What it does

| Feature | brew command |
|---|---|
| Installed list (version in use first, older versions grey) | `brew list --versions`, the `$(brew --prefix)/opt` links |
| Outdated, pinned, untrusted-tap labels | `brew outdated --json=v2`, `brew list --pinned`, `brew trust --json=v1` |
| Search and install | `brew search --formula/--cask`, `brew install` |
| Update one package / Update all | `brew upgrade [name]`, after `brew upgrade --dry-run` |
| Uninstall, pin, unpin | `brew uninstall`, `brew pin`, `brew unpin` |
| Clean up | `brew cleanup`, after `brew cleanup -n` |
| Cancel a running action | SIGINT to brew, same as Ctrl-C |

Before an update, Bodega shows what brew would really do: the packages you asked for, dependencies it
would upgrade or install, packages that use it and would be upgraded too, deprecated packages, brew's
one-line warnings (e.g. "pkgconf would be reinstalled due to macOS version mismatch"), and which
formulae would **compile from source**. brew's own dry run only lists source builds for the packages
you asked for; Bodega checks every formula involved (an official-tap formula with no bottle for this
Mac compiles). A single update with nothing else to it starts straight away.

Every action and each line brew prints is written with a timestamp to `~/Library/Logs/Bodega.log`.
At launch, a log over 5 MB becomes `Bodega.log.1` and a new one starts.

## Checks

```sh
swift test --scratch-path "$TMPDIR/bodega-build"   # unit tests for everything that parses brew output
```

`parity.sh` compares what the app shows with the brew CLI: packages and versions, outdated, active
versions, pinned and untrusted taps. Start the app with a dump file, then run it:

```sh
open -n build.noindex/Bodega.app --env BODEGA_DUMP=/tmp/ui.tsv
./parity.sh /tmp/ui.tsv     # expect five "MATCH" lines
```

### Driving the UI

These need **Accessibility** (and **Screen Recording** for screenshots) for the app that runs them.

- `ui.js` clicks and reads controls by their accessibility id:
  `osascript -l JavaScript ui.js click update-jq`, `type search-field tree submit`, `read status`,
  `wait <id> [sec]`, `dialog <button>`, `sheet-text`, `sheet-ids`, `enabled <id>`.
- `shot.sh out.png` captures the Bodega window, on any display.
- `fake-brew.sh` stands in for brew so confirmations can be tested safely. A real `cleanup` or
  `upgrade` is only written to `$TMPDIR/bodega/fake-actions.log`; everything else goes to real brew.
  Copy it out of Google Drive first, then start the app with it:

  ```sh
  cp fake-brew.sh "$TMPDIR/bodega/fake-brew.sh"
  open -n build.noindex/Bodega.app --env BODEGA_BREW="$TMPDIR/bodega/fake-brew.sh"
  ```

## Versions

`VERSION` in `build.sh` sets the version; the build number is the git commit count. Releases are git
tags: `v0.1.0` (list, update, uninstall, install), `v0.2.0` (search, pin, cleanup, update all, cancel,
live log), `v0.2.1` (source builds found for every dependency, `brew --prefix`, log rotation, this README),
`v0.2.2` (dependents, deprecated packages and brew's warnings in the update sheet; wording for any macOS).

## Known limits

- **Source builds.** A formula with no bottle for this Mac compiles from source, which can take hours.
  That was most updates on macOS 14 (Homebrew Tier 3, no new bottles); on current macOS it is rare.
  Bodega asks brew for this Mac's bottle tag at every launch, warns before such an update starts,
  and Cancel stops it.
- **Untrusted taps.** brew refuses to load formulae from taps you have not trusted (`brew trust`).
  Bodega labels them; actions on them show brew's error.
- **Casks** with `auto_updates` or `version :latest` are not in Update all (no `--greedy`).
- Not included: taps, services, `brew doctor`, sudo prompts.
