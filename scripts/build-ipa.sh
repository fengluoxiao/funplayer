#!/bin/bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
project_root="$PWD"
build_dir="$project_root/build"
archive_path="$build_dir/funPlayer.xcarchive"
ipa_path="$build_dir/funPlayer-unsigned.ipa"

mkdir -p "$build_dir"

xcodebuild \
  -resolvePackageDependencies \
  -project funPlayer.xcodeproj \
  -scheme funPlayer \
  -clonedSourcePackagesDirPath "$build_dir/SourcePackages" \
  2>&1 | tee "$build_dir/resolve-packages.log"

xcodebuild \
  -project funPlayer.xcodeproj \
  -scheme funPlayer \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -sdk iphoneos \
  -archivePath "$archive_path" \
  -derivedDataPath "$build_dir/DerivedData" \
  -clonedSourcePackagesDirPath "$build_dir/SourcePackages" \
  -resultBundlePath "$build_dir/Build.xcresult" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY= \
  DEVELOPMENT_TEAM= \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO \
  CURRENT_PROJECT_VERSION="${GITHUB_RUN_NUMBER:-1}" \
  archive 2>&1 | tee "$build_dir/archive.log"

app_path="$archive_path/Products/Applications/funPlayer.app"
if [[ ! -f "$app_path/Info.plist" || ! -f "$app_path/funPlayer" ]]; then
  echo '::error::Archive does not contain the expected funPlayer.app executable and Info.plist.'
  exit 1
fi

# Unsigned archives cannot use Xcode's signed distribution export.
# An IPA is a ZIP whose root contains Payload/<App>.app.
mkdir -p "$build_dir/ipa/Payload"
/usr/bin/ditto "$app_path" "$build_dir/ipa/Payload/funPlayer.app"
(
  cd "$build_dir/ipa"
  /usr/bin/ditto -c -k --keepParent Payload "$ipa_path"
)
/usr/bin/unzip -tq "$ipa_path"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  cat >> "$GITHUB_STEP_SUMMARY" <<'SUMMARY'
## funPlayer IPA

Download **funPlayer-unsigned-ipa** from this run's **Artifacts** section,
then extract `funPlayer-unsigned.ipa` from the artifact ZIP.

This is an **unsigned, arm64 iOS device build**. Sign it with your own
certificate and provisioning profile before installing it on a device.
It cannot be uploaded directly to TestFlight or the App Store.
SUMMARY
fi

echo "IPA created: $ipa_path"
