#!/bin/zsh
# Prepares a release people download and update to (README "Updates"): the Developer ID signed
# bundle with Sparkle's feed and public key, the app and its disk image notarized by notarize.sh,
# and an appcast.xml for the image signed with the EdDSA key. It stops there: nothing is pushed, no
# GitHub release is made and the site is not changed; the steps that publish are printed.
#
#   YARDLET_SIGNING_IDENTITY="Developer ID Application: …" ./scripts/release.sh [options]
#
#   --appcast <file>      The appcast published now (the site's appcast.xml), so its items stay in
#                         the new one. Without it the appcast starts with this release.
#   --notes <file>        Release notes (.md or .html) for Sparkle's update window.
#   --ed-key-file <file>  Signs with this private EdDSA key file instead of the key generate_keys
#                         keeps in the login keychain.
#   --skip-notarize       Tries the steps locally: the disk image is not notarized and must not be
#                         published. Any signing identity, ad-hoc included.
#   --output <folder>     Default .build/release-<version>; it must not hold this version's image.
#
#   YARDLET_SPARKLE_FEED_URL    Default https://yardlet.app/appcast.xml.
#   YARDLET_RELAY_URL           The phone relay built in. Default https://relay.yardlet.app (relay/README.md).
#   YARDLET_SPARKLE_ACCOUNT     The login keychain account that holds the EdDSA key (default yardlet).
#   YARDLET_SPARKLE_PUBLIC_KEY  The public EdDSA key built into the app. Default: generate_keys -p,
#                               which reads it from the login keychain.
#   YARDLET_RELEASE_DOWNLOADS   Where the images are downloaded from, followed by v<version>/.
#                               Default https://github.com/zzunkie/yardlet/releases/download.
#   YARDLET_NOTARY_PROFILE      notarize.sh's keychain profile (default yardlet-notary).
#
# The version is Packaging/Info.plist's: CFBundleShortVersionString names the release and the tag
# v<version>, and Sparkle orders updates by CFBundleVersion, so raise both and commit first.
set -euo pipefail

PROJECT_ROOT=${0:A:h:h}
SCRIPTS=${0:A:h}
SPARKLE_BIN="$PROJECT_ROOT/.build/artifacts/sparkle/Sparkle/bin"
feed=${YARDLET_SPARKLE_FEED_URL:-https://yardlet.app/appcast.xml}
relay=${YARDLET_RELAY_URL:-https://relay.yardlet.app}
public_key=${YARDLET_SPARKLE_PUBLIC_KEY:-}
account=${YARDLET_SPARKLE_ACCOUNT:-yardlet}
downloads=${YARDLET_RELEASE_DOWNLOADS:-https://github.com/zzunkie/yardlet/releases/download}
downloads=${downloads%/}
website=https://yardlet.app
current_appcast=""
notes=""
ed_key_file=""
skip_notarize=0
output=""
while (( $# > 0 )); do
    case $1 in
        --appcast) current_appcast=${2:?--appcast needs a file}; shift 2 ;;
        --notes) notes=${2:?--notes needs a file}; shift 2 ;;
        --ed-key-file) ed_key_file=${2:?--ed-key-file needs a file}; shift 2 ;;
        --skip-notarize) skip_notarize=1; shift ;;
        --output|-o) output=${2:?--output needs a folder}; shift 2 ;;
        -h|--help) /usr/bin/sed -n '2,28p' "$0" | /usr/bin/sed 's/^# \{0,1\}//'; exit 0 ;;
        *) print -u2 "error: unknown argument $1"; exit 2 ;;
    esac
done
for file in $current_appcast $notes $ed_key_file; do
    [[ -f "$file" ]] || { print -u2 "error: $file does not exist"; exit 1; }
done
[[ -z "$notes" || "$notes" == *.(md|html) ]] || { print -u2 "error: release notes must be a .md or .html file"; exit 1; }
identity=${YARDLET_SIGNING_IDENTITY:--}
if (( ! skip_notarize )); then
    [[ "$identity" != "-" ]] || {
        print -u2 "error: a release is signed with Developer ID: set YARDLET_SIGNING_IDENTITY (README \"Signing and notarization\")"
        exit 1
    }
    # What is published must be a commit anyone can build again.
    [[ -z "$(/usr/bin/git -C "$PROJECT_ROOT" status --porcelain 2>/dev/null)" ]] || {
        print -u2 "error: the checkout has uncommitted changes; commit them first"; exit 1; }
fi

# Sparkle's tools come with the package SwiftPM resolved (Package.resolved pins the version).
[[ -x "$SPARKLE_BIN/generate_appcast" ]] || (cd "$PROJECT_ROOT" && swift package resolve)
[[ -x "$SPARKLE_BIN/generate_appcast" ]] || { print -u2 "error: $SPARKLE_BIN/generate_appcast is missing"; exit 1; }
if [[ -z "$public_key" ]]; then
    public_key=$("$SPARKLE_BIN/generate_keys" --account "$account" -p 2>/dev/null) || {
        print -u2 "error: no Sparkle key in the login keychain. Create it once (README \"Updates\"):"
        print -u2 "  $SPARKLE_BIN/generate_keys --account $account"
        exit 1
    }
fi

YARDLET_SIGNING_IDENTITY=$identity YARDLET_SPARKLE_FEED_URL=$feed YARDLET_SPARKLE_PUBLIC_KEY=$public_key YARDLET_RELAY_URL=$relay \
    "$SCRIPTS/build-app.sh" release
app="$PROJECT_ROOT/.build/Yardlet.app"
plist_value() { /usr/libexec/PlistBuddy -c "Print :$1" "$app/Contents/Info.plist"; }
version=$(plist_value CFBundleShortVersionString)
build=$(plist_value CFBundleVersion)
[[ "$(plist_value SUPublicEDKey)" == "$public_key" ]] || { print -u2 "error: $app does not carry the public key"; exit 1; }

output=${output:-$PROJECT_ROOT/.build/release-$version}
output=${output:A}
dmg="$output/Yardlet-$version.dmg"
[[ ! -e "$dmg" ]] || { print -u2 "error: $dmg already exists; remove it or choose another --output"; exit 1; }
/bin/mkdir -p "$output"
print "Yardlet $version (build $build) into $output"

if (( skip_notarize )); then
    # notarize.sh's image without the notary service: the app beside a link to /Applications.
    stage=$(/usr/bin/mktemp -d "${${TMPDIR:-/tmp}%/}/yardlet-release.XXXXXX")
    trap '/bin/rm -rf "$stage"' EXIT
    /usr/bin/ditto "$app" "$stage/Yardlet.app"
    /bin/ln -s /Applications "$stage/Applications"
    /usr/bin/hdiutil create -volname Yardlet -srcfolder "$stage" -format UDZO -ov "$dmg" >/dev/null
    print -u2 "note: --skip-notarize: $dmg is not notarized; do not publish it"
else
    "$SCRIPTS/notarize.sh" --output "$dmg" "$app"
fi

# generate_appcast reads every image in the folder; this release's is the only one, so its item is
# the only new one and the download prefix applies to it alone.
[[ -n "$current_appcast" ]] && /bin/cp "$current_appcast" "$output/appcast.xml"
[[ -n "$notes" ]] && /bin/cp "$notes" "$output/Yardlet-$version.${notes:e}"
key_source=(--account "$account")
[[ -n "$ed_key_file" ]] && key_source=(--ed-key-file "$ed_key_file")
"$SPARKLE_BIN/generate_appcast" "${key_source[@]}" \
    --download-url-prefix "$downloads/v$version/" \
    --full-release-notes-url "${downloads%/download}" --link "$website" \
    ${notes:+--embed-release-notes} "$output"
appcast="$output/appcast.xml"

# The item as an installed Yardlet will read it: its address, and a signature that the public key
# built into the app accepts for exactly the image's bytes.
item="//*[local-name()='item'][*[local-name()='version']='$build']"
url=$(/usr/bin/xmllint --xpath "string($item/*[local-name()='enclosure']/@url)" "$appcast")
signature=$(/usr/bin/xmllint --xpath "string($item/*[local-name()='enclosure']/@*[local-name()='edSignature'])" "$appcast")
[[ "$url" == "$downloads/v$version/Yardlet-$version.dmg" ]] || {
    print -u2 "error: the appcast's item for build $build downloads from \"$url\""; exit 1; }
/usr/bin/xcrun swift - "$public_key" "$signature" "$dmg" <<'SWIFT' || { print -u2 "error: the app's public key does not accept the appcast's signature"; exit 1; }
import CryptoKit
import Foundation
let arguments = CommandLine.arguments.suffix(3).map { $0 }
guard let key = Data(base64Encoded: arguments[0]), let signature = Data(base64Encoded: arguments[1]),
      let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: key),
      let image = FileManager.default.contents(atPath: arguments[2]),
      publicKey.isValidSignature(signature, for: image) else { exit(1) }
SWIFT
print "  appcast.xml: build $build from $url, signature accepted by the app's key"

cat <<EOF

Ready, not published. To publish $version, in this order (the appcast points at the release):
  gh release create v$version "$dmg" --repo ${${downloads#https://github.com/}%/releases/download} --title "Yardlet $version"
  cp "$appcast" <yardlet-site checkout>/appcast.xml, then commit and push the site.
EOF
