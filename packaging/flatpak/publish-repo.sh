#!/bin/sh
# Builds Lurker's Flatpak repository, served from GitHub Pages, out of a bundle
# from flatpak-builder: the signed repository, .flatpakrepo and .flatpakref files
# to add it, and a bundle that installs from it, so installs get updates.
#
# Usage: publish-repo.sh BUNDLE KEY_ID OUT_DIR OUT_BUNDLE
# The signing key must be in gpg's keyring ($GNUPGHOME). Lurker's public key is
# lurker.gpg next to this script.
set -eu

bundle=$1 key=$2 out=$3 out_bundle=$4
url=${LURKER_REPO_URL:-https://sp1r17.github.io/lurker}
app=io.github.sp1r17.Lurker
flathub=https://dl.flathub.org/repo/flathub.flatpakrepo
pubkey=$(dirname "$0")/lurker.gpg
gpg_home=${GNUPGHOME:+--gpg-homedir=$GNUPGHOME}

# Only the latest release is kept: clients pull whatever the branch points at.
rm -rf "$out"
# An empty archive-mode OSTree repository, as `ostree init --mode=archive` makes.
mkdir -p "$out/repo/objects" "$out/repo/refs/heads" "$out/repo/refs/remotes" \
	"$out/repo/state" "$out/repo/tmp"
printf '[core]\nrepo_version=1\nmode=archive-z2\n' > "$out/repo/config"
flatpak build-import-bundle --gpg-sign="$key" $gpg_home "$out/repo" "$bundle"
flatpak build-update-repo --gpg-sign="$key" $gpg_home --generate-static-deltas \
	--title=Lurker --default-branch=master "$out/repo"

flatpak build-bundle --repo-url="$url/repo/" --runtime-repo="$flathub" \
	--gpg-keys="$pubkey" "$out/repo" "$out_bundle" "$app" master

gpg_key=$(base64 -w0 "$pubkey")
cat > "$out/lurker.flatpakrepo" <<EOF
[Flatpak Repo]
Title=Lurker
Url=$url/repo/
Homepage=https://github.com/sp1r17/lurker
Comment=A Twitch app for watching streams, videos and chat
DefaultBranch=master
GPGKey=$gpg_key
EOF
cat > "$out/lurker.flatpakref" <<EOF
[Flatpak Ref]
Name=$app
Branch=master
Title=Lurker
Url=$url/repo/
SuggestRemoteName=lurker
RuntimeRepo=$flathub
IsRuntime=false
GPGKey=$gpg_key
EOF
cat > "$out/index.html" <<EOF
<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Lurker Flatpak repository</title>
<p>Lurker's Flatpak repository. To install Lurker and get its updates with
<code>flatpak update</code>:</p>
<pre>flatpak install --user $url/lurker.flatpakref</pre>
<p>See <a href="https://github.com/sp1r17/lurker">Lurker on GitHub</a>.</p>
EOF
