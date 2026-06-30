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

assert_file_missing_or_empty() {
    local file="$1"

    [[ ! -s "$file" ]] || {
        echo "File should be missing or empty: $file" >&2
        echo "--- $file ---" >&2
        cat "$file" >&2
        fail "assert_file_missing_or_empty failed"
    }
}

assert_pid_not_running() {
    local pid_file="$1"
    local label="$2"

    [[ -f "$pid_file" ]] || fail "missing pid file for ${label}: $pid_file"
    local pid
    pid="$(cat "$pid_file")"
    for _ in 1 2 3 4 5; do
        if ! kill -0 "$pid" 2>/dev/null; then
            return
        fi
        sleep 1
    done

    kill "$pid" >/dev/null 2>&1 || true
    fail "${label} child process was still running after wrapper cleanup: ${pid}"
}

write_stub_tools() {
    local bin_dir="$1"
    mkdir -p "$bin_dir"

    cat >"$bin_dir/xcodebuild" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >>"${VVTERM_STUB_CAPTURE}/xcodebuild.args"
if [[ " $* " == *" -resolvePackageDependencies "* ]]; then
    if [[ "${VVTERM_STUB_RESOLVE_STALL:-0}" == "1" ]]; then
        sleep "${VVTERM_STUB_RESOLVE_SLEEP:-3}"
    fi
    exit 0
fi
if [[ "${1:-}" == "test" && "${VVTERM_STUB_TEST_STALL:-0}" == "1" ]]; then
    (
        sleep "${VVTERM_STUB_TEST_GRANDCHILD_SLEEP:-30}" &
        echo "$!" >"${VVTERM_STUB_CAPTURE}/xcodebuild-test-grandchild.pid"
        sleep "${VVTERM_STUB_TEST_CHILD_SLEEP:-30}"
    ) &
    echo "$!" >"${VVTERM_STUB_CAPTURE}/xcodebuild-test-child.pid"
    sleep "${VVTERM_STUB_TEST_SLEEP:-30}"
    exit 0
fi
if [[ "${VVTERM_STUB_ZERO_TESTS:-0}" == "1" ]]; then
    echo "Test run started."
    exit 0
fi
echo "Test run started."
echo "Test run with 1 tests in 1 suite passed after 0.001 seconds."
exit 0
STUB

    cat >"$bin_dir/xcrun" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >>"${VVTERM_STUB_CAPTURE}/xcrun.calls"
if [[ "${1:-}" == "simctl" && "${2:-}" == "list" && "${3:-}" == "devices" ]]; then
    echo "    iPhone 17 (11111111-2222-3333-4444-555555555555) (${VVTERM_STUB_DEVICE_STATE:-Shutdown})"
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

    cat >"$bin_dir/perl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >>"${VVTERM_STUB_CAPTURE}/perl.calls"
exit 0
STUB

    chmod +x "$bin_dir/xcodebuild" "$bin_dir/xcrun" "$bin_dir/hdiutil" "$bin_dir/diskutil" "$bin_dir/perl"
}

run_wrapper() {
    local capture_dir="$1"
    local ramdisk_mount="$2"
    local stdout_file="$3"
    local stderr_file="$4"
    local cloned_source_packages_dir="${5:-}"
    local device_state="${6:-Shutdown}"
    local env_overrides=()
    local script_args=()
    local parsing_script_args=0
    shift 6

    while [[ "$#" -gt 0 ]]; do
        if [[ "$1" == "--" && "$parsing_script_args" -eq 0 ]]; then
            parsing_script_args=1
            shift
            continue
        fi
        if [[ "$parsing_script_args" -eq 1 ]]; then
            script_args+=("$1")
        else
            env_overrides+=("$1")
        fi
        shift
    done

    mkdir -p "$capture_dir" "$ramdisk_mount" "$tmp_root/tmp" "$tmp_root/logs"
    set +u
    if [[ -n "$cloned_source_packages_dir" ]]; then
        env -i \
            PATH="${tmp_root}/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
            TMPDIR="${tmp_root}/tmp/" \
            VVTERM_STUB_CAPTURE="$capture_dir" \
            VVTERM_STUB_DEVICE_STATE="$device_state" \
            VVTERM_STUB_RAMDISK_MOUNT="$ramdisk_mount" \
            IOS_TEST_LOCK_DIR="${tmp_root}/ios-test.lock" \
            IOS_TEST_LOG_DIR="${tmp_root}/logs" \
            IOS_TEST_RETRIES=0 \
            IOS_TEST_NO_OUTPUT_TIMEOUT=0 \
            IOS_TEST_FAILURE_LOG_LINES=20 \
            IOS_TEST_CLONED_SOURCE_PACKAGES_DIR="$cloned_source_packages_dir" \
            "${env_overrides[@]}" \
            "${repo_root}/scripts/test-ios.sh" \
            "${script_args[@]}" >"$stdout_file" 2>"$stderr_file"
    else
        env -i \
            PATH="${tmp_root}/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
            TMPDIR="${tmp_root}/tmp/" \
            VVTERM_STUB_CAPTURE="$capture_dir" \
            VVTERM_STUB_DEVICE_STATE="$device_state" \
            VVTERM_STUB_RAMDISK_MOUNT="$ramdisk_mount" \
            IOS_TEST_LOCK_DIR="${tmp_root}/ios-test.lock" \
            IOS_TEST_LOG_DIR="${tmp_root}/logs" \
            IOS_TEST_RETRIES=0 \
            IOS_TEST_NO_OUTPUT_TIMEOUT=0 \
            IOS_TEST_FAILURE_LOG_LINES=20 \
            "${env_overrides[@]}" \
            "${repo_root}/scripts/test-ios.sh" \
            "${script_args[@]}" >"$stdout_file" 2>"$stderr_file"
    fi
    local status="$?"
    set -u
    return "$status"
}

run_wrapper_expect_failure() {
    local capture_dir="$1"
    local ramdisk_mount="$2"
    local stdout_file="$3"
    local stderr_file="$4"
    local cloned_source_packages_dir="${5:-}"
    local device_state="${6:-Shutdown}"
    local status
    shift 6

    set +e
    run_wrapper "$capture_dir" "$ramdisk_mount" "$stdout_file" "$stderr_file" "$cloned_source_packages_dir" "$device_state" "$@"
    status="$?"
    set -e
    echo "$status" >"${capture_dir}/wrapper.status"
}

run_wrapper_and_terminate() {
    local capture_dir="$1"
    local ramdisk_mount="$2"
    local stdout_file="$3"
    local stderr_file="$4"
    local cloned_source_packages_dir="${5:-}"
    local device_state="${6:-Shutdown}"
    local status
    local wrapper_pid
    local script_pid
    shift 6

    run_wrapper "$capture_dir" "$ramdisk_mount" "$stdout_file" "$stderr_file" "$cloned_source_packages_dir" "$device_state" "$@" &
    wrapper_pid="$!"

    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if [[ -f "${capture_dir}/xcodebuild-test-child.pid" ]]; then
            break
        fi
        sleep 1
    done
    [[ -f "${capture_dir}/xcodebuild-test-child.pid" ]] ||
        fail "wrapper did not start stub xcodebuild child before termination"

    script_pid="$(pgrep -P "$wrapper_pid" 2>/dev/null | head -n 1 || true)"
    [[ -n "$script_pid" ]] || fail "could not find test-ios.sh process for termination"

    kill -TERM "$script_pid" >/dev/null 2>&1 || true
    set +e
    wait "$wrapper_pid"
    status="$?"
    set -e
    echo "$status" >"${capture_dir}/wrapper.status"
}

write_stub_tools "${tmp_root}/bin"

local_capture="${tmp_root}/capture-local"
local_mount="${tmp_root}/ramdisk-local"
local_packages="${tmp_root}/persistent-ios-source-packages"
mkdir -p "${local_packages}/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal/steel/attn/kernels"
cat >"${local_packages}/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal/steel/attn/kernels/steel_attention.h" <<'HEADER'
if (is_bool) {}
if (BD == 128) {}
HEADER
run_wrapper "$local_capture" "$local_mount" "${tmp_root}/local.out" "${tmp_root}/local.err" "" "Booted" \
    IOS_TEST_RAMDISK_MB=16 \
    IOS_TEST_SOURCE_PACKAGES_CACHE_DIR="$local_packages"

assert_contains "${local_capture}/hdiutil.calls" "attach"
assert_contains "${local_capture}/hdiutil.calls" "detach"
assert_contains "${local_capture}/diskutil.calls" "erasevolume"
assert_contains "${local_capture}/diskutil.calls" "unmountDisk"
assert_contains "${local_capture}/xcodebuild.args" "-derivedDataPath"
assert_contains "${local_capture}/xcodebuild.args" "${local_mount}/vvterm-ios-derived-data."
assert_contains "${local_capture}/xcodebuild.args" "$local_packages"
assert_not_contains "${local_capture}/xcodebuild.args" "${local_mount}/vvterm-ios-source-packages"
assert_not_contains "${local_capture}/xcodebuild.args" "${tmp_root}/tmp/vvterm-ios-source-packages"
resolve_args_line="$(grep -n -- '-resolvePackageDependencies' "${local_capture}/xcodebuild.args" | head -n 1 | cut -d: -f1)"
[[ -n "$resolve_args_line" ]] || fail "missing resolvePackageDependencies invocation"
sed -n "${resolve_args_line},$((resolve_args_line + 8))p" "${local_capture}/xcodebuild.args" >"${tmp_root}/resolve.args"
assert_contains "${tmp_root}/resolve.args" "-derivedDataPath"
assert_contains "${tmp_root}/resolve.args" "${local_mount}/vvterm-ios-derived-data."
assert_file_missing_or_empty "${local_capture}/perl.calls"
assert_contains "${local_capture}/xcrun.calls" "simctl"
assert_contains "${local_capture}/xcrun.calls" "terminate"
assert_not_contains "${local_capture}/xcrun.calls" "shutdown"
assert_not_contains "${local_capture}/xcrun.calls" "bootstatus"
assert_contains "${local_capture}/xcodebuild.args" "-collect-test-diagnostics"
assert_contains "${local_capture}/xcodebuild.args" "never"
[[ -z "$(find "$local_mount" -maxdepth 1 -name 'vvterm-ios-derived-data.*' -print -quit)" ]] ||
    fail "auto-managed DerivedData was not removed from RAM disk"
[[ -n "$(find "${tmp_root}/logs" -name 'xcodebuild-test-attempt-1-passed.log' -print -quit)" ]] ||
    fail "diagnostic logs should be preserved outside the RAM disk"

reboot_capture="${tmp_root}/capture-reboot"
reboot_mount="${tmp_root}/ramdisk-reboot"
run_wrapper "$reboot_capture" "$reboot_mount" "${tmp_root}/reboot.out" "${tmp_root}/reboot.err" "" "Booted" \
    IOS_TEST_RAMDISK_MB=16 \
    IOS_TEST_REUSE_BOOTED_SIMULATOR=0 \
    IOS_TEST_COLLECT_DIAGNOSTICS=on-failure

assert_contains "${reboot_capture}/xcrun.calls" "shutdown"
assert_contains "${reboot_capture}/xcrun.calls" "bootstatus"
assert_contains "${reboot_capture}/xcodebuild.args" "-collect-test-diagnostics"
assert_contains "${reboot_capture}/xcodebuild.args" "on-failure"

explicit_capture="${tmp_root}/capture-explicit-packages"
explicit_mount="${tmp_root}/ramdisk-explicit-packages"
explicit_packages="${tmp_root}/explicit-xcode-cloned-source-packages"
run_wrapper "$explicit_capture" "$explicit_mount" "${tmp_root}/explicit.out" "${tmp_root}/explicit.err" "$explicit_packages" "Shutdown" \
    IOS_TEST_RAMDISK_MB=16

assert_contains "${explicit_capture}/xcodebuild.args" "$explicit_packages"
assert_not_contains "${explicit_capture}/xcodebuild.args" "${explicit_mount}/vvterm-ios-source-packages"

ci_capture="${tmp_root}/capture-ci"
ci_mount="${tmp_root}/ramdisk-ci"
run_wrapper "$ci_capture" "$ci_mount" "${tmp_root}/ci.out" "${tmp_root}/ci.err" "" "Shutdown" \
    GITHUB_ACTIONS=true \
    IOS_TEST_RAMDISK_MB=16

[[ ! -s "${ci_capture}/hdiutil.calls" ]] || fail "GitHub Actions must not create a RAM disk"
assert_contains "${ci_capture}/xcodebuild.args" "-derivedDataPath"
assert_not_contains "${ci_capture}/xcodebuild.args" "${ci_mount}/vvterm-ios-derived-data."
assert_contains "${tmp_root}/ci.out" "Ignoring IOS_TEST_RAMDISK_MB on GitHub Actions."

resolve_timeout_capture="${tmp_root}/capture-resolve-timeout"
resolve_timeout_mount="${tmp_root}/ramdisk-resolve-timeout"
run_wrapper_expect_failure "$resolve_timeout_capture" "$resolve_timeout_mount" \
    "${tmp_root}/resolve-timeout.out" "${tmp_root}/resolve-timeout.err" "" "Shutdown" \
    IOS_TEST_RAMDISK_MB=16 \
    IOS_TEST_NO_OUTPUT_TIMEOUT=1 \
    VVTERM_STUB_RESOLVE_STALL=1 \
    VVTERM_STUB_RESOLVE_SLEEP=3

assert_contains "${resolve_timeout_capture}/wrapper.status" "124"
assert_contains "${tmp_root}/resolve-timeout.err" "xcodebuild produced no output for 1s"
[[ ! -d "${tmp_root}/ios-test.lock" ]] || fail "resolve timeout should remove the iOS test lock"
[[ -z "$(find "$resolve_timeout_mount" -maxdepth 1 -name 'vvterm-ios-derived-data.*' -print -quit)" ]] ||
    fail "resolve timeout should clean auto-managed DerivedData from RAM disk"

test_timeout_capture="${tmp_root}/capture-test-timeout"
test_timeout_mount="${tmp_root}/ramdisk-test-timeout"
run_wrapper_expect_failure "$test_timeout_capture" "$test_timeout_mount" \
    "${tmp_root}/test-timeout.out" "${tmp_root}/test-timeout.err" "" "Shutdown" \
    IOS_TEST_RAMDISK_MB=16 \
    IOS_TEST_NO_OUTPUT_TIMEOUT=1 \
    VVTERM_STUB_TEST_STALL=1 \
    VVTERM_STUB_TEST_SLEEP=30 \
    VVTERM_STUB_TEST_CHILD_SLEEP=30

assert_contains "${test_timeout_capture}/wrapper.status" "124"
assert_contains "${tmp_root}/test-timeout.err" "xcodebuild produced no output for 1s"
assert_pid_not_running "${test_timeout_capture}/xcodebuild-test-child.pid" "test timeout"
assert_pid_not_running "${test_timeout_capture}/xcodebuild-test-grandchild.pid" "test timeout grandchild"
[[ ! -d "${tmp_root}/ios-test.lock" ]] || fail "test timeout should remove the iOS test lock"
[[ -z "$(find "$test_timeout_mount" -maxdepth 1 -name 'vvterm-ios-derived-data.*' -print -quit)" ]] ||
    fail "test timeout should clean auto-managed DerivedData from RAM disk"

test_term_capture="${tmp_root}/capture-test-term"
test_term_mount="${tmp_root}/ramdisk-test-term"
run_wrapper_and_terminate "$test_term_capture" "$test_term_mount" \
    "${tmp_root}/test-term.out" "${tmp_root}/test-term.err" "" "Shutdown" \
    IOS_TEST_RAMDISK_MB=16 \
    IOS_TEST_NO_OUTPUT_TIMEOUT=0 \
    VVTERM_STUB_TEST_STALL=1 \
    VVTERM_STUB_TEST_SLEEP=30 \
    VVTERM_STUB_TEST_CHILD_SLEEP=30

assert_contains "${test_term_capture}/wrapper.status" "143"
assert_pid_not_running "${test_term_capture}/xcodebuild-test-child.pid" "test trap termination"
assert_pid_not_running "${test_term_capture}/xcodebuild-test-grandchild.pid" "test trap termination grandchild"
[[ ! -d "${tmp_root}/ios-test.lock" ]] || fail "test trap termination should remove the iOS test lock"
[[ -z "$(find "$test_term_mount" -maxdepth 1 -name 'vvterm-ios-derived-data.*' -print -quit)" ]] ||
    fail "test trap termination should clean auto-managed DerivedData from RAM disk"

zero_tests_required_capture="${tmp_root}/capture-zero-tests-required"
zero_tests_required_mount="${tmp_root}/ramdisk-zero-tests-required"
run_wrapper_expect_failure "$zero_tests_required_capture" "$zero_tests_required_mount" \
    "${tmp_root}/zero-tests-required.out" "${tmp_root}/zero-tests-required.err" "" "Shutdown" \
    IOS_TEST_RAMDISK_MB=16 \
    IOS_TEST_REQUIRE_EXECUTED_TESTS=1 \
    VVTERM_STUB_ZERO_TESTS=1

assert_contains "${zero_tests_required_capture}/wrapper.status" "11"
assert_contains "${tmp_root}/zero-tests-required.err" "executed zero tests"

zero_tests_filter_capture="${tmp_root}/capture-zero-tests-filter"
zero_tests_filter_mount="${tmp_root}/ramdisk-zero-tests-filter"
run_wrapper_expect_failure "$zero_tests_filter_capture" "$zero_tests_filter_mount" \
    "${tmp_root}/zero-tests-filter.out" "${tmp_root}/zero-tests-filter.err" "" "Shutdown" \
    IOS_TEST_RAMDISK_MB=16 \
    VVTERM_STUB_ZERO_TESTS=1 \
    -- \
    -only-testing:VVTermTests/MissingRenamedTest

assert_contains "${zero_tests_filter_capture}/wrapper.status" "11"
assert_contains "${tmp_root}/zero-tests-filter.err" "Check -only-testing arguments"

echo "test-ios RAM disk self-test passed"
