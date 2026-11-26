# Gantara clients

Desktop applications for [Gantara](https://gantara.eu), and the source code of everything Gantara
changes in the open-source software it runs.

## Download

Click a link to download the newest version:

| Application | Windows | Linux | macOS |
|--|--|--|--|
| **Gantara Desktop** — keeps your files in sync with your computer | [Download for Windows](https://github.com/Dunetrails/gantara-clients/releases/download/desktop-latest/Gantara_Desktop-x64-setup.exe) | [Download for Linux](https://github.com/Dunetrails/gantara-clients/releases/download/desktop-latest/Gantara_Desktop-x86_64.AppImage) | [Download for Mac](https://github.com/Dunetrails/gantara-clients/releases/download/desktop-latest/Gantara_Desktop-macos-universal.pkg) |
| **Gantara Talk** — chat and calls, on plans that include them | [Download for Windows](https://github.com/Dunetrails/gantara-clients/releases/download/talk-latest/Gantara_Talk-x64-setup.exe) | [Download for Linux](https://github.com/Dunetrails/gantara-clients/releases/download/talk-latest/Gantara_Talk-x86_64.AppImage) | [Download for Mac](https://github.com/Dunetrails/gantara-clients/releases/download/talk-latest/Gantara_Talk-macos-universal.dmg) |

Earlier versions are on the [Releases page](https://github.com/Dunetrails/gantara-clients/releases).
Every release lists SHA-256 checksums of its files
([Desktop](https://github.com/Dunetrails/gantara-clients/releases/download/desktop-latest/Gantara_Desktop-SHA256SUMS.txt),
[Talk](https://github.com/Dunetrails/gantara-clients/releases/download/talk-latest/Gantara_Talk-SHA256SUMS.txt)
for the newest version), and the checksum file is signed. How to check a download:
[SIGNING.md](SIGNING.md).

When the application asks for a server address, enter the address you use in your browser, for
example `https://app.gantara.eu`.

**Windows:** until the installers are code-signed, Windows SmartScreen may show "Windows
protected your PC"; choose *More info*, then *Run anyway*. Each release says whether its Windows
installer is signed.

**Linux:** make the AppImage executable (`chmod +x Gantara_*.AppImage`) and run it.

**macOS:** one download per application for Apple Silicon and Intel Macs (macOS 13 or later for
Gantara Desktop), signed and notarised by Apple. Gantara Desktop is an installer: open the `.pkg`
and follow it. For Gantara Talk, open the disk image and drag *Gantara Talk* to *Applications*; the
first time you open it, macOS asks whether you want to open an app downloaded from the Internet;
choose *Open*.

**iPhone and Android:** there is no Gantara-branded version yet. See the Gantara help pages for
how to connect from these devices.

## These are modified, unofficial Nextcloud clients

Gantara Desktop is a modified build of the Nextcloud desktop client, and Gantara Talk is a modified
build of the Nextcloud Talk desktop client. They are **not** official Nextcloud clients and are not
provided or endorsed by Nextcloud GmbH. The changes are limited to the name, the artwork, links,
and the Linux fixes described in the folders below.

The applications do not update themselves. We publish a new version within a week of any
upstream release that fixes a security issue, and announce it in Gantara.

## Source code

Each release is built from an unmodified upstream tag plus the files in this repository, and has
its complete source attached as `Gantara_<Application>-<version>-source.tar.gz`
([Desktop](https://github.com/Dunetrails/gantara-clients/releases/download/desktop-latest/Gantara_Desktop-source.tar.gz),
[Talk](https://github.com/Dunetrails/gantara-clients/releases/download/talk-latest/Gantara_Talk-source.tar.gz)
for the newest version). The release notes name the upstream tag.

| Folder | What it is | Upstream |
|--|--|--|
| [`clients/desktop`](clients/desktop) | Branding and build scripts for Gantara Desktop | [nextcloud/desktop](https://github.com/nextcloud/desktop) |
| [`clients/talk-desktop`](clients/talk-desktop) | Branding, Linux tray helper and build scripts for Gantara Talk | [nextcloud/talk-desktop](https://github.com/nextcloud/talk-desktop) |
| [`server/nextcloud-tenant`](server/nextcloud-tenant) | The server image Gantara runs, including `patch-apps.sh`, the one change Gantara makes to upstream server-side code (the Google import app `integration_google` requests narrower permissions), and `gantara_isolation`, Gantara's own Nextcloud app that applies the "share with group members only" rule to calendars, contacts and Deck on the shared instance | [nextcloud/server](https://github.com/nextcloud/server), [nextcloud/integration_google](https://github.com/nextcloud/integration_google) |
| [`build/workflows`](build/workflows) | The build pipelines that produce the releases, for reference | — |

To rebuild a release: check out the upstream tag named in its release notes, run the folder's
`apply-branding.sh` against it, and follow the steps in the build pipeline for that application.

## Licences

The upstream programs keep their own licences: the Nextcloud desktop client is GPL-2.0-or-later,
the Talk desktop client and the Nextcloud server and apps are AGPL-3.0-or-later. The scripts and
patches in this repository are published under the same licence as the program they modify.
Which part is under which licence, and where the full texts and third-party notices are:
[LICENSING.md](LICENSING.md).

The Gantara name and logo are trademarks of Dunetrails BV and are not covered by these licences.
Nextcloud and the Nextcloud logo are registered trademarks of Nextcloud GmbH.

## Contact

Dunetrails BV, Schauwegemstraat 37, 9090 Merelbeke-Melle, Belgium — hello@dunetrails.com
