# Mac Storage Report

Find out where your Mac's disk space actually went — and what's safe to delete.

[![shellcheck](https://github.com/rxxxxxxb/mac-storage-report/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/rxxxxxxb/mac-storage-report/actions/workflows/shellcheck.yml)

macOS buries most of your disk in an opaque **"System Data"** bucket and tells
you nothing else. This script walks your home folder once and breaks it down by
category — Library, caches, dev tools, browsers, media, messaging, games — then
ends with a ranked list of cleanup candidates, each tagged by how risky it is to
remove.

> **It never deletes anything.** It measures and prints, nothing else. What to
> remove, and whether to remove it, stays entirely your call.

## Quick start

```sh
curl -fsSL https://raw.githubusercontent.com/rxxxxxxb/mac-storage-report/main/storage-report.sh -o storage-report.sh
chmod +x storage-report.sh
./storage-report.sh
```

Read it before you run it — it's one commented file, which is rather the point.

Requires macOS and nothing else: bash 3.2, `du`, `df`, `awk`, and `find` all
ship with the OS. A run takes a minute or two on a large home folder.

## What you get

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  💾 DISK OVERVIEW
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    Total: 926Gi    Used: 781Gi    Free: 145Gi    Usage: 85%

    ██████████████████████████████████████████░░░░░░░░  85%

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  🧹 CLEANUP CANDIDATES
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  #   Size       Item                                          Safety
  ──────────────────────────────────────────────────────────────────────
  1.  24.3G      iOS Simulators (all devices)                   CAUTION
  2.  14.7G      Gradle build cache                             SAFE
  3.  11.8G      Xcode DerivedData (build cache)                SAFE
  4.  6.2G       Homebrew download cache                        SAFE
  5.  3.1G       WhatsApp cached media                          CAUTION

    Total reclaimable (SAFE + CAUTION):  55.0 GB
```

<details>
<summary>See a full report</summary>

The real thing is longer — twelve sections before the cleanup list, in color.

```
╔══════════════════════════════════════════════════════════════════╗
║     🖥️  Mac Storage Report                                        ║
║     Generated: 2026-08-06 14:22:07                               ║
╚══════════════════════════════════════════════════════════════════╝

  💾 DISK OVERVIEW            Total / used / free, with a usage bar
  📁 HOME DIRECTORY           15 largest items in ~
  📚 LIBRARY                  10 largest items in ~/Library
  📦 APPLICATION SUPPORT      10 largest app data folders
  🚀 INSTALLED APPLICATIONS   10 largest apps in /Applications
  🗑️  CACHES                   10 largest cache folders
  🛠️  DEVELOPER TOOLS          Xcode, Android, package manager caches
  🌐 BROWSER DATA             Profile data and cache, per browser
  🎬 MEDIA & DOWNLOADS        Movies, Music, Pictures, Downloads, …
  💬 MESSAGING APPS           WhatsApp, Discord, Messenger
  🎮 GAMES                    ~/Games and CrossOver bottles
  🍎 macOS SYSTEM DATA        Wallpapers, iCloud Drive, containers
  🧹 CLEANUP CANDIDATES       Everything above 10 MB, ranked and tagged

    SAFE       items:  23.6 GB  — caches apps rebuild on their own
    CAUTION    items:  31.4 GB  — recoverable, may need re-login or re-download
    YOUR CALL  items:  84.2 GB  — personal data, not counted as reclaimable

    Total reclaimable (SAFE + CAUTION):  55.0 GB
```

</details>

## Safety tags

Every candidate over 10 MB gets one of three tags:

| Tag | What it means | Cost of deleting |
| --- | --- | --- |
| **SAFE** | Caches and temp files apps rebuild by themselves | A slower next launch |
| **CAUTION** | Working data that's recoverable, but not free | A re-login, re-download, or re-setup |
| **YOUR CALL** | Personal or app data — games, SDKs, backups, media | Only you know. Excluded from the reclaimable total |

## What it covers

Paths missing from your machine are skipped silently, so the list stays broad:

| Area | Covered |
| --- | --- |
| **Dev tools** | Xcode (DerivedData, Archives, simulators, DeviceSupport), Android SDK, Gradle, CocoaPods, JetBrains, VS Code, Cursor |
| **Package managers** | Homebrew, pip, uv, npm, Yarn, pnpm, Cargo, Go modules + build cache, FVM |
| **Browsers** | Chrome, Safari, Firefox, Brave, Edge, Arc — profile data and cache listed separately |
| **Containers & models** | Docker Desktop VM disk, Hugging Face cache, Ollama weights |
| **Apps & media** | WhatsApp, Discord, Messenger, Spotify, Notion, Steam, CrossOver bottles, iPhone/iPad backups, iCloud Drive, aerial wallpapers |

Something big missing? [Add it yourself](#add-your-own-paths) — and a PR adding
it for everyone is welcome.

## Full Disk Access

macOS may prompt for permission when the scan reaches protected folders
(Desktop, Documents, Downloads). Grant your terminal **Full Disk Access** under
System Settings → Privacy & Security for a complete picture.

Without it, nothing breaks — protected folders just report smaller than they
are. Sandboxed containers, Safari's especially, often read as `0K`.

## Tips

Save a plain-text copy by stripping the colors:

```sh
./storage-report.sh | sed $'s/\033\\[[0-9;]*m//g' > report.txt
```

## Add your own paths

The cleanup list is a series of `add_item` calls near the bottom of the script.
Each takes a path, a label, and a tag:

```bash
add_item "$HOME/Library/Caches/Homebrew" "Homebrew download cache" "SAFE"
```

Use `SAFE`, `CAUTION`, or `YOUR_CALL`. Non-existent paths are skipped, so it's
fine to add entries for apps you don't have.

## Alternatives

If you want cleanup rather than a report, use [Mole](https://github.com/tw93/Mole)
— `brew install mole`. It does considerably more than this script: an interactive
disk explorer, app uninstaller, orphaned-data detection, build-artifact purge,
live system monitor. For most people it's the better answer — start there.

This script covers a narrower case:

- **Nothing to install.** bash 3.2 and tools that ship with macOS. Runs over SSH,
  on a locked-down work Mac, anywhere you can't add a binary.
- **It cannot delete.** There is no `rm` in it — a property you can confirm in one
  read, rather than a promise you have to take on trust.
- **It shows its reasoning.** Each candidate is tagged with what removing it
  actually costs you, and the decision stays yours.


## Contributing

PRs welcome — especially cleanup paths for apps not yet covered. Two rules:

1. **The script stays read-only.** Nothing that deletes or modifies files.
2. **Target bash 3.2**, which is what macOS ships at `/bin/bash`. No associative
   arrays, no `${var,,}`, and note that BSD `seq 1 0` counts *down*.

Run `shellcheck storage-report.sh` before opening a PR. CI runs it on every push.

## License

MIT — see [LICENSE](LICENSE).
