# Signatures and how to check a download

Every Gantara Desktop and Gantara Talk release has these kinds of proof that a file is ours and
unchanged:

| What | Covers | Signed with |
|--|--|--|
| `Gantara_<App>-<version>-SHA256SUMS.txt` | SHA-256 of every file in the release: Windows installer, macOS package, AppImage, source tarball | — |
| `Gantara_<App>-<version>-SHA256SUMS.txt.sigstore.json` | The checksum file above | [Sigstore](https://www.sigstore.dev/), keyless, by our release pipeline on GitHub Actions |
| Authenticode signature inside the Windows installer | The installer and every program file and library it installs | Azure Artifact Signing, as Dunetrails BV |
| Developer ID signature and notarisation ticket on the macOS package | The disk image or installer, and the app inside it | Apple Developer ID, as Dunetrails, notarised by Apple |

The fixed `desktop-latest` and `talk-latest` releases carry the same files without the version in
their names (`Gantara_Desktop-SHA256SUMS.txt`, and so on).

`Gantara_<App>-<version>-signing.json` says whether that release's Windows installer is
Authenticode-signed (`{"windows":{"authenticode":true}}`). Releases from before Windows signing
was set up are not, and say so in their release notes. The AppImages carry no embedded signature;
the signed checksum file covers them.

## Check a download

### 1. The checksum

Download the checksum file of the release next to the file you downloaded.

Linux and macOS:

```sh
sha256sum -c --ignore-missing Gantara_Desktop-SHA256SUMS.txt
```

Windows (PowerShell): compare the output with the line for that file in the checksum file.

```powershell
(Get-FileHash .\Gantara_Desktop-x64-setup.exe -Algorithm SHA256).Hash.ToLower()
```

### 2. The signature on the checksum file

This proves the checksum file was produced by our release pipeline and not changed since. Install
[cosign](https://docs.sigstore.dev/cosign/system_config/installation/) (version 3 or newer), download
the `.sigstore.json` file next to the checksum file, and run:

```sh
cosign verify-blob \
  --bundle Gantara_Desktop-SHA256SUMS.txt.sigstore.json \
  --certificate-identity https://github.com/Dunetrails/k8s-platform-ovh/.github/workflows/publish-public-clients.yml@refs/heads/main \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  Gantara_Desktop-SHA256SUMS.txt
```

It prints `Verified OK`. Any other output means: do not install the file, and tell us at
hello@dunetrails.com. The identity is the GitHub Actions workflow that publishes the releases; it
lives in our private platform repository, and only its runs on the `main` branch can sign.

For Gantara Talk, use the `Gantara_Talk-` files instead.

### 3. The Windows signature

For releases whose `signing.json` says `"authenticode":true`: right-click the installer, choose
*Properties*, then *Digital Signatures*. The signer is *Dunetrails BV* and the signature has a
timestamp. Or in PowerShell:

```powershell
Get-AuthenticodeSignature .\Gantara_Desktop-x64-setup.exe | Format-List Status, SignerCertificate
```

`Status` must be `Valid`. Windows SmartScreen can still warn about a correctly signed installer
for a while after a release: it trusts a new file once enough people have downloaded it. Choose
*More info*, then *Run anyway*.

### 4. The macOS signature

macOS checks this itself: Gatekeeper only opens a downloaded app that is signed with a Developer
ID and notarised by Apple, so a damaged or altered app does not start. To see it before opening
the download, in Terminal:

```sh
spctl -a -vvv -t open --context context:primary-signature Gantara_Talk-macos-universal.dmg
```

It must say `accepted`, `source=Notarized Developer ID` and
`origin=Developer ID Application: Dunetrails (…)`. After installing, the same check on the app:

```sh
spctl -a -vvv "/Applications/Gantara Talk.app"
```

macOS packages are only released signed and notarised; there is no unsigned macOS release.

## How the signing works

The builds run in GitHub Actions in our platform repository; this repository receives the source
and the finished releases (`build/workflows` has copies of the build pipelines).

**Windows (Authenticode).** The Windows jobs sign with
[Azure Artifact Signing](https://learn.microsoft.com/azure/artifact-signing/) through `signtool`
and Microsoft's Artifact Signing dlib, the same tools and versions as
[azure/artifact-signing-action](https://github.com/Azure/artifact-signing-action). GitHub logs in
to Azure with OpenID Connect, so no password or key is stored in GitHub, and the signing key
never leaves Microsoft's HSMs. Every signature is SHA-256 with an RFC 3161 timestamp from
`http://timestamp.acs.microsoft.com`, so it stays valid after the short-lived certificate expires.

- Gantara Desktop: KDE Craft signs every `.exe` and `.dll` it collects for the installer, then the
  NSIS installer itself.
- Gantara Talk: Electron Forge signs the `.exe`, `.dll` and `.node` files of the packaged app,
  Squirrel signs `Update.exe` and the setup.
- The job then runs `signtool verify /pa` on the installer and on every binary inside it, and
  fails if any of them is unsigned or has no timestamp.

Signing is switched on by repository variables. Without them the builds stay unsigned, which
`signing.json` and the release notes then say.

**macOS (Developer ID and notarisation).** The macOS jobs run on GitHub's macOS runners. The
Developer ID certificates of Dunetrails are imported into a keychain that exists only for the
job and is deleted at its end. Everything is signed with the hardened runtime and a secure
timestamp from Apple, then submitted to Apple's notary service, which scans it and issues a
ticket; the ticket is stapled to the file, so Gatekeeper can check it offline.

- Gantara Talk: Electron Forge signs every executable, framework and library of the universal
  (Apple Silicon and Intel) app and has it notarised. The job then signs, notarises and staples
  the DMG around it.
- Afterwards the job checks the DMG and the app inside with `codesign --verify --deep --strict`,
  `spctl` and `stapler validate`, and fails if any of them is not signed by our team, lacks the
  hardened runtime or has no ticket.

**Checksums (Sigstore).** After the builds, the publishing workflow writes the checksum file from
the SHA-256 digests GitHub computed on upload and signs it with
[cosign](https://github.com/sigstore/cosign) in keyless mode: GitHub vouches for the workflow's
identity, Sigstore's Fulcio issues a certificate valid for ten minutes, and the signature is
recorded in the public [Rekor](https://search.sigstore.dev/) transparency log. There is no
private key to keep or leak. The bundle holds the certificate, the signature and the log entry,
so `cosign verify-blob` works without contacting us.

## Rotation and revocation

- **Sigstore:** nothing to rotate; every signature has its own ten-minute certificate. The
  identity in the command above only changes if the publishing workflow is renamed or moves to
  another repository. Then this page and the download page get the new identity, and older bundles
  keep verifying with the old one.
- **Windows certificate:** Azure Artifact Signing renews the certificate daily on its own. The
  organisation's identity validation has to be renewed when it expires; Microsoft emails 60 days
  before. Without renewal the Windows builds fail at the signing step, they do not ship unsigned.
- **macOS certificates:** Developer ID certificates are renewed about once a year. What was signed
  before one expires keeps opening, because the signatures are timestamped and the notarisation tickets stay
  valid. If the key were ever exposed, we would revoke the certificates at Apple; Gatekeeper then
  rejects everything signed with them, so a rebuild with new certificates would follow at once.
- **Access from GitHub (Windows):** no secret to rotate. Access is a federated credential trusting only
  the `main` branch of the platform repository, plus the *Artifact Signing Certificate Profile
  Signer* role on one certificate profile. Removing either stops signing at once.
- **If a signed file or the signing access were misused:** remove the role assignment, then
  revoke the affected certificate in the Azure portal (Artifact Signing account → *Certificate
  profiles* → the profile → search the certificate's thumbprint → *Revoke*, with the time from
  which signatures are no longer trusted). The certificates live for three days, so a revocation
  only touches what was signed with that one certificate; signatures made before the revocation
  time stay valid.
