# Gantara Desktop — licences and third-party notices

Gantara Desktop is a modified build of the Nextcloud desktop client
(<https://github.com/nextcloud/desktop>). It is not official Nextcloud software and is not provided
or endorsed by Nextcloud GmbH. Nextcloud and the Nextcloud logo are registered trademarks of
Nextcloud GmbH. The Gantara name and logo are trademarks of Dunetrails BV and are not covered by
the licences below.

## The application

Copyright (C) Nextcloud GmbH and Nextcloud contributors, and the ownCloud and Mirall contributors
before them. Modifications (name, artwork, links and packaging) by Dunetrails BV.

The client is free software: you can redistribute it and/or modify it under the terms of the GNU
General Public License as published by the Free Software Foundation, either version 2 of the
License, or (at your option) any later version. The full text is in `COPYING`. A few upstream
files carry other compatible licences; each file's SPDX header and upstream's `REUSE.toml` say
which. The Linux package links OpenVFS (GPL-3.0), so the Linux package as a whole is distributed
under GPL-3.0-or-later.

It is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the
implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

## Source code

Each release has a `Gantara_Desktop-<version>-source.tar.gz` attached at
<https://github.com/Dunetrails/gantara-clients/releases>: the upstream tag it was built from and
the Gantara scripts that rebrand and package it. The third-party components below are built by
upstream's own toolchain at that tag: KDE Craft with Nextcloud's `craft-blueprints-kde` and
`craft-blueprints-nextcloud` (branches named in the tag's `craftmaster.ini`) on Windows, and the
container named in the tag's `.github/workflows/linux-appimage.yml` on Linux.

**Written offer.** For at least three years after we last distribute a given version, Dunetrails
BV will give anyone who asks a complete copy of the corresponding source code of that version,
including the source of every third-party component listed below, on a medium customarily used
for software interchange, for no more than the cost of providing it. Write to
hello@dunetrails.com or Dunetrails BV, Schauwegemstraat 37, 9090 Merelbeke-Melle, Belgium.

## Third-party components

The packages include these libraries. Licence texts are in the `LICENSES` folder next to this
file, named by their SPDX identifier.

| Component | Licence | Project |
|--|--|--|
| Qt 6 (Core, Gui, Widgets, Network, Qml, Quick, Svg, Sql, WebSockets, Xml, DBus, Core5Compat, ShaderTools and the other `Qt6*` libraries, QML modules and plugins) | LGPL-3.0-only; some modules are also available under GPL-2.0/GPL-3.0. Qt includes third-party code of its own, listed at <https://doc.qt.io/qt-6/licenses-used-in-qt.html> | <https://download.qt.io/official_releases/qt/> |
| OpenSSL 3 (`libssl`, `libcrypto`, `ossl-modules`) | Apache-2.0 | <https://www.openssl.org/source/> |
| QtKeychain (`qt6keychain`) | BSD-3-Clause | <https://github.com/frankosterfeld/qtkeychain> |
| KDSingleApplication | MIT | <https://github.com/KDAB/KDSingleApplication> |
| KDE Frameworks KArchive, KDBusAddons | LGPL-2.0-or-later / LGPL-2.1-or-later | <https://invent.kde.org/frameworks> |
| libp11, pkcs11 engine | LGPL-2.1-or-later | <https://github.com/OpenSC/libp11> |
| SQLite | Public domain (blessing) | <https://www.sqlite.org/> |
| zlib | Zlib | <https://zlib.net/> |
| zstd | BSD-3-Clause (or GPL-2.0) | <https://github.com/facebook/zstd> |
| bzip2 | bzip2-1.0.6 | <https://sourceware.org/bzip2/> |
| xz / liblzma | 0BSD (public domain in older releases) | <https://tukaani.org/xz/> |
| Brotli | MIT | <https://github.com/google/brotli> |
| libb2 (BLAKE2) | CC0-1.0 | <https://github.com/BLAKE2/libb2> |
| ICU | Unicode-3.0 | <https://github.com/unicode-org/icu> |
| PCRE2 | BSD-3-Clause WITH PCRE2-exception | <https://github.com/PCRE2Project/pcre2> |
| HarfBuzz | MIT-Modern-Variant | <https://github.com/harfbuzz/harfbuzz> |
| FreeType | FTL (or GPL-2.0-or-later) | <https://freetype.org/> |
| libpng | libpng-2.0 | <http://www.libpng.org/pub/png/libpng.html> |
| libjpeg-turbo (`jpeg62`, `turbojpeg`) | IJG AND BSD-3-Clause AND Zlib | <https://libjpeg-turbo.org/> |
| GLib, GIO, GObject, GModule, GThread | LGPL-2.1-or-later | <https://gitlab.gnome.org/GNOME/glib> |
| libffi | MIT | <https://github.com/libffi/libffi> |
| libxml2 | MIT | <https://gitlab.gnome.org/GNOME/libxml2> |
| GNU libiconv, gettext runtime (`intl`, `asprintf`) | LGPL-2.1-or-later | <https://www.gnu.org/software/libiconv/>, <https://www.gnu.org/software/gettext/> |
| gettext libraries (`gettextlib`, `gettextsrc`, `gettextpo`) — Windows | GPL-3.0-or-later | <https://www.gnu.org/software/gettext/> |
| GNU libunistring — Windows | LGPL-3.0-or-later (or GPL-2.0-or-later) | <https://www.gnu.org/software/libunistring/> |
| cairo — Windows | LGPL-2.1-only (or MPL-1.1) | <https://www.cairographics.org/> |
| pixman — Windows | MIT | <https://www.cairographics.org/> |
| Microsoft Visual C++ runtime (`vcruntime140`, `msvcp140`, `concrt140`, `vcomp140`, `vcamp140`, `vccorlib140`, `mfc140*`) — Windows | Microsoft Visual C++ Redistributable licence terms | <https://learn.microsoft.com/cpp/windows/latest-supported-vc-redist> |
| OpenVFS (`openvfs`, `libopenvfs`, VFS plugin) — Linux | GPL-3.0-or-later | <https://github.com/opencloud-eu/openvfs> |
| libsecret — Linux | LGPL-2.1-or-later | <https://gitlab.gnome.org/GNOME/libsecret> |
| libgpg-error — Linux | LGPL-2.1-or-later | <https://gnupg.org/software/libgpg-error/> |
| FUSE 3 library — Linux | LGPL-2.1-only | <https://github.com/libfuse/libfuse> |
| util-linux `libblkid`, `libmount` — Linux | LGPL-2.1-or-later | <https://github.com/util-linux/util-linux> |
| util-linux `libuuid` — Linux | BSD-3-Clause | <https://github.com/util-linux/util-linux> |
| libselinux — Linux | Public domain | <https://github.com/SELinuxProject/selinux> |
| GCC OpenMP runtime (`libgomp`) — Linux | GPL-3.0-or-later WITH GCC-exception-3.1 | <https://gcc.gnu.org/> |
| Expat — Linux | MIT | <https://github.com/libexpat/libexpat> |
| libglvnd (`libEGL`, `libGLX`, `libOpenGL`, `libGLdispatch`) — Linux | MIT | <https://gitlab.freedesktop.org/glvnd/libglvnd> |
| Mesa `libgbm`, `libdrm` — Linux | MIT | <https://gitlab.freedesktop.org/mesa> |
| libxcb and xcb-util libraries, libXau, libXext, libxkbcommon — Linux | MIT | <https://gitlab.freedesktop.org/xorg> |
| linuxdeploy `AppRun` — Linux | MIT | <https://github.com/linuxdeploy/linuxdeploy> |

Windows packages are built with KDE Craft and the NSIS installer system; Linux packages with
linuxdeploy and appimagetool. These tools build the package but are not part of the application.
