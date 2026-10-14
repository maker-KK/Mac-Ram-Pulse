#!/bin/zsh
# Publishes a release and bumps the Homebrew tap.
# Usage: scripts/release.sh 5.3.0 path/to/notes.md
#   Requires a clean, committed tree whose Support/Info.plist version matches.
set -euo pipefail

cd "$(dirname "$0")/.."
version=${1:?version, e.g. 5.3.0}
notes=${2:?release notes markdown file}
tag="v$version"
repo="maker-KK/Mac-Ram-Pulse"
tap="$(brew --repository maker-KK/tap)"
formula="$tap/Formula/mac-ram-pulse.rb"
coauthor="Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"

[[ -z "$(git status --porcelain)" ]] || { echo "working tree is not clean" >&2; exit 1; }
plist_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Info.plist)
[[ "$version" == "$plist_version" || "$version" == "$plist_version.0" ]] \
  || { echo "Info.plist says $plist_version, not $version" >&2; exit 1; }
git rev-parse -q --verify "refs/tags/$tag" >/dev/null && { echo "$tag already exists" >&2; exit 1; }

swift test
git push origin main
git tag -a "$tag" -m "Mac Ram Pulse $version"
git push origin "$tag"
gh release create "$tag" -R "$repo" --title "Mac Ram Pulse $version" --notes-file "$notes"

# GitHub generates the tarball on first request; require two identical downloads.
url="https://github.com/$repo/archive/refs/tags/$tag.tar.gz"
sha=$(curl -fsSL "$url" | shasum -a 256 | cut -d' ' -f1)
sleep 2
[[ "$sha" == "$(curl -fsSL "$url" | shasum -a 256 | cut -d' ' -f1)" ]] || { echo "tarball hash unstable" >&2; exit 1; }

sed -i '' -E "s#^  url \".*\"#  url \"$url\"#; s#^  sha256 \".*\"#  sha256 \"$sha\"#" "$formula"
brew style maker-KK/tap
brew audit --strict --formula maker-KK/tap/mac-ram-pulse
git -C "$tap" commit -q -am "mac-ram-pulse $version" -m "$coauthor"
git -C "$tap" push -q origin main
echo "Released $tag and bumped the tap to $sha"
