#!/bin/bash
# Xcode Run Script phase of the DotfileSync app target: builds the `dotfilesyncd` agent and the
# `dotfilesync` CLI from ../Packages/DotfileSyncKit with SwiftPM and copies them into
# DotfileSync.app/Contents/MacOS/.
#
# Why SwiftPM and not a target dependency: Xcode can link a package's library products into a
# target, but it cannot build a package *executable* product as a dependency of an app or copy
# it into the bundle. `swift build` produces exactly the binaries the package tests exercise.
#
# The script runs `swift build` with a scrubbed environment so Xcode's build settings
# (ARCHS, SDKROOT, *_DEPLOYMENT_TARGET, …) do not leak into SwiftPM, and keeps SwiftPM's
# build directory inside DerivedData so the source tree stays clean.
#
# When code signing is enabled, both binaries are signed with the app's identity and the
# hardened runtime: the agent only accepts XPC peers signed by the same team, so they must share
# the app's signature. With CODE_SIGNING_ALLOWED=NO (CI) they are left as linked.
set -euo pipefail

PACKAGE_DIR="${SRCROOT}/../Packages/DotfileSyncKit"
SCRATCH="${OBJROOT}/DotfileSyncKit-swiftpm"
DEST="${TARGET_BUILD_DIR}/${EXECUTABLE_FOLDER_PATH}"

case "${CONFIGURATION}" in
    Release) SPM_CONFIG=release ;;
    *) SPM_CONFIG=debug ;;
esac

ARCH_FLAGS=()
for arch in ${ARCHS}; do
    ARCH_FLAGS+=(--arch "${arch}")
done

spm() {
    env -i \
        HOME="${HOME}" \
        PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
        TMPDIR="${TMPDIR:-/tmp}" \
        DEVELOPER_DIR="${DEVELOPER_DIR}" \
        /usr/bin/xcrun swift build \
            --package-path "${PACKAGE_DIR}" \
            --scratch-path "${SCRATCH}" \
            -c "${SPM_CONFIG}" \
            "${ARCH_FLAGS[@]}" \
            "$@"
}

spm --product dotfilesyncd
spm --product dotfilesync
BIN_DIR="$(spm --show-bin-path)"

mkdir -p "${DEST}"
for product in dotfilesyncd dotfilesync; do
    # The bundle executable is DotfileSyncApp, not DotfileSync: on a case-insensitive volume
    # Contents/MacOS/DotfileSync and Contents/MacOS/dotfilesync would be the same file.
    if [[ "$(printf %s "${product}" | tr "[:upper:]" "[:lower:]")" == "$(printf %s "${EXECUTABLE_NAME}" | tr "[:upper:]" "[:lower:]")" ]]; then
        echo "error: ${product} collides with the app executable" >&2
        exit 1
    fi
    /usr/bin/ditto "${BIN_DIR}/${product}" "${DEST}/${product}"
    if [[ "${CODE_SIGNING_ALLOWED:-YES}" == "YES" && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
        /usr/bin/codesign --force --options runtime --timestamp=none \
            --sign "${EXPANDED_CODE_SIGN_IDENTITY}" \
            --identifier "com.jamallyons.dotfilesync.${product}" \
            "${DEST}/${product}"
    fi
done
