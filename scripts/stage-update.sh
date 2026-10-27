#!/bin/zsh
# Stage a release bundle for Yardlet > Install Update…, which replaces the installed app and restarts.
#
#   ./scripts/build-app.sh release && ./scripts/stage-update.sh [path/to/Yardlet.app]
#
# The installed app is not touched here; the person chooses when to install.
set -euo pipefail

PROJECT_ROOT=${0:A:h:h}
APP="${1:-$PROJECT_ROOT/.build/Yardlet.app}"
ROOT="${YARDLET_UPDATES_DIR:-$HOME/Library/Application Support/Yardlet/Updates}"
PLIST="$APP/Contents/Info.plist"

[[ -f "$PLIST" ]] || { print -u2 "error: $APP is not an app bundle; run ./scripts/build-app.sh release first"; exit 1; }
identifier=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$PLIST")
[[ "$identifier" == com.zzunkie.yardlet ]] || { print -u2 "error: $APP is $identifier, not the release Yardlet"; exit 1; }
/usr/bin/codesign --verify --strict --deep "$APP" || { print -u2 "error: $APP failed strict signature verification"; exit 1; }
# Install Update… replaces a team-signed (Developer ID) app only with a build that meets its
# designated requirement; say so now rather than after the restart.
INSTALLED="${YARDLET_INSTALLED_APP:-/Applications/Yardlet.app}"
if [[ -d "$INSTALLED" ]]; then
    team=$(/usr/bin/codesign -dv "$INSTALLED" 2>&1 | /usr/bin/sed -n 's/^TeamIdentifier=//p')
    if [[ -n "$team" && "$team" != "not set" ]]; then
        requirement=$(/usr/bin/codesign -d -r- "$INSTALLED" 2>/dev/null | /usr/bin/sed -n 's/^designated => //p')
        /usr/bin/codesign --verify --strict -R "=$requirement" "$APP" 2>/dev/null || {
            print -u2 "error: $INSTALLED is signed by team $team and $APP is not; build with YARDLET_SIGNING_IDENTITY (README \"Signing and notarization\")"
            exit 1
        }
    fi
fi

executable=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$PLIST")
digest=$(/usr/bin/shasum -a 256 "$APP/Contents/MacOS/$executable" | cut -d' ' -f1)
commit=$(git -C "$PROJECT_ROOT" rev-parse --short HEAD 2>/dev/null || print unknown)
branch=$(git -C "$PROJECT_ROOT" branch --show-current 2>/dev/null || true)
dirty=false
[[ -n "$(git -C "$PROJECT_ROOT" status --porcelain --untracked-files=no 2>/dev/null)" ]] && dirty=true
built=$(/bin/date -u -r "$APP/Contents/MacOS/$executable" +%Y-%m-%dT%H:%M:%SZ)

/bin/mkdir -p "$ROOT"
incoming="$ROOT/.incoming-$$"
/bin/rm -rf "$incoming"
/bin/mkdir -p "$incoming"
/usr/bin/ditto "$APP" "$incoming/Yardlet.app"
printf '{"commit":"%s","branch":"%s","dirty":%s,"builtAt":"%s","executableSHA256":"%s"}\n' \
    "$commit" "$branch" "$dirty" "$built" "$digest" > "$incoming/manifest.json"
# Yardlet reads Pending only as a whole, so the copy is renamed into place after it is complete.
/bin/rm -rf "$ROOT/Pending"
/bin/mv "$incoming" "$ROOT/Pending"
print "Staged $commit${branch:+ ($branch)}. In Yardlet, choose Yardlet > Install Update…"
