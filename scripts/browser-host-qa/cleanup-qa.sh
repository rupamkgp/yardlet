#!/bin/zsh
# Retires a QA bundle: unregisters it and its nested browser host and helper apps from
# LaunchServices (so they do not appear in app lists), then moves the bundle and the preference
# files of its bundle identifiers into a Trash folder. Refuses while any of its processes run.
# A notification registration has no public way out, so QA bundles never make one (docs/BROWSER_HOST.md §11).
# usage: cleanup-qa.sh <qa app> <trash folder name, e.g. "Yardlet QA builds 2026-09-28">
set -uo pipefail
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
app=$1
trash="$HOME/.Trash/$2"
[[ -d "$app" ]] || { echo "no bundle at $app" >&2; exit 1; }
if pgrep -f "${app}/" >/dev/null; then
    echo "processes from $app are still running" >&2
    exit 1
fi
identifier=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$app/Contents/Info.plist")
mkdir -p "$trash/Preferences"
for nested in "$app"/Contents/Frameworks/*.app/Contents/Frameworks/*.app(N) "$app"/Contents/Frameworks/*.app(N); do
    "$LSREGISTER" -u "$nested" 2>/dev/null && echo "unregistered ${nested:t}"
done
"$LSREGISTER" -u "$app" 2>/dev/null && echo "unregistered ${app:t}"
target="$trash/${app:t}"
[[ -e "$target" ]] && target="$trash/${app:t:r} $(date +%H%M%S).app"
mv "$app" "$target" && echo "moved to $target"
for plist in "$HOME"/Library/Preferences/"$identifier"*.plist(N); do
    mv "$plist" "$trash/Preferences/" && echo "moved ${plist:t}"
done
