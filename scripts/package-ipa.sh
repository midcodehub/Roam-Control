#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUTPUT_DIR="${1:-${PROJECT_ROOT}/build/output}"
ARCHIVE_PATH="${PROJECT_ROOT}/build/RoamControl.xcarchive"
PAYLOAD_DIR="${PROJECT_ROOT}/build/Payload"

echo "=== Roam Control IPA Packaging Tool ==="
echo "Project Root: ${PROJECT_ROOT}"
echo "Output Directory: ${OUTPUT_DIR}"

if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "Error: xcodebuild is required but not found in PATH." >&2
    exit 1
fi

# Extract version and build number from project.pbxproj
VERSION=$(grep -m1 "MARKETING_VERSION" "${PROJECT_ROOT}/RoamControl.xcodeproj/project.pbxproj" | sed -E 's/.*= ([^;]+);/\1/' | tr -d ' "')
BUILD=$(grep -m1 "CURRENT_PROJECT_VERSION" "${PROJECT_ROOT}/RoamControl.xcodeproj/project.pbxproj" | sed -E 's/.*= ([^;]+);/\1/' | tr -d ' "')
VERSION="${VERSION:-0.9.2}"
BUILD="${BUILD:-1}"

echo "Target: RoamControl (Version: ${VERSION}, Build: ${BUILD})"

# Clean up temporary build artifacts
rm -rf "${ARCHIVE_PATH}" "${PAYLOAD_DIR}"
mkdir -p "${OUTPUT_DIR}"

echo "--> Step 1: Archiving RoamControl (Release, unsigned)..."
xcodebuild archive \
    -project "${PROJECT_ROOT}/RoamControl.xcodeproj" \
    -scheme "RoamControl" \
    -configuration "Release" \
    -destination "generic/platform=iOS" \
    -archivePath "${ARCHIVE_PATH}" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY=""

APP_PATH="${ARCHIVE_PATH}/Products/Applications/RoamControl.app"
if [[ ! -d "${APP_PATH}" ]]; then
    echo "Error: Archived app not found at expected path: ${APP_PATH}" >&2
    exit 1
fi

echo "--> Step 2: Packaging Payload into IPA..."
mkdir -p "${PAYLOAD_DIR}"
cp -R "${APP_PATH}" "${PAYLOAD_DIR}/"

VERSIONED_IPA="${OUTPUT_DIR}/RoamControl-v${VERSION}-b${BUILD}.ipa"
CANONICAL_IPA="${OUTPUT_DIR}/RoamControl.ipa"

rm -f "${VERSIONED_IPA}" "${CANONICAL_IPA}"

(
    cd "${PROJECT_ROOT}/build"
    zip -r -y -q "${VERSIONED_IPA}" Payload
)

cp "${VERSIONED_IPA}" "${CANONICAL_IPA}"

echo "--> Step 3: Package Summary:"
ls -lh "${VERSIONED_IPA}" "${CANONICAL_IPA}"
if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${CANONICAL_IPA}"
fi

echo "=== Successfully built IPA: ${VERSIONED_IPA} ==="
