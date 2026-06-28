#!/bin/bash
# VVTerm vendor build (GhosttyKit + libssh2/OpenSSL)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

VENDOR_GHOSTTY="$PROJECT_ROOT/Vendor/libghostty"
VENDOR_SSH="$PROJECT_ROOT/Vendor/libssh2"
BUILD_DIR_SSH="$PROJECT_ROOT/.build/ssh"

OPENSSL_VERSION="3.2.0"
LIBSSH2_VERSION="1.11.0"
OPENSSL_SHA256="14c826f07c7e433706fb5c69fa9e25dab95684844b4c962a2cf1bf183eb4690e"
LIBSSH2_SHA256="3736161e41e2693324deb38c26cfdc3efe6209d634ba4258db1cecff6a5ad461"
MACOS_DEPLOYMENT_TARGET="13.3"
IOS_DEPLOYMENT_TARGET="16.1"

GHOSTTY_REPO="${GHOSTTY_REPO:-https://github.com/mzz2017/ghostty.git}"
DEFAULT_GHOSTTY_REF="b00bb2d91ecfd05fa9ce1f08b9d146b76c7d0041"
GHOSTTY_REF="${GHOSTTY_REF:-${DEFAULT_GHOSTTY_REF}}"
GHOSTTY_SOURCE_DIR="${GHOSTTY_SOURCE_DIR:-}"
BUNDLE_ID="app.vivy.VivyTerm"

KEEP_WORKDIR="${KEEP_WORKDIR:-0}"
GHOSTTY_WORKDIR=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_section() { echo -e "\n${BLUE}==== $1 ====${NC}\n"; }

print_usage() {
    cat << EOF
VVTerm Build Script

Usage: $0 [command]

Commands:
  all       Build GhosttyKit + libssh2/OpenSSL (default)
  ghostty   Build GhosttyKit.xcframework and copy .a libs
  check-ghostty
            Verify vendored Ghostty headers/libs expose the ABI VVTerm uses
  ssh       Build libssh2 + OpenSSL (macOS + iOS + simulator)
  check-ssh-sources
            Download and verify OpenSSL/libssh2 source archives
  clean     Remove .build + Vendor libraries
  help      Show this help message

Env:
  GHOSTTY_REPO=<git-url>       Remote repo to fetch when GHOSTTY_SOURCE_DIR is unset
  GHOSTTY_REF=<git-ref>        Build a specific ghostty ref (default: ${DEFAULT_GHOSTTY_REF})
  GHOSTTY_SOURCE_DIR=<path>    Build from a local ghostty checkout instead of remote
  KEEP_WORKDIR=1               Keep ghostty build temp dir for debugging
EOF
}

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        log_error "Missing dependency: $1"
        exit 1
    fi
}

check_deps_ghostty() {
    require_cmd git
    require_cmd python3
    require_cmd zig
    require_cmd xcodebuild
    require_cmd perl
    require_cmd rsync
    require_cmd msgfmt
}

check_deps_ssh() {
    require_cmd curl
    require_cmd shasum
    require_cmd tar
    require_cmd cmake
    require_cmd make
    require_cmd xcrun
}

find_ghostty_xcframework_library() {
    local xcframework="$1"
    local slice_pattern="$2"
    local lib

    lib=$(find "${xcframework}" -path "*/${slice_pattern}/*.a" -type f -print -quit)
    if [ -z "${lib}" ]; then
        log_error "Failed to locate static library for ${slice_pattern} inside ${xcframework}"
        exit 1
    fi

    printf "%s\n" "${lib}"
}

normalize_ghostty_headers() {
    local root="$1"
    while IFS= read -r -d '' header; do
        perl -pi -e 's/[ \t]+$//' "${header}"
    done < <(find "${root}" -name "*.h" -type f -print0)
}

strip_lib() {
    local lib="$1"
    if command -v xcrun >/dev/null 2>&1; then
        xcrun strip -S -x "$lib" || strip -S -x "$lib"
    else
        strip -S -x "$lib"
    fi
}

prepare_ghostty_source() {
    local workdir="$1"

    if [ -n "${GHOSTTY_SOURCE_DIR}" ]; then
        local source_root
        source_root="$(git -C "${GHOSTTY_SOURCE_DIR}" rev-parse --show-toplevel)"
        log_info "Cloning local ghostty source from ${source_root} @ ${GHOSTTY_REF}..."

        if [ -n "$(git -C "${source_root}" status --porcelain)" ]; then
            log_warn "Local ghostty source has uncommitted changes; git clone will not include them."
        fi

        git clone --no-hardlinks "${source_root}" "${workdir}/ghostty"
        git -C "${workdir}/ghostty" checkout --detach "${GHOSTTY_REF}"
    else
        log_info "Cloning ghostty from ${GHOSTTY_REPO} @ ${GHOSTTY_REF}..."
        git clone --filter=blob:none --no-checkout "${GHOSTTY_REPO}" "${workdir}/ghostty"
        git -C "${workdir}/ghostty" fetch --depth 1 origin "${GHOSTTY_REF}"
        git -C "${workdir}/ghostty" checkout --detach FETCH_HEAD
    fi
}

prepare_ghostty_dependencies() {
    local ghostty_root="$1"
    local patch_script="${ghostty_root}/scripts/apply-dependency-patches.sh"

    if [ ! -f "${patch_script}" ]; then
        return
    fi

    log_info "Preparing Ghostty dependencies..."
    (cd "${ghostty_root}" && bash "${patch_script}")
}

check_ghostty_vendor() {
    log_section "Ghostty vendor ABI check"

    local header_tokens=(
        "GHOSTTY_BACKEND_EXTERNAL"
        "backend_type"
        "write_callback"
        "resize_callback"
        "typedef bool (*ghostty_runtime_read_clipboard_cb)"
        "ghostty_surface_write_output"
        "ghostty_surface_external_exited"
        "ghostty_surface_in_alternate_screen"
    )
    local xcframework="${VENDOR_GHOSTTY}/GhosttyKit.xcframework"
    local macos_header
    local ios_header
    local sim_header
    macos_header=$(find "${xcframework}" -path "*/macos-*/Headers/ghostty.h" -type f -print -quit)
    ios_header=$(find "${xcframework}" -path "*/ios-arm64/Headers/ghostty.h" -type f -print -quit)
    sim_header=$(find "${xcframework}" -path "*/ios-*simulator/Headers/ghostty.h" -type f -print -quit)
    local libs=(
        "${VENDOR_GHOSTTY}/lib/libghostty.a"
        "${VENDOR_GHOSTTY}/ios/lib/libghostty.a"
        "${VENDOR_GHOSTTY}/ios-simulator/lib/libghostty.a"
        "$(find_ghostty_xcframework_library "${xcframework}" "macos-*")"
        "$(find_ghostty_xcframework_library "${xcframework}" "ios-arm64")"
        "$(find_ghostty_xcframework_library "${xcframework}" "ios-*simulator")"
    )
    local headers=(
        "${VENDOR_GHOSTTY}/include/ghostty.h"
        "${VENDOR_GHOSTTY}/ios/include/ghostty.h"
        "${VENDOR_GHOSTTY}/ios-simulator/include/ghostty.h"
        "${macos_header}"
        "${ios_header}"
        "${sim_header}"
    )
    local symbols=(
        "ghostty_surface_write_output"
        "ghostty_surface_external_exited"
        "ghostty_surface_in_alternate_screen"
    )

    local nm_cmd=()
    if command -v llvm-nm >/dev/null 2>&1; then
        nm_cmd=(llvm-nm)
    elif command -v xcrun >/dev/null 2>&1 && xcrun -find llvm-nm >/dev/null 2>&1; then
        nm_cmd=(xcrun llvm-nm)
    elif command -v xcrun >/dev/null 2>&1 && xcrun -find nm >/dev/null 2>&1; then
        nm_cmd=(xcrun nm)
    elif command -v nm >/dev/null 2>&1; then
        nm_cmd=(nm)
    else
        log_error "Missing dependency: llvm-nm or nm"
        exit 1
    fi

    local header token lib symbol
    for header in "${headers[@]}"; do
        if [ ! -f "${header}" ]; then
            log_error "Missing Ghostty header: ${header}"
            exit 1
        fi
        for token in "${header_tokens[@]}"; do
            if ! grep -Fq "${token}" "${header}"; then
                log_error "Ghostty header ${header} is missing ${token}"
                exit 1
            fi
        done
    done

    for lib in "${libs[@]}"; do
        if [ ! -f "${lib}" ]; then
            log_error "Missing Ghostty library: ${lib}"
            exit 1
        fi
        local nm_output
        if ! nm_output="$("${nm_cmd[@]}" -g "${lib}" 2>&1)"; then
            log_error "Unable to inspect Ghostty library ${lib} with ${nm_cmd[*]}: ${nm_output%%$'\n'*}"
            exit 1
        fi
        for symbol in "${symbols[@]}"; do
            if ! grep -Eq "[[:space:]]_?${symbol}$" <<< "${nm_output}"; then
                log_error "Ghostty library ${lib} is missing ${symbol}"
                exit 1
            fi
        done
    done

    log_info "Ghostty vendor ABI check passed"
}

build_ghosttykit() {
    log_section "GhosttyKit"

    GHOSTTY_WORKDIR="$(mktemp -d "/tmp/ghosttykit.XXXXXX")"
    local workdir="$GHOSTTY_WORKDIR"

    prepare_ghostty_source "${workdir}"
    prepare_ghostty_dependencies "${workdir}/ghostty"

    local embedded_path="${workdir}/ghostty/src/apprt/embedded.zig"
    if [ -f "${embedded_path}" ]; then
        log_info "Disabling Ghostty window blur (App Store safe)..."
        python3 - <<PY
from pathlib import Path

path = Path("${embedded_path}")
text = path.read_text()
old = """    /// Sets the window background blur on macOS to the desired value.
    /// I do this in Zig as an extern function because I don't know how to
    /// call these functions in Swift.
    ///
    /// This uses an undocumented, non-public API because this is what
    /// every terminal appears to use, including Terminal.app.
    export fn ghostty_set_window_background_blur(
        app: *App,
        window: *anyopaque,
    ) void {
        // This is only supported on macOS
        if (comptime builtin.target.os.tag != .macos) return;

        const config = &app.config;

        // Do nothing if we don't have background transparency enabled
        if (config.@\\"background-opacity\\" >= 1.0) return;

        const nswindow = objc.Object.fromId(window);
        _ = CGSSetWindowBackgroundBlurRadius(
            CGSDefaultConnectionForThread(),
            nswindow.msgSend(usize, objc.sel(\\"windowNumber\\"), .{}),
            @intCast(config.@\\"background-blur\\".cval()),
        );
    }

    /// See ghostty_set_window_background_blur
    extern \\"c\\" fn CGSSetWindowBackgroundBlurRadius(*anyopaque, usize, c_int) i32;
    extern \\"c\\" fn CGSDefaultConnectionForThread() *anyopaque;
"""
new = """    /// Sets the window background blur on macOS to the desired value.
    /// App Store builds must avoid non-public APIs; keep this as a no-op.
    export fn ghostty_set_window_background_blur(
        app: *App,
        window: *anyopaque,
    ) void {
        _ = app;
        _ = window;
        return;
    }
"""
if old not in text:
    raise SystemExit("Ghostty private blur block not found; aborting.")
path.write_text(text.replace(old, new))
PY
    fi

    # Patch to link Metal frameworks (same as aizen)
    if [ -f "${workdir}/ghostty/pkg/macos/build.zig" ]; then
        perl -0pi -e 's/lib\.linkFramework\("IOSurface"\);/lib.linkFramework("IOSurface");\n    lib.linkFramework("Metal");\n    lib.linkFramework("MetalKit");/g' "${workdir}/ghostty/pkg/macos/build.zig"
        perl -0pi -e 's/module\.linkFramework\("IOSurface", \.\{\}\);/module.linkFramework("IOSurface", .{});\n        module.linkFramework("Metal", .{});\n        module.linkFramework("MetalKit", .{});/g' "${workdir}/ghostty/pkg/macos/build.zig"
    fi

    # IOSurfaceLayer fixes live in the Ghostty fork; no local patching here.

    # Patch bundle ID to use VVTerm's instead of Ghostty's
    sed -i '' "s/com\\.mitchellh\\.ghostty/${BUNDLE_ID}/g" "${workdir}/ghostty/src/build_config.zig"

    # Lower iOS minimum to match app deployment target.
    local ghostty_config_path="${workdir}/ghostty/src/build/Config.zig"
    python3 - <<PY
from pathlib import Path
import re

target = "${IOS_DEPLOYMENT_TARGET}"
parts = target.split(".")
major = int(parts[0])
minor = int(parts[1]) if len(parts) > 1 else 0
patch = int(parts[2]) if len(parts) > 2 else 0

path = Path("${ghostty_config_path}")
text = path.read_text()
pattern = re.compile(
    r"        // iOS \d+ picked arbitrarily\n"
    r"        \.ios => \.\{ \.semver = \.\{\n"
    r"            \.major = \d+,\n"
    r"            \.minor = \d+,\n"
    r"            \.patch = \d+,\n"
    r"        \} \},"
)
replacement = f"""        // iOS {target} matches app deployment target
        .ios => .{{ .semver = .{{
            .major = {major},
            .minor = {minor},
            .patch = {patch},
        }} }},"""
text, count = pattern.subn(replacement, text, count=1)
if count != 1:
    raise SystemExit("Ghostty iOS deployment target block not found; aborting.")
path.write_text(text)
PY

    log_info "Building GhosttyKit.xcframework..."

    local zig_flags=(
        -Dapp-runtime=none
        -Demit-xcframework=true
        -Demit-macos-app=false
        -Demit-exe=false
        -Demit-docs=false
        -Demit-webdata=false
        -Demit-helpgen=false
        -Demit-terminfo=false
        -Demit-termcap=false
        -Demit-themes=false
        -Doptimize=ReleaseFast
        -Dstrip
        -Dxcframework-target=universal
    )

    (cd "${workdir}/ghostty" && zig build "${zig_flags[@]}" -p "${workdir}/zig-out")

    local xcframework="${workdir}/ghostty/macos/GhosttyKit.xcframework"
    if [ ! -d "${xcframework}" ]; then
        log_error "${xcframework} not found"
        exit 1
    fi

    local macos_lib
    local ios_lib
    local sim_lib
    macos_lib=$(find_ghostty_xcframework_library "${xcframework}" "macos-*")
    ios_lib=$(find_ghostty_xcframework_library "${xcframework}" "ios-arm64")
    sim_lib=$(find_ghostty_xcframework_library "${xcframework}" "ios-*simulator")

    mkdir -p "${VENDOR_GHOSTTY}/lib" "${VENDOR_GHOSTTY}/ios/lib" "${VENDOR_GHOSTTY}/ios-simulator/lib"
    cp "${macos_lib}" "${VENDOR_GHOSTTY}/lib/libghostty.a"
    cp "${ios_lib}" "${VENDOR_GHOSTTY}/ios/lib/libghostty.a"
    cp "${sim_lib}" "${VENDOR_GHOSTTY}/ios-simulator/lib/libghostty.a"

    if [ -d "${workdir}/ghostty/include" ]; then
        mkdir -p "${VENDOR_GHOSTTY}/include" "${VENDOR_GHOSTTY}/ios/include" "${VENDOR_GHOSTTY}/ios-simulator/include"
        rsync -a --exclude='module.modulemap' "${workdir}/ghostty/include/" "${VENDOR_GHOSTTY}/include/"
        rsync -a --exclude='module.modulemap' "${workdir}/ghostty/include/" "${VENDOR_GHOSTTY}/ios/include/"
        rsync -a --exclude='module.modulemap' "${workdir}/ghostty/include/" "${VENDOR_GHOSTTY}/ios-simulator/include/"
    fi

    rm -rf "${VENDOR_GHOSTTY}/GhosttyKit.xcframework"
    rsync -a "${xcframework}" "${VENDOR_GHOSTTY}/"

    normalize_ghostty_headers "${VENDOR_GHOSTTY}"

    printf "%s\n" "$(git -C "${workdir}/ghostty" rev-parse HEAD)" > "${VENDOR_GHOSTTY}/VERSION"

    strip_lib "${VENDOR_GHOSTTY}/lib/libghostty.a"
    strip_lib "${VENDOR_GHOSTTY}/ios/lib/libghostty.a"
    strip_lib "${VENDOR_GHOSTTY}/ios-simulator/lib/libghostty.a"

    # Also strip static libs inside the xcframework to stay under GitHub size limits.
    while IFS= read -r -d '' lib; do
        strip_lib "${lib}"
    done < <(find "${VENDOR_GHOSTTY}/GhosttyKit.xcframework" -name "*.a" -type f -print0)

    log_info "GhosttyKit done"
    log_info "  macOS: $(ls -lh "${VENDOR_GHOSTTY}/lib/libghostty.a" | awk '{print $5}')"
    log_info "  iOS: $(ls -lh "${VENDOR_GHOSTTY}/ios/lib/libghostty.a" | awk '{print $5}')"
    log_info "  iOS Simulator: $(ls -lh "${VENDOR_GHOSTTY}/ios-simulator/lib/libghostty.a" | awk '{print $5}')"
    check_ghostty_vendor

    if [ "${KEEP_WORKDIR}" = "1" ]; then
        log_warn "Keeping workdir: ${workdir}"
    else
        rm -rf "${workdir}"
        GHOSTTY_WORKDIR=""
    fi
}

# ---------- libssh2 / OpenSSL ----------

verify_sha256() {
    local file="$1"
    local expected="$2"
    local actual

    actual="$(shasum -a 256 "${file}" | awk '{print $1}')"
    if [ "${actual}" != "${expected}" ]; then
        log_error "Checksum mismatch for ${file}"
        log_error "  expected: ${expected}"
        log_error "  actual:   ${actual}"
        exit 1
    fi
}

download_archive() {
    local url="$1"
    local archive="$2"
    local expected_sha256="$3"

    if [ ! -f "${archive}" ]; then
        curl -fL --retry 3 --output "${archive}.tmp" "${url}"
        mv "${archive}.tmp" "${archive}"
    fi

    verify_sha256 "${archive}" "${expected_sha256}"
}

download_sources() {
    mkdir -p "${BUILD_DIR_SSH}"
    cd "${BUILD_DIR_SSH}"

    log_info "Preparing OpenSSL ${OPENSSL_VERSION} source..."
    download_archive \
        "https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz" \
        "openssl-${OPENSSL_VERSION}.tar.gz" \
        "${OPENSSL_SHA256}"
    if [ ! -d "openssl-${OPENSSL_VERSION}" ]; then
        tar xzf "openssl-${OPENSSL_VERSION}.tar.gz"
    fi

    log_info "Preparing libssh2 ${LIBSSH2_VERSION} source..."
    download_archive \
        "https://www.libssh2.org/download/libssh2-${LIBSSH2_VERSION}.tar.gz" \
        "libssh2-${LIBSSH2_VERSION}.tar.gz" \
        "${LIBSSH2_SHA256}"
    if [ ! -d "libssh2-${LIBSSH2_VERSION}" ]; then
        tar xzf "libssh2-${LIBSSH2_VERSION}.tar.gz"
    fi
}

build_openssl_macos() {
    log_info "Building OpenSSL for macOS universal..."

    build_openssl_macos_arch arm64 darwin64-arm64-cc
    build_openssl_macos_arch x86_64 darwin64-x86_64-cc

    create_universal_openssl \
        "${BUILD_DIR_SSH}/openssl-macos-arm64" \
        "${BUILD_DIR_SSH}/openssl-macos-x86_64" \
        "${BUILD_DIR_SSH}/openssl-macos"
}

build_openssl_macos_arch() {
    local arch="$1"
    local configure_target="$2"
    local prefix="${BUILD_DIR_SSH}/openssl-macos-${arch}"

    log_info "Building OpenSSL for macOS ${arch}..."
    cd "${BUILD_DIR_SSH}/openssl-${OPENSSL_VERSION}"

    make clean 2>/dev/null || true
    rm -rf "${prefix}"

    local mac_sdk
    mac_sdk=$(xcrun --sdk macosx --show-sdk-path)
    export MACOSX_DEPLOYMENT_TARGET="${MACOS_DEPLOYMENT_TARGET}"
    export CC="$(xcrun --sdk macosx -f clang) -arch ${arch} -isysroot ${mac_sdk} -mmacosx-version-min=${MACOS_DEPLOYMENT_TARGET}"

    ./Configure "${configure_target}" \
        --prefix="${prefix}" \
        no-shared \
        no-tests

    make -j"$(sysctl -n hw.ncpu)"
    make install_sw

    unset MACOSX_DEPLOYMENT_TARGET CC
}

build_openssl_ios() {
    log_info "Building OpenSSL for iOS arm64..."
    cd "${BUILD_DIR_SSH}/openssl-${OPENSSL_VERSION}"

    make clean 2>/dev/null || true

    local ios_sdk
    ios_sdk=$(xcrun --sdk iphoneos --show-sdk-path)
    export CROSS_TOP="$(xcrun --sdk iphoneos --show-sdk-platform-path)/Developer"
    export CROSS_SDK="iPhoneOS.sdk"
    export CC="$(xcrun --sdk iphoneos -f clang) -isysroot ${ios_sdk} -miphoneos-version-min=${IOS_DEPLOYMENT_TARGET}"

    ./Configure ios64-xcrun \
        --prefix="${BUILD_DIR_SSH}/openssl-ios" \
        -miphoneos-version-min=${IOS_DEPLOYMENT_TARGET} \
        no-shared \
        no-tests \
        no-apps

    make -j"$(sysctl -n hw.ncpu)" build_libs
    make install_sw

    unset CROSS_TOP CROSS_SDK CC
}

build_openssl_simulator() {
    log_info "Building OpenSSL for iOS Simulator universal..."

    build_openssl_simulator_arch arm64
    build_openssl_simulator_arch x86_64

    create_universal_openssl \
        "${BUILD_DIR_SSH}/openssl-simulator-arm64" \
        "${BUILD_DIR_SSH}/openssl-simulator-x86_64" \
        "${BUILD_DIR_SSH}/openssl-simulator"
}

build_openssl_simulator_arch() {
    local arch="$1"
    local prefix="${BUILD_DIR_SSH}/openssl-simulator-${arch}"

    log_info "Building OpenSSL for iOS Simulator ${arch}..."
    cd "${BUILD_DIR_SSH}/openssl-${OPENSSL_VERSION}"

    make clean 2>/dev/null || true
    rm -rf "${prefix}"

    local sim_sdk
    sim_sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
    export CROSS_TOP="$(xcrun --sdk iphonesimulator --show-sdk-platform-path)/Developer"
    export CROSS_SDK="iPhoneSimulator.sdk"
    export CC="$(xcrun --sdk iphonesimulator -f clang) -arch ${arch} -isysroot ${sim_sdk} -mios-simulator-version-min=${IOS_DEPLOYMENT_TARGET}"

    ./Configure iossimulator-xcrun \
        --prefix="${prefix}" \
        -mios-simulator-version-min=${IOS_DEPLOYMENT_TARGET} \
        no-shared \
        no-tests \
        no-apps

    make -j"$(sysctl -n hw.ncpu)" build_libs
    make install_sw

    unset CROSS_TOP CROSS_SDK CC
}

create_universal_openssl() {
    local arm64_prefix="$1"
    local x86_64_prefix="$2"
    local universal_prefix="$3"

    rm -rf "${universal_prefix}"
    mkdir -p "${universal_prefix}/lib"
    rsync -a "${arm64_prefix}/include" "${universal_prefix}/"
    xcrun lipo -create \
        "${arm64_prefix}/lib/libssl.a" \
        "${x86_64_prefix}/lib/libssl.a" \
        -output "${universal_prefix}/lib/libssl.a"
    xcrun lipo -create \
        "${arm64_prefix}/lib/libcrypto.a" \
        "${x86_64_prefix}/lib/libcrypto.a" \
        -output "${universal_prefix}/lib/libcrypto.a"
}

build_libssh2_macos() {
    log_info "Building libssh2 for macOS universal..."

    build_libssh2_macos_arch arm64
    build_libssh2_macos_arch x86_64

    create_universal_libssh2 \
        "${BUILD_DIR_SSH}/libssh2-macos-arm64" \
        "${BUILD_DIR_SSH}/libssh2-macos-x86_64" \
        "${VENDOR_SSH}/macos" \
        "${BUILD_DIR_SSH}/openssl-macos"
}

build_libssh2_macos_arch() {
    local arch="$1"
    local install_prefix="${BUILD_DIR_SSH}/libssh2-macos-${arch}"

    log_info "Building libssh2 for macOS ${arch}..."
    cd "${BUILD_DIR_SSH}/libssh2-${LIBSSH2_VERSION}"

    rm -rf "build-macos-${arch}" "${install_prefix}"
    mkdir -p "build-macos-${arch}" && cd "build-macos-${arch}"

    cmake .. \
        -Wno-dev \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DCMAKE_OSX_ARCHITECTURES="${arch}" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOS_DEPLOYMENT_TARGET} \
        -DCMAKE_INSTALL_PREFIX="${install_prefix}" \
        -DOPENSSL_ROOT_DIR="${BUILD_DIR_SSH}/openssl-macos-${arch}" \
        -DOPENSSL_INCLUDE_DIR="${BUILD_DIR_SSH}/openssl-macos-${arch}/include" \
        -DOPENSSL_CRYPTO_LIBRARY="${BUILD_DIR_SSH}/openssl-macos-${arch}/lib/libcrypto.a" \
        -DOPENSSL_SSL_LIBRARY="${BUILD_DIR_SSH}/openssl-macos-${arch}/lib/libssl.a" \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_EXAMPLES=OFF \
        -DBUILD_TESTING=OFF

    make -j"$(sysctl -n hw.ncpu)"
    make install
}

build_libssh2_ios() {
    log_info "Building libssh2 for iOS arm64..."
    cd "${BUILD_DIR_SSH}/libssh2-${LIBSSH2_VERSION}"

    rm -rf build-ios
    mkdir -p build-ios && cd build-ios

    local ios_sdk
    ios_sdk=$(xcrun --sdk iphoneos --show-sdk-path)

    cmake .. \
        -Wno-dev \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_SYSROOT="${ios_sdk}" \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=${IOS_DEPLOYMENT_TARGET} \
        -DCMAKE_INSTALL_PREFIX="${VENDOR_SSH}/ios" \
        -DOPENSSL_ROOT_DIR="${BUILD_DIR_SSH}/openssl-ios" \
        -DOPENSSL_INCLUDE_DIR="${BUILD_DIR_SSH}/openssl-ios/include" \
        -DOPENSSL_CRYPTO_LIBRARY="${BUILD_DIR_SSH}/openssl-ios/lib/libcrypto.a" \
        -DOPENSSL_SSL_LIBRARY="${BUILD_DIR_SSH}/openssl-ios/lib/libssl.a" \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_EXAMPLES=OFF \
        -DBUILD_TESTING=OFF

    make -j"$(sysctl -n hw.ncpu)"
    make install

    cp "${BUILD_DIR_SSH}/openssl-ios/lib/libssl.a" "${VENDOR_SSH}/ios/lib/"
    cp "${BUILD_DIR_SSH}/openssl-ios/lib/libcrypto.a" "${VENDOR_SSH}/ios/lib/"
}

build_libssh2_simulator() {
    log_info "Building libssh2 for iOS Simulator universal..."

    build_libssh2_simulator_arch arm64
    build_libssh2_simulator_arch x86_64

    create_universal_libssh2 \
        "${BUILD_DIR_SSH}/libssh2-simulator-arm64" \
        "${BUILD_DIR_SSH}/libssh2-simulator-x86_64" \
        "${VENDOR_SSH}/ios-simulator" \
        "${BUILD_DIR_SSH}/openssl-simulator"
}

build_libssh2_simulator_arch() {
    local arch="$1"
    local install_prefix="${BUILD_DIR_SSH}/libssh2-simulator-${arch}"

    log_info "Building libssh2 for iOS Simulator ${arch}..."
    cd "${BUILD_DIR_SSH}/libssh2-${LIBSSH2_VERSION}"

    rm -rf "build-simulator-${arch}" "${install_prefix}"
    mkdir -p "build-simulator-${arch}" && cd "build-simulator-${arch}"

    local sim_sdk
    sim_sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)

    cmake .. \
        -Wno-dev \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_SYSROOT="${sim_sdk}" \
        -DCMAKE_OSX_ARCHITECTURES="${arch}" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=${IOS_DEPLOYMENT_TARGET} \
        -DCMAKE_INSTALL_PREFIX="${install_prefix}" \
        -DOPENSSL_ROOT_DIR="${BUILD_DIR_SSH}/openssl-simulator-${arch}" \
        -DOPENSSL_INCLUDE_DIR="${BUILD_DIR_SSH}/openssl-simulator-${arch}/include" \
        -DOPENSSL_CRYPTO_LIBRARY="${BUILD_DIR_SSH}/openssl-simulator-${arch}/lib/libcrypto.a" \
        -DOPENSSL_SSL_LIBRARY="${BUILD_DIR_SSH}/openssl-simulator-${arch}/lib/libssl.a" \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_EXAMPLES=OFF \
        -DBUILD_TESTING=OFF

    make -j"$(sysctl -n hw.ncpu)"
    make install
}

create_universal_libssh2() {
    local arm64_prefix="$1"
    local x86_64_prefix="$2"
    local vendor_prefix="$3"
    local openssl_prefix="$4"

    rm -rf "${vendor_prefix}"
    mkdir -p "${vendor_prefix}/lib"
    rsync -a "${arm64_prefix}/include" "${vendor_prefix}/"
    xcrun lipo -create \
        "${arm64_prefix}/lib/libssh2.a" \
        "${x86_64_prefix}/lib/libssh2.a" \
        -output "${vendor_prefix}/lib/libssh2.a"
    cp "${openssl_prefix}/lib/libssl.a" "${vendor_prefix}/lib/"
    cp "${openssl_prefix}/lib/libcrypto.a" "${vendor_prefix}/lib/"
}

create_modulemap() {
    log_info "Writing libssh2 module map..."

    cat > "${VENDOR_SSH}/module.modulemap" << 'EOF_MODULE'
module libssh2 {
    header "include/libssh2.h"
    header "include/libssh2_sftp.h"
    header "include/libssh2_publickey.h"
    link "ssh2"
    link "ssl"
    link "crypto"
    export *
}
EOF_MODULE
}

build_ssh() {
    log_section "libssh2 + OpenSSL"
    download_sources
    build_openssl_macos
    build_libssh2_macos
    build_openssl_ios
    build_libssh2_ios
    build_openssl_simulator
    build_libssh2_simulator
    create_modulemap

    log_info "libssh2 done"
    log_info "  macOS: $(ls -lh "${VENDOR_SSH}/macos/lib/libssh2.a" | awk '{print $5}')"
    log_info "  iOS: $(ls -lh "${VENDOR_SSH}/ios/lib/libssh2.a" | awk '{print $5}')"
    log_info "  iOS Simulator: $(ls -lh "${VENDOR_SSH}/ios-simulator/lib/libssh2.a" | awk '{print $5}')"
}

clean() {
    log_section "Clean"
    rm -rf "${PROJECT_ROOT}/.build"
    rm -rf "${VENDOR_GHOSTTY}"
    rm -rf "${VENDOR_SSH}"
    log_info "Clean complete"
}

COMMAND="${1:-all}"

case "${COMMAND}" in
    all)
        check_deps_ghostty
        check_deps_ssh
        build_ghosttykit
        build_ssh
        ;;
    ghostty)
        check_deps_ghostty
        build_ghosttykit
        ;;
    check-ghostty)
        check_ghostty_vendor
        ;;
    ssh)
        check_deps_ssh
        build_ssh
        ;;
    check-ssh-sources)
        check_deps_ssh
        download_sources
        ;;
    clean)
        clean
        ;;
    help|--help|-h)
        print_usage
        ;;
    *)
        log_error "Unknown command: ${COMMAND}"
        print_usage
        exit 1
        ;;
 esac
