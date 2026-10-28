# Gantara Talk desktop (rebranded Nextcloud Talk)

Companion to [`clients/desktop`](../desktop/README.md) (the file-sync client), for the
**Talk** desktop client. Same trademark driver: we host Nextcloud **Community** (see
[docs/nextcloud-editions.md](../../docs/nextcloud-editions.md)), so a Talk client we
distribute may not carry the Nextcloud name or logo — see
[nextcloud.com/trademarks](https://nextcloud.com/trademarks/).

Unlike the Qt sync client, `nextcloud/talk-desktop` is an **Electron** app that bundles
the Talk web UI from `nextcloud/spreed`, and it ships a first-class branding mechanism,
so this overlay is small.

## How it works

We pin an upstream `talk-desktop` tag and stage a branding overlay, then run upstream's
own `release:package` flow. Tracking a new release is a one-line `talk_desktop_ref` bump.

```
clients/talk-desktop/
  README.md
  branding/
    build.config.json     <- the brand config (single source of truth)
    apply-branding.sh      <- stages the overlay into a checked-out talk-desktop tree
    verify-branding.sh     <- fails the build if a Nextcloud mark or update URL survived
    make-appimage.sh       <- wraps the packaged app tree into a single-file AppImage
    assets/gantara-*.svg   <- brand vectors: white/colour star, stacked + horizontal white logo
    assets/logo.png        <- PNG fallback for the AppImage icon
    assets/squirrel-install-loading.gif <- Windows setup animation (replaces Nextcloud's)
    styles/<major>/        <- extracted Nextcloud theme CSS (see refresh-talk-styles)
.github/workflows/
  build-talk-desktop.yml   <- manual workflow: checkout -> brand -> verify -> package
```

`apply-branding.sh`:

1. Copies `build.config.json` to `<talk-desktop>/.overrides/build.config.json`. Its mere
   presence flips the build into **branded mode** (`isBranded = true`), which auto-derives
   `companyName`, the copyright string, the macOS/Windows/Linux app IDs and the Windows
   MSI `UpgradeCode` from our `domain` — so, unlike the sync client, there are no GUIDs to
   regenerate by hand.
2. Replaces the source icon SVGs in `img/` (the ones `scripts/generate-icons.js` consumes)
   with the Gantara vectors, plus the Windows Squirrel loading GIF. The workflow then runs
   `npm run generate-icons`.
3. Rewrites leftover Nextcloud URLs (login placeholder, Squirrel `iconUrl`, Help/privacy)
   and disables auto-update for branded builds. `verify-branding.sh` then fails the job if
   any of those marks survived.
4. Shows `displayName` ("Gantara Talk") wherever upstream would show `applicationName`
   ("Dunetrails Talk"), which stays the app's identity — see
   [Names and identity](#names-and-identity).

The workflow then runs upstream `npm run release:package -- --linux`, which installs the
tree (the bundled Talk web UI is the `@nextcloud/talk` npm dependency since v2.3) and
packages the app. electron-forge has no AppImage maker, so a final `make-appimage.sh`
step wraps the packaged `out/<name>-linux-<arch>/` tree into a single-file `.AppImage`
with `appimagetool`.

## Running it

Actions → **Build Gantara Talk desktop (rebranded Nextcloud Talk)** → *Run workflow*.
Inputs: `platform` (`linux` or `windows`), `talk_desktop_ref` (upstream tag, default
`v2.3.3`), and `channel` (`stable`/`beta`/`dev`, the release channel compiled into the
app; since v2.3 the bundled Talk version is fixed by the tag). Installers are attached to
a **GitHub Release** `talk-desktop-<ref>`. They do not count toward Actions storage.
This repo is private; customers download from the public
[`Dunetrails/gantara-clients`](https://github.com/Dunetrails/gantara-clients), where
`publish-public-clients.yml` mirrors each release after its build (see the compliance
checklist below).

**Windows needs current committed styles.** v2.3.3 bundles Talk v25, which themes itself
from Nextcloud 35 styles; the committed `styles/34` no longer match. Run
**refresh-talk-styles** once (after pushing this branch, before a Windows build) — the
Windows job checks and stops with that instruction otherwise. Linux extracts them itself
via Docker when they are stale.

## Installing / running the AppImage

An AppImage is **not a setup wizard** — there is no install screen. Mark it executable
and run it (double-click or terminal); the Talk window should open, and the first
launch registers a menu entry.

```bash
chmod +x Gantara_Talk-x86_64.AppImage
./Gantara_Talk-x86_64.AppImage
```

If a file manager double-click does nothing: the download often has no execute bit
(GNOME then silently refuses to run it). `chmod +x` as above, or right-click →
Properties → “Allow executing file as program”, then double-click again.

**It adds itself to the applications menu on first launch.** The build injects a
self-integrating `AppRun` (see [`clients/embed-desktop-integration.sh`](../embed-desktop-integration.sh)):
the first time the AppImage runs it drops a launcher + icon into `~/.local/share`
pointing back at itself, so it shows up in "programs" with no install step. Set
`DUNETRAILS_INTEGRATE=0` to skip that. Deleting the AppImage leaves the menu entry behind
(a known AppImage limitation) — remove it with the installer's `--uninstall` below, or via
[AppImageLauncher](https://github.com/TheAssassin/AppImageLauncher).

Linux behaviour that differs from upstream Nextcloud Talk:

- The hamburger (three-stripe) menu has **no Update** item — we do not point at
  Nextcloud's GitHub releases.
- The running window uses the same Linux app id as the launcher (`dunetrails-talk`),
  so the dock/panel does not grow a second ungrouped icon.
- Clicking the desktop or menu item while Talk is already open brings the existing
  window to the foreground (it does not start a second copy or quit the first).
- **"The server was updated. Please restart the app."** Talk shows this whenever the
  server's `X-Nextcloud-Talk-Hash` changes. That hash includes the theming cache
  buster, and the tenant migrate job used to re-run `occ theming:config` on every
  deploy, which bumps it even when nothing changed — hence the message after every
  deploy. The job now only writes theming values that differ. When the hash does
  change, Talk restarts itself once the window is hidden in the tray and no call is
  running, coming back in the tray; "Restart" from the message also works for an
  AppImage now (upstream relaunched the FUSE-mounted binary, which is gone by then).
- Quitting no longer races the tray helper: it gets a clean `QUIT`, exits on its own
  when its stdin closes, and a second stop or a closed window is ignored instead of
  throwing.

The **tray/status icon** appears **after you log in** (not on the welcome/login
window). Look **next to the clock**, not in the dock. Right-click gives an
**Open / Quit** menu and double-click shows the window; closing the window hides
to the tray (Quit from the tray menu or hamburger File menu actually exits).

That menu is a second D-Bus object: hosts read it from `com.canonical.dbusmenu`
at the path the item's `Menu` property names, and GNOME builds the whole menu
from `GetLayout`/`GetGroupProperties` — it never calls the item's `ContextMenu`
method. So on Linux the menu entries live in `sni_tray.py`, not in the Electron
`Menu` template, and an item without a real dbusmenu object has **no** right-click
menu at all.

Electron 43.3–43.4 and 44.0 broke GNOME/Cinnamon tray icons
([electron#52674](https://github.com/electron/electron/issues/52674)); talk-desktop v2.2.4
shipped one of those, so the overlay used to pin Electron 43.2. The fix is in 43.5.0 /
44.1.0 and v2.3.3 ships ^44.4, so nothing is pinned any more (`inspect-appimage.sh`
flags a build that lands in the broken range). On Linux the overlay still
prefers a host `sni_tray.py` helper
(python3 + **python3-gi**) over Electron's Tray API: it exports a StatusNotifierItem
with Gio so GNOME AppIndicator can read `Id` / `Menu` / `IconPixmap` on the unique
bus name. If that helper cannot start — `python3-gi` is not installed everywhere —
the app **falls back to Electron's own Tray** instead of ending up with no icon.
The helper also re-registers whenever a StatusNotifierWatcher appears, so the icon
survives a gnome-shell restart and a shell that finishes loading after Talk does.
The window keeps the `dunetrails-talk` app id (no extra dock icon). Vulkan is
disabled so Wayland can map the window; we do not force X11.

### No tray icon on Linux

Start with `/tmp/dunetrails-talk-sni.log`, then run the shipped diagnostic — it
separates "the helper is broken" from "this desktop has no tray host":

```bash
./Gantara_Talk-x86_64.AppImage --appimage-extract sni_tray.py
python3 squashfs-root/sni_tray.py --diagnose
```

Also make sure no **older Talk is still running**. Our own patch makes a second
launch on Linux focus the existing window rather than start a new process (AppImage
FUSE mounts differ per launch, so upstream would otherwise kill the running copy),
and the app hides to the tray instead of exiting. A stale instance therefore
swallows every new AppImage you start, and the build you just downloaded never
runs. `pgrep -af -i 'dunetrails.*talk'` should be empty before you re-test.

Before changing `sni_tray.py`, run its self-tests — the build job runs the same
ones, and they cover the pixmap, the item properties and the whole dbusmenu path:

```bash
python3 clients/talk-desktop/branding/validate-sni-tray.py
```

Note that **the sync client showing a tray icon does not prove Talk can**. Qt
falls back to the legacy XEmbed protocol when no StatusNotifierWatcher is
running, and Electron/Chromium implements only StatusNotifier. So on Xfce, MATE
and some Cinnamon setups the Qt sync client gets an icon while every Electron app
silently gets none. `--diagnose` reports which of the two your session has.
GNOME needs the AppIndicator extension (Ubuntu: `gnome-shell-extension-appindicator`,
enabled by default on Ubuntu desktop; Fedora/vanilla GNOME usually needs it installed).

If you'd rather integrate/keep the AppImage in a fixed place explicitly (per-user, no root),
the shared installer does that and also cleans up:

```bash
../install-appimage.sh Gantara_Talk-x86_64.AppImage   # clients/install-appimage.sh
# later: clients/install-appimage.sh --uninstall dunetrails-talk
```

The bundled `AppRun` launches Electron with `--no-sandbox` (an AppImage is a read-only FUSE
mount, so Chromium's SUID sandbox helper can't be used).

## Installing the Windows setup (unsigned)

Download the `.exe` from the GitHub Release and run it. The Squirrel installer creates
Start Menu / Programs entries (no separate desktop-integration step). The setup
animation and Add/Remove Programs icon are the Gantara star, not Nextcloud's. Shortcuts
and Add/Remove Programs say "Gantara Talk"; the install folder, executable, user data and
notification identity keep the "Dunetrails Talk" identity, so an update over an existing
install keeps the login. Squirrel's update hook removes the old "Dunetrails Talk"
Start-menu folder and desktop shortcut.

**This build is deliberately unsigned** (`WINDOWS_SIGN_PARAMS` is forced empty). On first launch Windows
SmartScreen will typically show “Windows protected your PC” → *More info* → *Run anyway*.
That is expected until Azure Artifact Signing (or another Authenticode cert) is wired into
the Windows job. Treat the unsigned EXE as internal / test distribution, not a customer-facing
download.

**No auto-update.** The hamburger has no Update item, the client does not poll
`nextcloud-releases`, and Squirrel's `RELEASES` / `.nupkg` feed is not published.
A new version means a new build here and a new file for the user.

`windowsMsi` stays `false` for now (WiX Toolset on the runner + MSI path can come later).
macOS / Flatpak remain off.

## Deliberate scope of this pipeline

- **Linux AppImage + Windows Squirrel EXE (unsigned, no auto-update).** `windowsExe` is `true` in
  `build.config.json`; `windowsMsi`, `macosDmg` and `linuxFlatpak` stay `false` (the Linux
  `.zip` maker stays enabled — the AppImage is built from the app tree it produces). Signing
  is off (`WINDOWS_SIGN_PARAMS` empty). Flatpak is skipped to avoid `flatpak-builder` in CI.
- **In-app theming is ON, and builds are Docker-free when the styles are current.**
  `build.config.json` sets `primaryColor`/`backgroundColor` to the Gantara blue
  (`#31469D`, the platform theme's primary), which flips
  `withThemingOverrides` true — the in-app Talk web UI is recoloured from *extracted*
  Nextcloud styles. Producing those styles requires spinning up a Nextcloud container
  (`ghcr.io/szaimen/nextcloud-easy-test`) via **Docker** and scraping the theme CSS, because
  Nextcloud computes the theme (and all its contrast-adjusted/dark/high-contrast variants)
  server-side at runtime. Rather than pay that on every build, we **commit the extracted
  styles** under `branding/styles/<major>/`; `apply-branding.sh` stages them into
  `.overrides/styles/`, and `release:package` then finds them "up-to-date" and **skips the
  Docker extraction**. So the normal build needs no Docker and stays fast.
  - Regenerate them with the **`refresh-talk-styles`** workflow (Actions → *Run workflow*)
    — the only step that uses Docker. Run it when the theme colours change or when a
    `talk_desktop_ref` bump changes the bundled Nextcloud major. It extracts, commits
    `branding/styles/<major>/`, and uploads an artifact.
  - The "up-to-date" check keys on the Nextcloud `versionCommitHash` and on the two
    colours, so it works because stable Talk pins a Nextcloud **tag** (Talk `v25.x` → NC
    `35`). Changing a colour or bumping `talk_desktop_ref` to a new Talk major means
    re-running the workflow. Only the Linux runner can fall back to a live extraction;
    the Windows job stops instead and says so.
  - `styles/34/` is from the v2.2 line and can be deleted once `styles/35/` is committed.
  - To revert to the stock Nextcloud theme, delete the two colour keys and the committed
    `branding/styles/`.

## What is / isn't rebranded

<a id="names-and-identity"></a>**Names and identity.** Users see **Gantara Talk**: window
title, About, tray tooltip, Windows shortcuts, file description and Add/Remove Programs,
the AppImage filename and its menu entry. `applicationName` stays `Dunetrails Talk`
because upstream derives the executable name, the user-data directory, the Squirrel
package id, the Windows AppUserModelId and the Linux app id (`dunetrails-talk`) from it;
renaming it would log every user out and split the dock/notification identity. So the
overlay injects `displayName` into the compiled-in build config as the name the app shows,
and keeps the identity values derived from `applicationName`.

**Rebranded:** app name, installer/zip name, window title, company/copyright metadata
(`vendorName` Gantara), app IDs, the app + tray icons, the splash `brandColor`/gradient,
the Windows Squirrel setup animation and `iconUrl`, and the logos rendered by the app
shell — the **welcome/splash** logo (`img/talk-logo.svg`, the stacked white logo), the
**login** logo (`img/server-logo-plain.svg`, the horizontal white logo) and the in-app
Talk **navigation** icon (`img/talk-icon-plain-dark.svg`, the colour star). The first two
sit on the brand-colour background, so they use the brand's white variants; each keeps the
target's original `viewBox` so the layout is unchanged. All artwork is the brand's own SVG
nested in place, not a raster. Help / privacy links go to `gantara.eu`. The login field is
**not** pre-filled with a Nextcloud URL; the placeholder is `https://<<tenant>>.gantara.eu`.
Auto-update is compiled out of the branded UI (no GitHub poll, no Update menu item).

**Distinct from the sync client:** the sync client's icon is the full-colour star on
transparency, the brand's app-icon mark. Talk's app/tray icon is the white star on a solid
brand-colour rounded tile (`brandColor`, read from `build.config.json`). Without that the
two apps are indistinguishable in the dock, app grid and tray. The `-spaced`/mac icon
sources get an inset tile, since they feed the targets that expect padding. The AppImage's
menu icon reuses the generated `img/icons/icon.png`, so the menu entry matches the running app.

**Not covered here:** deep string rebranding *inside* the bundled Talk web UI (conversation
screens, "Nextcloud Talk" strings) comes from `spreed`, not the app shell. `domain` in
`build.config.json` stays `https://dunetrails.com` only so app IDs become `com.dunetrails.*`
instead of `com.nextcloud.*`; it is not used as the login default (`enforceDomain` is false).

## Compliance checklist (per build)

1. No "Nextcloud" name or cloud/Talk logo in anything user-facing (upstream author
   attribution in About/copyright stays — a licence requirement, not a violation).
2. Branded name + app IDs derived from `dunetrails.com` (never `com.nextcloud.*`).
3. Presented as a modified, unofficial client.
4. **AGPL copyleft:** provide the modified source to recipients. Here "the source" is
   upstream `nextcloud/talk-desktop@<ref>` + `nextcloud/spreed@<bundled version>` + this
   `clients/talk-desktop/branding/` overlay. `publish-public-clients.yml` publishes the
   overlay and mirrors each `Gantara_*` release to the public
   [`Dunetrails/gantara-clients`](https://github.com/Dunetrails/gantara-clients), with release
   notes naming the upstream tag; customers download only from there.

## Notes / gotchas

- First run against a new upstream tag can surface a moved file, a changed icon-source
  set, or a Linux UX patch that no longer matches; `apply-branding.sh` fails rather than
  silently no-op'ing.
- Node `^24` / npm `^11` are required by upstream `package.json` engines.
- Light/dark-specific tray art is not done; the tray uses the same tile as the app icon.
