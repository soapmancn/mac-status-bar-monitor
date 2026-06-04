#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="MacStatusBarMonitor"
VERSION="${RELEASE_VERSION:-}"

if [[ -z "${VERSION}" ]]; then
    if git -C "${PROJECT_DIR}" describe --tags --exact-match >/dev/null 2>&1; then
        VERSION="$(git -C "${PROJECT_DIR}" describe --tags --exact-match)"
    elif [[ -n "${GITHUB_REF_NAME:-}" ]]; then
        VERSION="${GITHUB_REF_NAME}"
    else
        VERSION="dev"
    fi
fi

DIST_DIR="${PROJECT_DIR}/dist"
APP_DIR="${DIST_DIR}/${APP_NAME}.app"
RELEASE_DIR="${DIST_DIR}/release"
DMG_ROOT="${DIST_DIR}/dmg-root"
ZIP_PATH="${RELEASE_DIR}/${APP_NAME}-${VERSION}-macos.zip"
DMG_PATH="${RELEASE_DIR}/${APP_NAME}-${VERSION}-macos.dmg"
CHECKSUM_PATH="${RELEASE_DIR}/${APP_NAME}-${VERSION}-checksums.txt"

cd "${PROJECT_DIR}"

"${PROJECT_DIR}/scripts/build_app.sh"

rm -rf "${RELEASE_DIR}" "${DMG_ROOT}"
mkdir -p "${RELEASE_DIR}" "${DMG_ROOT}"

ditto -c -k --keepParent "${APP_DIR}" "${ZIP_PATH}"

cp -R "${APP_DIR}" "${DMG_ROOT}/${APP_NAME}.app"
ln -s /Applications "${DMG_ROOT}/Applications"
hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${DMG_ROOT}" \
    -ov \
    -format UDZO \
    "${DMG_PATH}" >/dev/null

(
    cd "${RELEASE_DIR}"
    shasum -a 256 "$(basename "${ZIP_PATH}")" "$(basename "${DMG_PATH}")" > "$(basename "${CHECKSUM_PATH}")"
)

cat > "${DIST_DIR}/release-notes.md" <<EOF
## MacStatusBarMonitor ${VERSION}

Download the DMG, open it, then drag MacStatusBarMonitor.app to Applications.

Assets:
- ${APP_NAME}-${VERSION}-macos.dmg
- ${APP_NAME}-${VERSION}-macos.zip
- ${APP_NAME}-${VERSION}-checksums.txt
EOF

echo "Packaged release files in ${RELEASE_DIR}"
