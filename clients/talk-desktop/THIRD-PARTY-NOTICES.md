# Gantara Talk — licences and third-party notices

Gantara Talk is a modified build of the Nextcloud Talk desktop client
(<https://github.com/nextcloud/talk-desktop>). It is not official Nextcloud software and is not
provided or endorsed by Nextcloud GmbH. Nextcloud, Nextcloud Talk and the Nextcloud logo are
registered trademarks of Nextcloud GmbH. The Gantara name and logo are trademarks of Dunetrails BV
and are not covered by the licences below.

## The application

Copyright (C) Nextcloud GmbH and Nextcloud contributors. Modifications (name, artwork, links, the
Linux tray helper and packaging) by Dunetrails BV.

The client, and the Nextcloud Talk web application it bundles (<https://github.com/nextcloud/spreed>),
are free software: you can redistribute them and/or modify them under the terms of the GNU Affero
General Public License as published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version. The full text is in `LICENSE`.

They are distributed in the hope that they will be useful, but WITHOUT ANY WARRANTY; without even
the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

## Source code

Each release has a `Gantara_Talk-<version>-source.tar.gz` attached at
<https://github.com/Dunetrails/gantara-clients/releases>: the upstream talk-desktop tag it was
built from, the Nextcloud Talk (spreed) tag that tag bundles, and the Gantara scripts that rebrand
and package them. The JavaScript dependencies are pinned by the `package-lock.json` files in those
trees and are fetched from the npm registry at build time.

**Written offer.** For at least three years after we last distribute a given version, Dunetrails
BV will give anyone who asks a complete copy of the corresponding source code of that version,
including its dependencies, on a medium customarily used for software interchange, for no more
than the cost of providing it. Write to hello@dunetrails.com or Dunetrails BV,
Schauwegemstraat 37, 9090 Merelbeke-Melle, Belgium.

## Third-party components

Licence texts are in the `LICENSES` folder next to this file, named by their SPDX identifier.

| Component | Licence | Project |
|--|--|--|
| Electron | MIT (its own `LICENSE` ships next to the executable) | <https://github.com/electron/electron> |
| Chromium and its third-party code | Various; listed in `LICENSES.chromium.html` next to the executable | <https://www.chromium.org/> |
| Node.js (inside Electron) | MIT | <https://github.com/nodejs/node> |
| npm packages bundled into the application | Mostly MIT, ISC, BSD and Apache-2.0; each package's licence is in its `package.json` and in the licence comments kept in the bundled scripts | <https://www.npmjs.com/> |
| Notification sounds | CC0-1.0 | <https://github.com/nextcloud/talk-desktop> |
| Linux tray helper (`sni_tray.py`, Gantara) | AGPL-3.0-or-later | <https://github.com/Dunetrails/gantara-clients> |
