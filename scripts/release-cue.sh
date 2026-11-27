#!/bin/bash
set -euo pipefail

for name in GH_TOKEN RELEASE_TAG APPLE_CERTIFICATE_BASE64 APPLE_ID APPLE_APP_PASSWORD APPLE_TEAM_ID SPARKLE_PRIVATE_KEY SPARKLE_PUBLIC_KEY; do
    if [[ -z "${!name:-}" ]]; then
        echo "Missing release configuration: $name" >&2
        exit 1
    fi
done
: "${APPLE_CERTIFICATE_PASSWORD?Missing certificate password}"
: "${GITHUB_REPOSITORY?Missing repository}"
: "${RUNNER_TEMP?Run this on a GitHub-hosted macOS runner}"

if [[ ! "$RELEASE_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Expected a stable release tag like v0.1.16" >&2
    exit 1
fi

version="${RELEASE_TAG#v}"
work=$(mktemp -d "$RUNNER_TEMP/cue-release.XXXXXX")
keychain="$work/signing.keychain-db"
trap 'security delete-keychain "$keychain" >/dev/null 2>&1 || true; rm -rf "$work"' EXIT
feed="$work/feed"
updates="$work/updates"
mkdir "$feed" "$updates"
archive="$updates/Cue-$version-universal.zip"

git init -q -b appcast "$feed"
git -C "$feed" config user.name 'github-actions[bot]'
git -C "$feed" config user.email '41898282+github-actions[bot]@users.noreply.github.com'
gh auth setup-git --hostname github.com
git -C "$feed" remote add origin "https://github.com/$GITHUB_REPOSITORY.git"
feed_ref=$(git -C "$feed" ls-remote origin refs/heads/appcast)
if [[ -n "$feed_ref" ]]; then
    git -C "$feed" fetch --depth=1 origin refs/heads/appcast
    git -C "$feed" reset --hard FETCH_HEAD
fi

xcodebuild -project Cue.xcodeproj -scheme Cue -configuration Release \
    -derivedDataPath "$work/build" -destination 'generic/platform=macOS' \
    ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO \
    SPARKLE_PUBLIC_KEY="$SPARKLE_PUBLIC_KEY" build

app="$work/build/Build/Products/Release/Cue.app"
plist="$app/Contents/Info.plist"
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" != "$version" ]]; then
    echo "The release tag must match MARKETING_VERSION in project.yml" >&2
    exit 1
fi
build_number=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")
python3 - "$build_number" "$feed/appcast.xml" "$RELEASE_TAG" <<'PY'
import pathlib
import sys
import xml.etree.ElementTree as ET

build, filename, tag = sys.argv[1:]
if not build.isascii() or not build.isdecimal() or int(build) < 1:
    sys.exit("Use a positive integer CURRENT_PROJECT_VERSION")
if pathlib.Path(filename).exists():
    feed = ET.parse(filename)
    ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
    for item in feed.findall("./channel/item"):
        previous = int(item.findtext("sparkle:version", namespaces=ns))
        enclosure = item.find("enclosure")
        same_release = f"/download/{tag}/" in enclosure.get("url", "")
        if previous > int(build) or (previous == int(build) and not same_release):
            sys.exit("Increase CURRENT_PROJECT_VERSION above the published build")
PY

if gh release view "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
    # A rerun after a feed-publishing failure must sign the ZIP already on GitHub.
    gh release download "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" \
        --pattern "$(basename "$archive")" --dir "$updates"
else
    lipo "$app/Contents/MacOS/Cue" -verify_arch arm64 x86_64
    keychain_password=$(openssl rand -hex 24)
    cert="$work/developer-id.p12"
    printf '%s' "$APPLE_CERTIFICATE_BASE64" | base64 --decode > "$cert"
    security create-keychain -p "$keychain_password" "$keychain"
    security unlock-keychain -p "$keychain_password" "$keychain"
    security import "$cert" -k "$keychain" -f pkcs12 -P "$APPLE_CERTIFICATE_PASSWORD" -T /usr/bin/codesign
    security set-key-partition-list -S apple-tool:,apple: -s -k "$keychain_password" "$keychain"
    identity=$(security find-identity -v -p codesigning "$keychain" | awk '/"Developer ID Application:/ {print $2; exit}')
    if [[ -z "$identity" ]]; then
        echo 'The certificate must be a Developer ID Application identity with its private key' >&2
        exit 1
    fi

    sign() {
        codesign --force --sign "$identity" --keychain "$keychain" --options runtime --timestamp "$@"
    }
    framework="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
    sign "$framework/XPCServices/Installer.xpc"
    sign --preserve-metadata=entitlements "$framework/XPCServices/Downloader.xpc"
    sign "$framework/Autoupdate"
    sign "$framework/Updater.app"
    sign "$framework"
    bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")
    sed 's/$(PRODUCT_BUNDLE_IDENTIFIER)/'"$bundle_id"'/g' Cue/Cue.entitlements > "$work/Cue.entitlements"
    sign --entitlements "$work/Cue.entitlements" "$app"
    codesign --verify --deep --strict "$app"

    ditto -c -k --keepParent "$app" "$work/notarization.zip"
    xcrun notarytool submit "$work/notarization.zip" --wait --timeout 25m \
        --apple-id "$APPLE_ID" --password "$APPLE_APP_PASSWORD" --team-id "$APPLE_TEAM_ID"
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
    ditto -c -k --keepParent "$app" "$archive"
fi

generate_appcast="$work/build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast"
printf '%s\n' "$SPARKLE_PRIVATE_KEY" | "$generate_appcast" --ed-key-file - --maximum-deltas 0 \
    --download-url-prefix "https://github.com/$GITHUB_REPOSITORY/releases/download/$RELEASE_TAG/" \
    -o "$updates/appcast.xml" "$updates"

python3 - "$updates/appcast.xml" "$archive" "$build_number" "$GITHUB_REPOSITORY" "$RELEASE_TAG" <<'PY'
import base64
import pathlib
import sys
import xml.etree.ElementTree as ET

feed, archive, build, repo, tag = sys.argv[1:]
data = pathlib.Path(feed).read_bytes()
_, marker, signatures = data.rpartition(b"<!-- sparkle-signatures:\n")
if not marker or b"edSignature:" not in signatures:
    sys.exit("Sparkle did not sign the appcast")
ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
item = ET.fromstring(data).find("./channel/item")
if item is None or item.findtext("sparkle:version", namespaces=ns) != build:
    sys.exit("The generated appcast has the wrong build number")
enclosure = item.find("enclosure")
expected_url = f"https://github.com/{repo}/releases/download/{tag}/{pathlib.Path(archive).name}"
signature_key = f"{{{ns['sparkle']}}}edSignature"
if enclosure is None or enclosure.get("url") != expected_url or enclosure.get("length") != str(pathlib.Path(archive).stat().st_size):
    sys.exit("The appcast does not point to the expected release ZIP")
if len(base64.b64decode(enclosure.get(signature_key, ""), validate=True)) != 64:
    sys.exit("The release ZIP is missing its EdDSA signature. Check the Sparkle key pair.")
PY

if ! gh release view "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
    gh release create "$RELEASE_TAG" "$archive" --repo "$GITHUB_REPOSITORY" \
        --verify-tag --title "Cue $version" --generate-notes
fi

cp "$updates/appcast.xml" "$feed/appcast.xml"
git -C "$feed" add appcast.xml
if ! git -C "$feed" diff --cached --quiet; then
    git -C "$feed" commit -m "Publish Cue $version update"
    git -C "$feed" push origin HEAD:refs/heads/appcast
fi
