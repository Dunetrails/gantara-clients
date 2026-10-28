# Gantara desktop client (rebranded Nextcloud)

We host **Nextcloud Community** (see [docs/nextcloud-editions.md](../../docs/nextcloud-editions.md)).
The desktop sync client is GPL code we are free to modify and ship, but **"Nextcloud" and
the cloud logo are registered trademarks**, and Nextcloud's
[trademark guidelines](https://nextcloud.com/trademarks/) are explicit: a client we
distribute may not carry the Nextcloud name or logo, and must not look like the official
one. For a Community client we hand to customers, rebranding is the compliant path, not a
preference.

This directory turns the Linux and Windows sync client into **Gantara** and
nothing else. No features are added, removed or changed — same code, different
name, artwork and links. Windows builds are unsigned for now.

The client first shipped as *Dunetrails*. Only what users see moved to Gantara: the
settings directory, keychain entries, autostart entry, executable, `.desktop` / D-Bus
id, Windows install folder and sync roots all keep the Dunetrails identity, so an
update keeps its accounts and sync folders (see [Names and identity](#names-and-identity)).

> The Talk client is a separate application with its own overlay and workflow:
> [`clients/talk-desktop`](../talk-desktop/README.md). Nothing here touches it.

## How it works

There is no fork. The pipeline checks out a **pinned upstream tag** and rewrites the marks
in place, immediately before the build, so following a new upstream release is a
`desktop_ref` bump rather than a merge.

Every rewrite anchors on an exact upstream literal and **aborts when the anchor is
missing**. A tag where upstream moved a string fails the build instead of quietly
shipping a Nextcloud mark. Afterwards the whole tree is swept again for surviving marks.

```
clients/desktop/
  README.md                  <- this file
  branding/
    branding.env             <- every name, identifier, URL and Windows GUID
    apply-branding.sh        <- rewrites a checked-out nextcloud/desktop tree
    verify-branding.sh       <- compliance sweep; fails the build on a leftover
    build-windows.ps1        <- Craft-based unsigned Windows NSIS package
    build-windows-local.ps1  <- full local VM build (prereqs + clone + package)
    assets/gantara-*.svg     <- brand vectors: colour star, horizontal logo (light/dark)
    assets/logo.png          <- the colour star as PNG, for the NSIS installer
    assets/logo.ico          <- the brand app icon for Windows NSIS / shortcuts
clients/
  install-appimage.sh        <- per-user install / --uninstall / --purge
  reset-linux-clients.sh     <- wipe all client state from a Linux account
.github/workflows/
  build-desktop-client.yml   <- manual workflow: Linux AppImage + Windows NSIS
```

## What gets changed

**Names and identifiers**, as an override block appended to `NEXTCLOUD.cmake`. It is
`include()`d top to bottom, so appending wins. Product name, executable, icon name,
domain, vendor, the reverse-DNS id we register with the OS (`.desktop` entry, D-Bus name),
the settings filename, the virtual-file suffix that ends up in every online-only
placeholder's name, and the Windows Explorer overlay / context-menu / MSI
UpgradeCode GUIDs (so we never collide with an official Nextcloud install on the
same machine). Two of those — the settings filename and the desktop/D-Bus id — are
derived by upstream from values we replace, so they are recomputed rather than inherited.
The Windows CfApi class IDs live in `CMakeLists.txt` *after* that include, so they
are rewritten in place rather than appended.

<a id="names-and-identity"></a>**Names and identity.** `APPLICATION_NAME` (Gantara) is
what users see. `APPLICATION_SHORTNAME`, `APPLICATION_EXECUTABLE`, `APPLICATION_VENDOR`
and the reverse-DNS id keep the Dunetrails values the client first shipped with. Upstream
uses the short name for keychain entries and the autostart file, but derives a few
identities from the display name: the settings directory (`~/.config/<name>`,
`%APPDATA%\<name>`), admin policy paths, the Windows virtual-files sync-root id and the
Explorer sidebar entry. `apply-branding.sh` pins those to the short name, and
`verify-branding.sh` checks each pin. Without that, renaming the product would orphan
every existing account. On Windows the NSIS installer does the same: the Program Files
folder, the registry key and the uninstall key stay "Dunetrails", while the setup window,
the Start menu, Add/Remove Programs and the publisher say Gantara.

**Links.** The add-account wizard's server-address hint, its "sign up" and
"host your own server" buttons, the Client Push link in Settings, the Help menu, and the
build-revision link in the About dialog. Where a link had no Gantara equivalent it
points at the site rather than being removed, because removing it would mean removing a
`QString::arg()` placeholder and shifting everything after it into the wrong slot. The
About dialog's "supplied by" line names the product rather than the vendor, and the
command-line help of both binaries no longer names Nextcloud.

**The updater is compiled out** (`BUILD_UPDATER=OFF`), so nothing polls for updates. The
update URL is still set, and set to our own domain: `config.h` only defines the macro when
it is non-empty, `theme.cpp` dereferences it unconditionally, and a build with the updater
accidentally switched back on must not be able to reach `updates.nextcloud.org` — that
serves the official, differently-branded client.

**Artwork.** The application icon is the Gantara colour star, the brand's app-icon mark
(the Talk client uses the white star on a blue tile, so the two stay apart in a tray). The
brand SVGs are nested into SVGs of the size each slot expects, so the client rasterises
real vectors; the same converter the cmake build already requires produces the bitmaps Qt
loads by a fixed `.png` name. The wizard logo and the old wizard's slides get the
horizontal logo at their 2:1 aspect, with the light-text variant for dark windows. v35's
QML wizard shows none of them, but they are still compiled in. On Windows the Start
tile (`<executable>.VisualElementsManifest.xml` plus the `w10startmenu` SVG), the
folder icon and the NSIS `installer.ico` are the same star. Unreferenced Nextcloud logo
artwork, including the macOS Icon Composer bundle, is deleted from the tree rather than
left to rely on its code path staying dead.

The tray status icons need no work: upstream's own build switches from its logo-shaped
icons to plain status glyphs as soon as `APPLICATION_NAME` stops being "Nextcloud".
`verify-branding.sh` asserts that switch still exists, because if a future tag drops it the
tray goes back to the Nextcloud mark silently.

**House style.** The wizard header and the default account accent colour come from the
cmake block, which is where the QML style sheet reads its base colour. The info boxes are
the exception — they hardcode Nextcloud blue — so they are recoloured too. Colour only: no
sizes, no layout, no behaviour.

**Translations.** Qt matches a translation by its source text, so the two rewritten
messages need their `<source>` moved with the literal or the client asks for a string no
catalogue has. One of them — the Assistant's "Start a conversation with … Assistant." —
cannot be translated across the change: languages inflect "Nextcloud" into the sentence,
and no substitution stays grammatical. Those bodies are cleared, which makes Qt fall back
to the rebranded English source.

## What is deliberately left alone

`verify-branding.sh` treats every remaining "nextcloud" as a failure unless it is
explicitly allowed, and each entry in that list says why. The categories:

- **Server protocol** — WebDAV property namespaces (`http://nextcloud.org/ns:*`), the
  probe that finds a server installed under `/nextcloud/`, the organisation field of the
  end-to-end-encryption certificate request, and the extended attributes stamped on
  placeholder files. These travel to the server or the filesystem. Renaming them breaks
  sync.
- **Identifiers** — the QML module URI every `.qml` file imports, C++ class names, cmake
  target and library names, Qt logging categories, the About dialog's translation context.
  None is rendered. The Windows Explorer overlay / context-menu / MSI / CfApi GUIDs are
  the opposite: those *are* replaced, so two clients do not collide. Developer switches
  read from the environment (`NEXTCLOUD_BULK_UPLOAD`, …) keep their names too.
- **Legacy account import** — the client reads an existing Nextcloud install's settings so
  its account can be migrated, and checks whether it is still called "Nextcloud" to decide
  whether it is a branded build. Both are only correct unbranded.
- **Diagnostics** — the log filename and the debug-archive scratch file. Also the two
  probe files the folder watcher writes, which are named in `sync-exclude.lst`: renaming
  those would start syncing them.
- **Attribution** — the copyright notice in the About dialog and Legal notice. The GPL
  requires keeping it, and rebranding is not a claim of authorship.
- **Stale translation entries** — the catalogues still carry `<source>` text for strings
  upstream has since changed, some naming Nextcloud. Those are unreachable, and the sweep
  proves it rather than assuming it: it checks that no such source text is a literal the
  rebranded code still asks for.

Also out of scope by the same logic: macOS sources and upstream's Debian/PPA publishing
scripts. None of those is built or installed here.

## Which upstream version to pin

**`v35.0.0`.** We held at v33.0.7 for a while because v34 reworked the tray, the main
window and the add-account wizard, and on Linux several of its breakages reproduced with
upstream's own AppImage. v35 replaces the add-account wizard again (now QML) and moves to
Qt 6.11; the v33 pin no longer matched the server we host, so the overlay was re-anchored
on v35.0.0. Re-test the Linux tray and the add-account flow on each new tag before
handing a build to customers.

Version skew is not the problem it looks like. The client supports every server back to
20, and an older client against a newer server is the combination upstream expects, since
users update on their own schedule.

The overlay is written against v35.0.x. Newer v35 patch releases should apply unchanged —
check [nextcloud/desktop releases](https://github.com/nextcloud/desktop/releases). A new
major means bumping `desktop_ref` and `builder_image` together, and re-checking the
anchors, which the script will tell you about by failing. Windows needs no extra input:
it reads the Craft blueprint branches from the tag's own `craftmaster.ini`.

## Building

Actions → **Build Gantara desktop client (rebranded Nextcloud)** → *Run workflow*.

- `platform` — `linux` or `windows` (one per run; default `windows`).
- `desktop_ref` — the upstream tag to build (default `v35.0.0`).
- `builder_image` — Nextcloud's own AppImage build container, as pinned by that tag's
  `.github/workflows/linux-appimage.yml`. Used for Linux. Bump it with the tag.
- `craft_blueprint_branch` — optional, Windows only. Empty (the default) uses the
  `craft-blueprints-kde` / `craft-blueprints-nextcloud` branches pinned in the tag's
  `craftmaster.ini`, as upstream CI does. A value overrides both.

Linux is upstream's `admin/linux/build-appimage.sh`. Windows is KDE Craft via
`clients/desktop/branding/build-windows.ps1` (same path as upstream's
`windows-build-and-test.yml`), packaging an unsigned NSIS installer. Both assets attach
to the same **GitHub Release** (`desktop-<tag>`), which is a browser download and does
not consume Actions artifact storage. This repo is private, so customers get the file
from you rather than from GitHub.

To apply the branding locally without building, run the script against a checkout — it
needs `bash`, `sed`, and `inkscape` or `rsvg-convert`:

```bash
git clone --depth 1 --branch v35.0.0 https://github.com/nextcloud/desktop.git
bash clients/desktop/branding/apply-branding.sh ./desktop
```

## Installing

An AppImage is a portable single file: running it never registers a launcher, so it does
not appear in the applications menu on its own. That is normal AppImage behaviour, and it
is true of the official Nextcloud AppImages too. [`clients/install-appimage.sh`](../install-appimage.sh)
does that integration once, per user, no root:

```bash
clients/install-appimage.sh Gantara_Desktop-35.0.0-x86_64.AppImage
clients/install-appimage.sh --uninstall com.dunetrails.desktopclient.dunetrails
```

It copies the AppImage somewhere stable, installs the embedded `.desktop` entry and icon,
and writes the autostart entry under the basename the client's own "Launch on system
startup" checkbox looks for. It writes that entry pointing at the installed copy on
purpose: the client, left to itself, can write one pointing at the AppImage's temporary
FUSE mount, which does not exist at the next login.

`--purge` additionally removes settings, cache and the stored account.
[`clients/reset-linux-clients.sh`](../reset-linux-clients.sh) clears out every client,
branded or not, from a Linux account — useful when a test install has left state behind.

## Installing the Windows setup (unsigned)

Download the `.exe` from the GitHub Release and run it. The NSIS installer creates
Start Menu / Programs entries.

**This build is deliberately unsigned** (Craft `SIGN_PACKAGE=False`; upstream's
`craftmaster.ini` already ships that). On first launch Windows SmartScreen will
typically show “Windows protected your PC” → *More info* → *Run anyway*. That is
expected until Azure Artifact Signing (or another Authenticode cert) is wired into
the Windows job. Treat the unsigned EXE as internal / test distribution, not a
customer-facing download.

### Local Windows VM (no Actions)

Do **not** download the `.ps1` via raw.githubusercontent — chat/clipboard often
mangles the closing quote after `.ps1` into `%27` / `%22` and PowerShell dies.

On an **elevated** PowerShell:

```powershell
gh repo clone Dunetrails/k8s-platform-ovh $root
Set-ExecutionPolicy -Scope Process Bypass -Force
& (Join-Path $root 'clients\desktop\branding\build-windows-local.ps1')
```

`build-windows-local.ps1` then installs Python 3.12, Inkscape, VS 2022 C++ Build
Tools, and 7-Zip, clones `nextcloud/desktop`, applies branding, and runs Craft/NSIS.
Output: `%USERPROFILE%\dunetrails-desktop-build\desktop-windows-out\`.
Plan for **50+ GB** free and **1–2 hours** on the first run.

## Limitations

- **x86_64 Linux AppImage + unsigned Windows NSIS.** No Authenticode cert yet;
  SmartScreen will warn. No macOS package (needs a Developer ID and notarisation).
  WiX MSI can come later; Craft currently emits NSIS.
- **No updates.** The updater is compiled out, so a new version means a new build here and
  a new file for the user. There is no appcast to point it at.
- Synced files are never touched by any of these scripts, including `--purge`. Saved
  passwords live in the system keyring.
