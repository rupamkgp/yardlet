#!/bin/zsh
# Notarizes a Developer ID signed Yardlet bundle and the disk image people download, and staples
# both (README "Signing and notarization", docs/BROWSER_HOST.md §7).
#
#   YARDLET_SIGNING_IDENTITY="Developer ID Application: …" ./scripts/build-app.sh release
#   ./scripts/notarize.sh [--keychain-profile <name>] [--output <file.dmg>] [path/to/Yardlet.app]
#   ./scripts/notarize.sh --dry-run [path/to/Yardlet.app]
#
# <name> is a notarytool keychain profile, stored once with `xcrun notarytool store-credentials`
# (default yardlet-notary, or YARDLET_NOTARY_PROFILE); this script never handles a password. Before
# sending anything it checks what the notary service would refuse: every Mach-O signed by Developer
# ID with a secure timestamp, executables under the hardened runtime and without get-task-allow.
# Then it submits the app as a zip and staples it, puts the stapled app and a link to /Applications
# in a disk image (default Yardlet-<version>.dmg next to the app), signs the image with the app's
# certificate, submits and staples it, and asks Gatekeeper about both. --dry-run stops after the
# checks and prints the commands it would run; nothing leaves the Mac.
set -euo pipefail

PROJECT_ROOT=${0:A:h:h}
profile=${YARDLET_NOTARY_PROFILE:-yardlet-notary}
dry_run=0
app=""
dmg=""
while (( $# > 0 )); do
    case $1 in
        --keychain-profile|-p) profile=${2:?--keychain-profile needs a name}; shift 2 ;;
        --output|-o) dmg=${2:?--output needs a path}; shift 2 ;;
        --dry-run|-n) dry_run=1; shift ;;
        -h|--help) /usr/bin/sed -n '2,16p' "$0" | /usr/bin/sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) print -u2 "error: unknown option $1"; exit 2 ;;
        *) app=$1; shift ;;
    esac
done
app=${app:-$PROJECT_ROOT/.build/Yardlet.app}
app=${app:A}
[[ -f "$app/Contents/Info.plist" ]] || { print -u2 "error: $app is not an app bundle"; exit 1; }
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist" 2>/dev/null || true)
dmg=${dmg:-${app:h}/${app:t:r}${version:+-$version}.dmg}
dmg=${dmg:A}

print "Checking $app"
/usr/bin/codesign --verify --strict --deep "$app" || { print -u2 "error: the bundle's signature does not verify"; exit 1; }

problems=()
count=0
while IFS= read -r -d '' file; do
    kind=$(/usr/bin/file -b "$file")
    [[ "$kind" == Mach-O* ]] || continue
    count=$(( count + 1 ))
    details=$(/usr/bin/codesign -dvv "$file" 2>&1 || true)
    relative=${file#$app/}
    [[ "$details" == *"Authority=Developer ID Application: "* ]] || problems+=("$relative: not signed with a Developer ID Application certificate")
    [[ "$details" == *$'\nTimestamp='* ]] || problems+=("$relative: no secure timestamp (sign with YARDLET_SIGNING_TIMESTAMP=1)")
    # Libraries take their host's runtime; every executable needs its own.
    if [[ "$kind" == *executable* ]]; then
        [[ "$details" == *"(runtime)"* || "$details" == *",runtime"* ]] || problems+=("$relative: executable without the hardened runtime")
        entitlements=$(/usr/bin/codesign -d --entitlements - --xml "$file" 2>/dev/null || true)
        [[ "$entitlements" != *com.apple.security.get-task-allow* ]] \
            || problems+=("$relative: has com.apple.security.get-task-allow (a debugging entitlement)")
    fi
done < <(/usr/bin/find "$app" -type f \( -perm -u+x -o -name '*.dylib' \) -print0)
if (( ${#problems} )); then
    print -u2 "The notary service would refuse this bundle ($count Mach-O files checked):"
    print -u2 -l -- "${problems[@]/#/  }"
    exit 1
fi
print "  $count Mach-O files: Developer ID, secure timestamp, hardened runtime"

work=$(/usr/bin/mktemp -d "${${TMPDIR:-/tmp}%/}/yardlet-notarize.XXXXXX")
trap '/bin/rm -rf "$work"' EXIT

# The disk image is signed by the certificate that signed the app, named by its SHA-1.
/usr/bin/codesign -d --extract-certificates="$work/signer" "$app" 2>/dev/null
signer=$(/usr/bin/shasum -a 1 "$work/signer0" | /usr/bin/awk '{ print toupper($1) }')
signer_name=$(/usr/bin/security find-identity -v -p codesigning | /usr/bin/awk -v want="$signer" -F'"' '
    { split($1, field, " "); if (field[2] == want) print $2 }')
[[ -n "$signer_name" ]] || { print -u2 "error: the certificate that signed the app ($signer) is not a codesigning identity in this keychain"; exit 1; }
team=$(/usr/bin/codesign -dv "$app" 2>&1 | /usr/bin/sed -n 's/^TeamIdentifier=//p')
print "  signed by $signer_name; the disk image will be too"

store_hint() {
    print -u2 "Store it once in Terminal; notarytool asks for an app-specific password (appleid.apple.com > Sign-In and Security > App-Specific Passwords) and keeps it in your login keychain:"
    print -u2 "  xcrun notarytool store-credentials ${(q)profile} --apple-id <your Apple ID email> --team-id $team"
}

archive="$work/${app:t:r}.zip"
stage="$work/dmg"
if (( dry_run )); then
    # Only whether any notarytool profile exists; the secret is not read and nothing is sent.
    /usr/bin/security find-generic-password -s com.apple.gke.notary.tool >/dev/null 2>&1 \
        || { print -u2 "note: no notarytool profile is stored in this keychain yet."; store_hint; }
    print "Dry run; would run:"
    print "  /usr/bin/xcrun notarytool history --keychain-profile ${(q)profile}   # the profile exists and signs in"
    print "  /usr/bin/ditto -c -k --keepParent ${(q)app} ${(q)archive}"
    print "  /usr/bin/xcrun notarytool submit ${(q)archive} --keychain-profile ${(q)profile} --wait --output-format json"
    print "  /usr/bin/xcrun stapler staple ${(q)app}"
    print "  /usr/bin/hdiutil create -volname ${(q)${app:t:r}} -srcfolder ${(q)stage} -format UDZO -ov ${(q)dmg}   # the stapled app and /Applications"
    print "  /usr/bin/codesign --sign $signer --timestamp ${(q)dmg}"
    print "  /usr/bin/xcrun notarytool submit ${(q)dmg} --keychain-profile ${(q)profile} --wait --output-format json"
    print "  /usr/bin/xcrun stapler staple ${(q)dmg}"
    print "  /usr/sbin/spctl --assess --type execute -vv ${(q)app}"
    print "  /usr/sbin/spctl --assess --type open --context context:primary-signature -vv ${(q)dmg}"
    exit 0
fi

# The profile first, so a missing or rejected credential stops before anything is uploaded.
if ! /usr/bin/xcrun notarytool history --keychain-profile "$profile" --output-format json >/dev/null 2>"$work/history.log"; then
    if /usr/bin/grep -q "No Keychain password item found" "$work/history.log"; then
        print -u2 "error: there is no notarytool keychain profile named \"$profile\"."
        store_hint
        exit 2
    fi
    print -u2 "error: notarytool could not sign in with the profile \"$profile\":"
    /bin/cat "$work/history.log" >&2
    exit 1
fi

submit() {
    local file=$1 result outcome submission
    print "Submitting ${file:t} to Apple's notary service (profile $profile); this usually takes a few minutes"
    result=$(/usr/bin/xcrun notarytool submit "$file" --keychain-profile "$profile" --wait --output-format json) || true
    outcome=$(print -r -- "$result" | /usr/bin/plutil -extract status raw -o - - 2>/dev/null || true)
    submission=$(print -r -- "$result" | /usr/bin/plutil -extract id raw -o - - 2>/dev/null || true)
    if [[ "$outcome" != Accepted ]]; then
        print -u2 "error: notarization of ${file:t} ended as \"${outcome:-unknown}\"${submission:+ (submission $submission)}"
        print -u2 -r -- "$result"
        [[ -n "$submission" ]] && /usr/bin/xcrun notarytool log "$submission" --keychain-profile "$profile" >&2 || true
        exit 1
    fi
    print "  accepted (submission $submission)"
}

/usr/bin/ditto -c -k --keepParent "$app" "$archive"
submit "$archive"
/usr/bin/xcrun stapler staple "$app"
/usr/bin/xcrun stapler validate "$app"

# The image people download: the stapled app, so it opens offline too, beside /Applications.
/bin/mkdir -p "$stage" "${dmg:h}"
/usr/bin/ditto "$app" "$stage/${app:t}"
/bin/ln -s /Applications "$stage/Applications"
/usr/bin/hdiutil create -volname "${app:t:r}" -srcfolder "$stage" -format UDZO -ov "$dmg" >/dev/null
/usr/bin/codesign --sign "$signer" --timestamp "$dmg"
/usr/bin/codesign --verify --strict "$dmg"
submit "$dmg"
/usr/bin/xcrun stapler staple "$dmg"
/usr/bin/xcrun stapler validate "$dmg"

/usr/sbin/spctl --assess --type execute -vv "$app"
/usr/sbin/spctl --assess --type open --context context:primary-signature -vv "$dmg"
print "Notarized and stapled: $app and $dmg"
