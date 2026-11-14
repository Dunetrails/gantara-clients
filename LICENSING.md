# Licensing

This repository holds the changes Gantara makes to open-source Nextcloud software, and the
releases built from them. Each part keeps the licence of the program it modifies:

| Part | Licence | Full text |
|--|--|--|
| [`clients/desktop`](clients/desktop): Gantara Desktop, a modified build of the [Nextcloud desktop client](https://github.com/nextcloud/desktop) | GPL-2.0-or-later | [`LICENSE-GPL-2.0-or-later.txt`](LICENSE-GPL-2.0-or-later.txt), [`clients/desktop/COPYING`](clients/desktop/COPYING) |
| [`clients/talk-desktop`](clients/talk-desktop): Gantara Talk, a modified build of the [Nextcloud Talk desktop client](https://github.com/nextcloud/talk-desktop) | AGPL-3.0-or-later | [`LICENSE-AGPL-3.0-or-later.txt`](LICENSE-AGPL-3.0-or-later.txt), [`clients/talk-desktop/LICENSE`](clients/talk-desktop/LICENSE) |
| [`server/nextcloud-tenant`](server/nextcloud-tenant): the server image Gantara runs, including the patch to [integration_google](https://github.com/nextcloud/integration_google) | AGPL-3.0-or-later | [`LICENSE-AGPL-3.0-or-later.txt`](LICENSE-AGPL-3.0-or-later.txt), [`server/nextcloud-tenant/LICENSE`](server/nextcloud-tenant/LICENSE) |
| The shared scripts in [`clients`](clients) | The licence of the client they build | as above |

The installers bundle third-party libraries (Qt, OpenSSL, Electron and others). They are listed,
with their licences, in each client's `THIRD-PARTY-NOTICES.md`; the licence texts they cite are
in [`clients/LICENSES`](clients/LICENSES), named by SPDX identifier. The installed applications
carry the same files: in `licenses\` in the install folder of Gantara Desktop on Windows, in
`usr/share/dunetrails/licenses` inside its AppImage, and in `resources/licenses` of Gantara Talk.

Every release has the complete corresponding source attached, as
`Gantara_<Application>-<version>-source.tar.gz`.

The Gantara name and logo are trademarks of Dunetrails BV and are not covered by these licences.
Nextcloud and the Nextcloud logo are registered trademarks of Nextcloud GmbH.
