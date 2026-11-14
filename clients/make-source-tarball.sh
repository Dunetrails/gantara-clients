#!/usr/bin/env bash
#
# Build the source tarball attached to every client release, next to the
# installers it is the source of: the upstream tag exactly as published, plus
# the Gantara files that rebrand and package it, at the commit the release was
# built from. That is the GPL/AGPL corresponding source of what we distribute,
# in one download that does not depend on another project keeping its tags.
#
# Usage: make-source-tarball.sh <desktop|talk-desktop> <upstream-checkout> <upstream-tag> <platform-checkout> <out-dir>
#
# <upstream-checkout> is the untouched upstream tree at <upstream-tag> (branding
# edits in its working tree do not matter: git archive reads the commit).
# <platform-checkout> is this repo at the commit the build ran from.
#
# The archive is reproducible: entries sorted, owner and timestamps fixed to the
# overlay commit, gzip without a name or time. Two runs of the same commits
# produce the same bytes, so building Linux and Windows from one commit
# uploads the same tarball twice.

set -euo pipefail

product="${1:?usage: make-source-tarball.sh <desktop|talk-desktop> <upstream-checkout> <upstream-tag> <platform-checkout> <out-dir>}"
upstream="$(cd -- "${2:?missing upstream checkout}" && pwd)"
ref="${3:?missing upstream tag}"
platform="$(cd -- "${4:?missing platform checkout}" && pwd)"
out="${5:?missing out dir}"

case "${product}" in
    desktop)
        name="Gantara_Desktop"
        upstream_repo="nextcloud/desktop"
        workflow=".github/workflows/build-desktop-client.yml"
        overlay=(clients/desktop clients/LICENSES clients/install-appimage.sh clients/reset-linux-clients.sh
                 clients/make-source-tarball.sh "${workflow}")
        ;;
    talk-desktop)
        name="Gantara_Talk"
        upstream_repo="nextcloud/talk-desktop"
        workflow=".github/workflows/build-talk-desktop.yml"
        overlay=(clients/talk-desktop clients/LICENSES clients/embed-desktop-integration.sh
                 clients/make-source-tarball.sh "${workflow}" .github/workflows/refresh-talk-styles.yml)
        ;;
    *) echo "make-source-tarball: unknown product ${product}" >&2; exit 1 ;;
esac

version="${ref#v}"
base="${name}-${version}-source"
upstream_dir="upstream/${upstream_repo#*/}-${ref}"
upstream_commit="$(git -C "${upstream}" rev-parse HEAD)"
overlay_commit="$(git -C "${platform}" rev-parse HEAD)"
epoch="$(git -C "${platform}" log -1 --format=%ct HEAD)"

stage="$(mktemp -d)"
trap 'rm -rf "${stage}"' EXIT
root="${stage}/${base}"
mkdir -p "${root}"

git -C "${upstream}" archive --format=tar --prefix="${upstream_dir}/" HEAD | tar -x -C "${root}"
git -C "${platform}" archive --format=tar --prefix="gantara/" HEAD -- "${overlay[@]}" | tar -x -C "${root}"

talk_note=""
if [ "${product}" = "talk-desktop" ]; then
    # The Talk web app is an npm dependency, pinned in package.json to the
    # release build of a nextcloud/spreed tag. Ship the source of that tag.
    talk_spec="$(sed -n 's/.*"@nextcloud\/talk": *"\([^"]*\)".*/\1/p' "${upstream}/package.json" | head -n1)"
    talk_ref="${talk_spec##*#}"
    case "${talk_spec}" in
        github:nextcloud-releases/spreed#v*) ;;
        *) echo "make-source-tarball: unexpected @nextcloud/talk dependency: '${talk_spec}'" >&2; exit 1 ;;
    esac
    git -c advice.detachedHead=false clone -q --depth 1 --branch "${talk_ref}" \
        https://github.com/nextcloud/spreed.git "${stage}/spreed"
    talk_commit="$(git -C "${stage}/spreed" rev-parse HEAD)"
    git -C "${stage}/spreed" archive --format=tar --prefix="upstream/spreed-${talk_ref}/" HEAD | tar -x -C "${root}"
    talk_note="- \`upstream/spreed-${talk_ref}/\`: [nextcloud/spreed](https://github.com/nextcloud/spreed) at
  tag \`${talk_ref}\` (commit \`${talk_commit}\`), unmodified. This is the Nextcloud Talk web app the
  client bundles; the build installs its release build from npm as \`${talk_spec}\`."
fi

cat >"${root}/SOURCE.md" <<EOF
# ${name//_/ } ${version}: corresponding source

This archive is the complete source of the ${name//_/ } ${version} packages published at
https://github.com/Dunetrails/gantara-clients/releases.

- \`${upstream_dir}/\`: [${upstream_repo}](https://github.com/${upstream_repo}) at tag \`${ref}\`
  (commit \`${upstream_commit}\`), unmodified.
${talk_note}
- \`gantara/\`: the Gantara overlay at commit \`${overlay_commit}\` of the repository it is
  maintained in. The same files are published in https://github.com/Dunetrails/gantara-clients
  (\`clients/\`, and the build pipelines under \`build/workflows/\`).

To rebuild: copy \`${upstream_dir}\`, run the overlay's \`apply-branding.sh\` against the copy
(\`gantara/clients/${product}/branding/apply-branding.sh\`), then follow the steps of
\`gantara/${workflow}\` for the platform you need. Third-party components and their licences are
listed in \`gantara/clients/${product}/THIRD-PARTY-NOTICES.md\`.
EOF

mkdir -p "${out}"
file="${out}/${base}.tar.gz"
tar --sort=name --owner=0 --group=0 --numeric-owner --mtime="@${epoch}" \
    -C "${stage}" -cf - "${base}" | gzip -n -9 >"${file}"
printf 'make-source-tarball: %s (%s bytes, sha256 %s)\n' \
    "${file}" "$(stat -c %s "${file}")" "$(sha256sum "${file}" | cut -d' ' -f1)"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "file=${file}" >>"${GITHUB_OUTPUT}"
fi
