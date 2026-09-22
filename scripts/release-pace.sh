#!/usr/bin/env bash
#
# release-pace.sh — Ship a new Pace release with auto-update support.
#
# What it does:
#   1. Reads the current version from leanring-buddy/Info.plist (or bumps it).
#   2. Builds Pace.app unsigned in isolated DerivedData.
#   3. Developer ID signs Pace and packages a notarized, stapled DMG.
#   4. Signs the package with Sparkle's sign_update (uses the private key
#      stored in your Mac's Keychain — generated once via Sparkle's
#      generate_keys; see SUPublicEDKey in Info.plist for the matching
#      public key).
#   5. Pushes the package + release notes to a GitHub Release via `gh`.
#   6. Regenerates appcast.xml with the new entry on top.
#   7. Commits + pushes appcast.xml so the SUFeedURL serves it instantly.
#
# Signed DMG release (requires Apple Developer Program):
#   Set these env vars before running:
#     PACE_NOTARY_PROFILE  — keychain profile name created via:
#       xcrun notarytool store-credentials "pace-notary" \
#         --apple-id <apple-id> --team-id <team-id> --password <app-password>
#     PACE_DEVELOPER_ID    — Developer ID Application cert name
#       (e.g. "Developer ID Application: Your Name (XXXXXXXXXX)")
#   The identity is auto-detected when PACE_DEVELOPER_ID is omitted. A
#   notarytool profile must be named with PACE_NOTARY_PROFILE or the shared
#   APPLE_NOTARY_PROFILE. Public releases fail closed if either is unavailable.
#
# Prereqs (one-time):
#   - Xcode with command-line tools (`xcode-select --install`)
#   - `brew install gh`, `gh auth login` (personal GitHub account)
#   - Sparkle EdDSA key already generated (was: ./generate_keys)
#   - For signed DMG: Apple Developer Program + notarytool profile
#
# Usage:
#   ./scripts/release-pace.sh           # bump patch, e.g. 0.3.0 → 0.3.1
#   ./scripts/release-pace.sh 0.4.0     # exact version
#
# After running, every existing Pace install pings the appcast within
# the next hour (or on next launch) and offers the update.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GITHUB_REPO="HeyPace/pace"
APP_NAME="Pace"
SCHEME="leanring-buddy"
INFO_PLIST="${PROJECT_DIR}/leanring-buddy/Info.plist"
ENTITLEMENTS_PATH="${PROJECT_DIR}/leanring-buddy/leanring-buddy.entitlements"
APPCAST_PATH="${PROJECT_DIR}/appcast.xml"
BUILD_DIR="${PROJECT_DIR}/build/release"
RELEASES_DIR="${PROJECT_DIR}/releases"

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# xcodebuild lives in Xcode.app, not the Command Line Tools shim. Many
# Macs default xcode-select to /Library/Developer/CommandLineTools and
# xcodebuild fails with "requires Xcode" in that state. Probe known full-Xcode
# locations (the beta has lived under both /Applications and ~/Downloads) so
# the release works regardless of the user's xcode-select state.
if [ -z "${DEVELOPER_DIR:-}" ]; then
    for candidateDeveloperDir in \
        "/Applications/Xcode-26.6.0.app/Contents/Developer" \
        "/Applications/Xcode-27.0.0-Beta.app/Contents/Developer" \
        "/Applications/Xcode-beta.app/Contents/Developer" \
        "/Users/sarthak/Downloads/Xcode-beta.app/Contents/Developer" \
        "/Applications/Xcode.app/Contents/Developer"; do
        if [ -d "$candidateDeveloperDir" ]; then
            export DEVELOPER_DIR="$candidateDeveloperDir"
            break
        fi
    done
fi

SPARKLE_BIN=$(find ~/Library/Developer/Xcode/DerivedData -path "*sparkle/Sparkle/bin/sign_update" 2>/dev/null | head -1)
if [ -z "$SPARKLE_BIN" ]; then
    SPARKLE_BIN=$(find /tmp/pace-test-derived-data -path "*sparkle/Sparkle/bin/sign_update" 2>/dev/null | head -1)
fi
if [ -z "$SPARKLE_BIN" ]; then
    echo "❌ Sparkle's sign_update not found. Build Pace once (Xcode or test-pace.sh) so SPM downloads Sparkle." >&2
    exit 1
fi
SPARKLE_BIN_DIR=$(dirname "$SPARKLE_BIN")

# ── Version handling ────────────────────────────────────────────────────────

current_version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST" 2>/dev/null || echo "0.0.0")
current_build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INFO_PLIST" 2>/dev/null || echo "0")

if [ $# -ge 1 ]; then
    next_version="$1"
else
    major=$(echo "$current_version" | cut -d. -f1)
    minor=$(echo "$current_version" | cut -d. -f2)
    patch=$(echo "$current_version" | cut -d. -f3)
    patch=$((patch + 1))
    next_version="${major}.${minor}.${patch}"
fi

next_build=$((current_build + 1))
tag="v${next_version}"

echo "▶ Pace release ${tag} (build ${next_build}; previous: ${current_version} build ${current_build})"

if gh release view "$tag" --repo "$GITHUB_REPO" &>/dev/null; then
    echo "❌ Release ${tag} already exists on GitHub. Bump the version: ./scripts/release-pace.sh <new-version>" >&2
    exit 1
fi

# Developer ID identities and notarytool credentials are team-scoped, not
# product-scoped. Reuse the installed team identity and any explicitly named
# Keychain profile while keeping Pace's bundle ID and Sparkle key independent.
PACE_DEVELOPMENT_TEAM="${PACE_DEVELOPMENT_TEAM:-$(awk -F' = ' '
    /DEVELOPMENT_TEAM = / {
        gsub(/;/, "", $2)
        print $2
        exit
    }
' "${PROJECT_DIR}/leanring-buddy.xcodeproj/project.pbxproj")}"
available_signing_identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
PACE_DEVELOPER_ID="${PACE_DEVELOPER_ID:-$(awk -F'"' -v team="$PACE_DEVELOPMENT_TEAM" '
    /Developer ID Application:/ && index($2, "(" team ")") > 0 {
        print $2
        exit
    }
' <<< "$available_signing_identities")}"
PACE_NOTARY_PROFILE="${PACE_NOTARY_PROFILE:-${APPLE_NOTARY_PROFILE:-}}"

if [ -z "$PACE_DEVELOPER_ID" ]; then
    echo "❌ No Developer ID Application identity is installed." >&2
    exit 1
fi
if ! grep -Fq "\"$PACE_DEVELOPER_ID\"" <<< "$available_signing_identities"; then
    echo "❌ Developer ID identity is not available: $PACE_DEVELOPER_ID" >&2
    exit 1
fi
if [ -z "$PACE_NOTARY_PROFILE" ]; then
    echo "❌ Set PACE_NOTARY_PROFILE or APPLE_NOTARY_PROFILE to an existing notarytool Keychain profile." >&2
    exit 1
fi
echo "🔐 Verifying Apple notarization credentials..."
if ! xcrun notarytool history --keychain-profile "$PACE_NOTARY_PROFILE" --output-format json >/dev/null; then
    echo "❌ Notarization profile is unavailable or invalid: $PACE_NOTARY_PROFILE" >&2
    exit 1
fi

# Dirty-tree check moved here so we fail BEFORE bumping Info.plist /
# building / publishing. If the tree is dirty, fix it (commit or stash)
# and re-run. release-pace.sh itself is the only file allowed to be in
# the dirty set since the script may be self-modifying across releases.
working_tree_status=$(git status --porcelain | grep -v "^.. scripts/release-pace.sh\$" || true)
if [ -n "$working_tree_status" ]; then
    echo "❌ Working tree has uncommitted changes. Commit or stash first:" >&2
    echo "$working_tree_status" >&2
    exit 1
fi

# Releases are cut from clean, synced main ONLY (fleet deploy standard:
# fail closed). v0.3.17 went out from a feature branch whose code had
# never landed on main — this guard exists so that can't repeat.
# PACE_RELEASE_ALLOW_NON_MAIN=1 is the explicit, logged escape hatch.
current_release_branch=$(git rev-parse --abbrev-ref HEAD)
if [ "$current_release_branch" != "main" ] && [ "${PACE_RELEASE_ALLOW_NON_MAIN:-0}" != "1" ]; then
    echo "❌ Releases are cut from main (currently on '$current_release_branch')." >&2
    echo "   Merge your branch first, or set PACE_RELEASE_ALLOW_NON_MAIN=1 to override." >&2
    exit 1
fi
git fetch origin main --quiet
if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ] && [ "${PACE_RELEASE_ALLOW_NON_MAIN:-0}" != "1" ]; then
    echo "❌ HEAD is not in sync with origin/main. Pull/push first so the release matches the reviewed code." >&2
    exit 1
fi

# Walk the hardware-path smoke checklist before every release — the
# unit suite injects synthetic samples and is structurally blind to
# audio/capture defects (the v0.3.17 sample-rate bug shipped 1079-green).
echo "▶ Pre-release: confirm the hardware smoke checklist has been walked:"
echo "   docs/operations/release-smoke-checklist.md"
read -p "Checklist done? (y/N) " -n 1 -r
echo
[[ "$REPLY" =~ ^[Yy]$ ]] || { echo "Aborted — walk the checklist first."; exit 0; }

read -p "Proceed? (y/N) " -n 1 -r
echo
[[ "$REPLY" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ── Bump Info.plist before building ────────────────────────────────────────

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $next_version" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $next_build" "$INFO_PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $next_build" "$INFO_PLIST"

# ── Build Release ──────────────────────────────────────────────────────────

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$RELEASES_DIR"

echo "📦 Building Pace.app (Release)..."
# Build unsigned in isolated DerivedData, then apply one stable Developer ID
# identity to every nested framework and the outer app. This prevents Xcode
# from selecting an unrelated Apple Development team from the Keychain.
if ! xcodebuild \
    -project "${PROJECT_DIR}/leanring-buddy.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$BUILD_DIR" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    MARKETING_VERSION="$next_version" \
    CURRENT_PROJECT_VERSION="$next_build" \
    > "$BUILD_DIR/build.log" 2>&1; then
    echo "❌ Release build failed. Tail of $BUILD_DIR/build.log:" >&2
    tail -40 "$BUILD_DIR/build.log" >&2
    exit 1
fi

APP_PATH="$BUILD_DIR/Build/Products/Release/${APP_NAME}.app"
if [ ! -d "$APP_PATH" ]; then
    echo "❌ Build failed. Tail of $BUILD_DIR/build.log:" >&2
    tail -40 "$BUILD_DIR/build.log" >&2
    exit 1
fi
echo "✅ Built ${APP_PATH}"

# ── Bundle TTS launcher script so PaceTTSSidecarLauncher finds it in the
# installed app (otherwise auto-start only works in dev builds where the
# hardcoded repo-path fallback fires). The Resources/ path is the first
# location the launcher probes via Bundle.main.resourceURL.
mkdir -p "${APP_PATH}/Contents/Resources/scripts"
cp "${PROJECT_DIR}/scripts/start-tts-server.sh" "${APP_PATH}/Contents/Resources/scripts/start-tts-server.sh"
chmod +x "${APP_PATH}/Contents/Resources/scripts/start-tts-server.sh"
echo "✅ Bundled start-tts-server.sh into Resources/"

# Sparkle arrives with its upstream Team ID. Re-sign nested frameworks before
# the outer app so dyld sees one identity throughout the bundle. Developer ID
# releases require both a secure timestamp and the hardened-runtime flag.
echo "🔐 Signing embedded frameworks with $PACE_DEVELOPER_ID..."
find "${APP_PATH}/Contents/Frameworks" -maxdepth 2 -name "*.framework" -type d 2>/dev/null | while IFS= read -r framework_path; do
    codesign --force --deep --options runtime --timestamp --sign "$PACE_DEVELOPER_ID" "${framework_path}" 2>&1 | tail -1
done
codesign --force --deep --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS_PATH" \
    --sign "$PACE_DEVELOPER_ID" "${APP_PATH}" 2>&1 | tail -1
codesign --verify --deep --strict --verbose=2 "${APP_PATH}" && echo "✅ Developer ID codesign verification passed"
# Show the signing Authority so the user can confirm TCC will preserve
# grants — same Authority on every release = same TCC identity = grants
# kept.
codesign -dvv "${APP_PATH}" 2>&1 | grep -E "Authority|Identifier|Runtime Version" | head -4

# ── Package, notarize, staple, and Sparkle-sign ────────────────────────────
# Public releases fail closed instead of publishing an ad-hoc archive. The
# non-publishing prepare-release helper remains available for local candidates.

package_name=""
package_path=""

# Release order: build unsigned → sign with Developer ID → create DMG → sign
# DMG → notarize → staple → Sparkle-sign.

    dmg_name="Pace-${next_version}.dmg"
    dmg_path="${RELEASES_DIR}/${dmg_name}"
    rm -f "$dmg_path"
    package_name="$dmg_name"
    package_path="$dmg_path"

    echo "💿 Creating DMG → $dmg_name"
    # hdiutil create with -srcfolder is the simplest DMG creation path.
    # -format UDZO gives compressed read-only DMG. -fs HFS+ for max compat.
    hdiutil create \
        -volname "Pace ${next_version}" \
        -srcfolder "$APP_PATH" \
        -fs HFS+ \
        -format UDZO \
        -imagekey zlib-level=9 \
        "$dmg_path"

    echo "🔏 Signing DMG with Developer ID..."
    codesign --force --timestamp --sign "$PACE_DEVELOPER_ID" "$dmg_path"
    codesign --verify "$dmg_path" && echo "✅ DMG codesign verify passed"

    echo "📤 Notarizing DMG with Apple (this can take 2-10 minutes)..."
    notarization_receipt="${BUILD_DIR}/Pace-${next_version}-notarization.json"
    xcrun notarytool submit "$dmg_path" \
        --keychain-profile "$PACE_NOTARY_PROFILE" \
        --wait \
        --output-format json > "$notarization_receipt"
    python3 - "$notarization_receipt" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as receipt_file:
    receipt = json.load(receipt_file)
if receipt.get("status") != "Accepted":
    raise SystemExit(f"Apple notarization was not accepted: {receipt.get('status', 'unknown')}")
print(f"✅ Apple notarization accepted: {receipt.get('id', 'unknown')}")
PY

    echo "📎 Stapling notarization ticket to DMG..."
    xcrun stapler staple "$dmg_path"
    xcrun stapler validate "$dmg_path" && echo "✅ Notarization staple validated"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg_path"

    echo "🔐 Signing DMG with Sparkle EdDSA key..."
    signature_line=$("${SPARKLE_BIN_DIR}/sign_update" "$dmg_path")
    echo "   ${signature_line}"
    ed_signature=$(echo "$signature_line" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
    package_size=$(echo "$signature_line" | sed -n 's/.*length="\([^"]*\)".*/\1/p')
    if [ -z "$ed_signature" ] || [ -z "$package_size" ]; then
        echo "❌ Could not parse sign_update output." >&2
        exit 1
    fi
# ── Publish GitHub Release ─────────────────────────────────────────────────

echo "🏷  Publishing GitHub Release $tag..."
# Use hand-written release notes from docs/release-notes/<version>.md when
# present (so the GitHub release + Sparkle changelog show a real "what's new"
# instead of a generic string); otherwise fall back to the generic note.
notes_file="${PROJECT_DIR}/docs/release-notes/${next_version}.md"
if [ -f "$notes_file" ]; then
    echo "   using release notes from ${notes_file}"
    release_notes_args=(--notes-file "$notes_file")
else
    release_notes_args=(--notes "Pace ${next_version} (build ${next_build}) — auto-update enabled.")
fi
gh release create "$tag" "$package_path" \
    --repo "$GITHUB_REPO" \
    --title "Pace ${next_version}" \
    "${release_notes_args[@]}" \
    --latest

download_url="https://github.com/${GITHUB_REPO}/releases/download/${tag}/${package_name}"

# ── Update appcast.xml ─────────────────────────────────────────────────────

pub_date=$(date -u +"%a, %d %b %Y %H:%M:%S +0000")
new_item=$(cat <<EOF
        <item>
            <title>Pace ${next_version}</title>
            <pubDate>${pub_date}</pubDate>
            <sparkle:version>${next_build}</sparkle:version>
            <sparkle:shortVersionString>${next_version}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
            <enclosure url="${download_url}" length="${package_size}" type="application/octet-stream" sparkle:edSignature="${ed_signature}"/>
        </item>
EOF
)

python3 - "$APPCAST_PATH" "$new_item" <<'PY'
import sys, pathlib, re
path, new_item = pathlib.Path(sys.argv[1]), sys.argv[2]
text = path.read_text() if path.exists() else None
if not text or "<channel>" not in text:
    text = """<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <title>Pace</title>
        <description>Auto-update feed for Pace, the local-only macOS voice companion.</description>
        <language>en</language>
    </channel>
</rss>
"""
text = re.sub(r"(<channel>\n(?:[^<]*<(?:title|description|language)>[^<]*</(?:title|description|language)>\n)*)", r"\1" + new_item + "\n", text, count=1)
path.write_text(text)
PY

echo "✅ appcast.xml updated"

# ── Commit appcast + version bump via auto-merged PR ──────────────────────
# main is branch-protected (no direct push), so the appcast update goes
# through a release branch + PR + squash-merge via `gh`. End result is
# identical to a direct push but respects the protection rule.

cd "$PROJECT_DIR"
release_branch="release/${tag}"

current_branch=$(git rev-parse --abbrev-ref HEAD)
git checkout -B "$release_branch"
# Include scripts/release-pace.sh in the release commit if the script
# itself was edited as part of this release (e.g. shipping a fix to the
# release pipeline alongside the bump). The pre-flight dirty-tree check
# at the top of the script already cleared every OTHER file.
git add "$APPCAST_PATH" "$INFO_PLIST" "$0"
git commit -m "Release Pace ${next_version} (build ${next_build}): appcast entry + version bump"
git push -u origin "$release_branch"

pr_url=$(gh pr create \
    --base main \
    --head "$release_branch" \
    --title "Release Pace ${next_version}" \
    --body "Appcast entry + Info.plist bump for the ${tag} GitHub Release. Auto-generated by scripts/release-pace.sh." \
    2>&1 | tail -1)
echo "🔗 PR: $pr_url"

# Squash-merge via gh; --delete-branch cleans up the release branch
# both remotely and locally.
gh pr merge --squash --delete-branch "$pr_url"

# Return to the branch we started on (typically main) and fast-forward.
git checkout "$current_branch" 2>/dev/null || git checkout main
git pull --rebase --autostash

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "✅ Pace ${next_version} released"
echo "   Download: ${download_url}"
echo "   Appcast:  https://raw.githubusercontent.com/${GITHUB_REPO}/main/appcast.xml"
echo "   Existing installs check the appcast within an hour (or on next launch)."
echo "═══════════════════════════════════════════════════════════════"
