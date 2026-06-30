#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp_root="$(mktemp -d -t vvterm-ios-ramdisk-self-test.XXXXXX)"

cleanup() {
    rm -rf "$tmp_root"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_contains() {
    local file="$1"
    local expected="$2"

    [[ -f "$file" ]] || fail "missing file: $file"
    grep -Fq -- "$expected" "$file" || {
        echo "File did not contain expected text: $expected" >&2
        echo "--- $file ---" >&2
        cat "$file" >&2
        fail "assert_contains failed"
    }
}

assert_not_contains() {
    local file="$1"
    local unexpected="$2"

    [[ -f "$file" ]] || fail "missing file: $file"
    ! grep -Fq -- "$unexpected" "$file" || {
        echo "File contained unexpected text: $unexpected" >&2
        echo "--- $file ---" >&2
        cat "$file" >&2
        fail "assert_not_contains failed"
    }
}

write_stub_tools() {
    local bin_dir="$1"
    mkdir -p "$bin_dir"

    cat >"$bin_dir/xcodebuild" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >>"${VVTERM_STUB_CAPTURE}/xcodebuild.args"
if [[ " $* " == *" -resolvePackageDependencies "* ]]; then
    exit 0
fi
echo "Test run started."
echo "Test run with 1 tests in 1 suite passed after 0.001 seconds."
exit 0
STUB

    cat >"$bin_dir/xcrun" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "simctl" && "${2:-}" == "list" && "${3:-}" == "devices" ]]; then
    echo "    iPhone 17 (11111111-2222-3333-4444-555555555555) (Shutdown)"
fi
exit 0
STUB

    cat >"$bin_dir/hdiutil" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >>"${VVTERM_STUB_CAPTURE}/hdiutil.calls"
case "${1:-}" in
attach)
    echo "/dev/disk999"
    ;;
detach)
    ;;
esac
exit 0
STUB

    cat >"$bin_dir/diskutil" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >>"${VVTERM_STUB_CAPTURE}/diskutil.calls"
case "${1:-}" in
erasevolume)
    mkdir -p "${VVTERM_STUB_RAMDISK_MOUNT}"
    ;;
info)
    cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>MountPoint</key>
    <string>${VVTERM_STUB_RAMDISK_MOUNT}</string>
</dict>
</plist>
PLIST
    ;;
unmountDisk)
    ;;
esac
exit 0
STUB

    chmod +x "$bin_dir/xcodebuild" "$bin_dir/xcrun" "$bin_dir/hdiutil" "$bin_dir/diskutil"
}

run_wrapper() {
    local capture_dir="$1"
    local ramdisk_mount="$2"
    local stdout_file="$3"
    local stderr_file="$4"
    shift 4

    mkdir -p "$capture_dir" "$ramdisk_mount" "$tmp_root/tmp" "$tmp_root/logs"
    env -i \
        PATH="${tmp_root}/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        TMPDIR="${tmp_root}/tmp/" \
        VVTERM_STUB_CAPTURE="$capture_dir" \
        VVTERM_STUB_RAMDISK_MOUNT="$ramdisk_mount" \
        IOS_TEST_LOCK_DIR="${tmp_root}/ios-test.lock" \
        IOS_TEST_CLONED_SOURCE_PACKAGES_DIR="${tmp_root}/xcode-cloned-source-packages" \
        IOS_TEST_LOG_DIR="${tmp_root}/logs" \
        IOS_TEST_RETRIES=0 \
        IOS_TEST_NO_OUTPUT_TIMEOUT=0 \
        IOS_TEST_FAILURE_LOG_LINES=20 \
        "$@" \
        "${repo_root}/scripts/test-ios.sh" >"$stdout_file" 2>"$stderr_file"
}

write_stub_tools "${tmp_root}/bin"

local_capture="${tmp_root}/capture-local"
local_mount="${tmp_root}/ramdisk-local"
run_wrapper "$local_capture" "$local_mount" "${tmp_root}/local.out" "${tmp_root}/local.err" \
    IOS_TEST_RAMDISK_MB=16

assert_contains "${local_capture}/hdiutil.calls" "attach"
assert_contains "${local_capture}/hdiutil.calls" "detach"
assert_contains "${local_capture}/diskutil.calls" "erasevolume"
assert_contains "${local_capture}/diskutil.calls" "unmountDisk"
assert_contains "${local_capture}/xcodebuild.args" "-derivedDataPath"
assert_contains "${local_capture}/xcodebuild.args" "${local_mount}/vvterm-ios-derived-data."
assert_contains "${local_capture}/xcodebuild.args" "${tmp_root}/xcode-cloned-source-packages"
assert_not_contains "${local_capture}/xcodebuild.args" "${local_mount}/xcode-cloned-source-packages"
[[ -z "$(find "$local_mount" -maxdepth 1 -name 'vvterm-ios-derived-data.*' -print -quit)" ]] ||
    fail "auto-managed DerivedData was not removed from RAM disk"
[[ -n "$(find "${tmp_root}/logs" -name 'xcodebuild-test-attempt-1-passed.log' -print -quit)" ]] ||
    fail "diagnostic logs should be preserved outside the RAM disk"

ci_capture="${tmp_root}/capture-ci"
ci_mount="${tmp_root}/ramdisk-ci"
run_wrapper "$ci_capture" "$ci_mount" "${tmp_root}/ci.out" "${tmp_root}/ci.err" \
    GITHUB_ACTIONS=true \
    IOS_TEST_RAMDISK_MB=16

[[ ! -s "${ci_capture}/hdiutil.calls" ]] || fail "GitHub Actions must not create a RAM disk"
assert_contains "${ci_capture}/xcodebuild.args" "-derivedDataPath"
assert_not_contains "${ci_capture}/xcodebuild.args" "${ci_mount}/vvterm-ios-derived-data."
assert_contains "${tmp_root}/ci.out" "Ignoring IOS_TEST_RAMDISK_MB on GitHub Actions."

echo "test-ios RAM disk self-test passed"
