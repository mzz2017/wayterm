#!/usr/bin/env bash
set -euo pipefail

project="${IOS_TEST_PROJECT:-VVTerm.xcodeproj}"
scheme="${IOS_TEST_SCHEME:-VVTermUnitTests}"
device_name="${IOS_TEST_DEVICE_NAME:-iPhone 17}"
device_name_candidates="${IOS_TEST_DEVICE_NAME_CANDIDATES:-$device_name}"
destination_id="${IOS_TEST_DESTINATION_ID:-}"
retries="${IOS_TEST_RETRIES:-2}"
app_identifier="${IOS_TEST_APP_IDENTIFIER:-app.vivy.VivyTerm}"
allow_device_fallback="${IOS_TEST_ALLOW_DEVICE_FALLBACK:-0}"
lock_dir="${IOS_TEST_LOCK_DIR:-${TMPDIR:-/tmp}/vvterm-ios-test.lock}"
lock_timeout="${IOS_TEST_LOCK_TIMEOUT:-600}"
lock_owner_metadata_grace="${IOS_TEST_LOCK_OWNER_METADATA_GRACE:-10}"
derived_data_path="${IOS_TEST_DERIVED_DATA_PATH:-}"
cloned_source_packages_path="${IOS_TEST_CLONED_SOURCE_PACKAGES_DIR:-${TMPDIR:-/tmp}/vvterm-ios-source-packages}"
keep_derived_data="${IOS_TEST_KEEP_DERIVED_DATA:-0}"
no_output_timeout="${IOS_TEST_NO_OUTPUT_TIMEOUT:-900}"
xcodebuild_quiet="${IOS_TEST_XCODEBUILD_QUIET:-0}"
xcodebuild_action="${IOS_TEST_XCODEBUILD_ACTION:-test}"
progress_interval="${IOS_TEST_PROGRESS_INTERVAL:-0}"
progress_log_lines="${IOS_TEST_PROGRESS_LOG_LINES:-20}"
failure_log_lines="${IOS_TEST_FAILURE_LOG_LINES:-120}"
lock_acquired=0
cleanup_derived_data=0
log_file=""
tail_pid=""
watchdog_pid=""
progress_pid=""
xcode_pid=""

cleanup() {
    if [[ -n "$tail_pid" ]]; then
        kill "$tail_pid" >/dev/null 2>&1 || true
    fi
    if [[ -n "$watchdog_pid" ]]; then
        kill "$watchdog_pid" >/dev/null 2>&1 || true
    fi
    if [[ -n "$progress_pid" ]]; then
        kill "$progress_pid" >/dev/null 2>&1 || true
    fi
    if [[ -n "$xcode_pid" ]]; then
        kill "$xcode_pid" >/dev/null 2>&1 || true
    fi
    if [[ -n "$log_file" ]]; then
        rm -f "$log_file"
    fi
    if [[ "$cleanup_derived_data" -eq 1 && "$keep_derived_data" != "1" ]]; then
        rm -rf "$derived_data_path"
    fi
    if [[ "$lock_acquired" -eq 1 ]]; then
        if [[ "$(cat "$lock_dir/pid" 2>/dev/null || true)" == "$$" ]]; then
            rm -rf "$lock_dir"
        fi
    fi
}

trap cleanup EXIT
trap 'trap - EXIT INT TERM; cleanup; exit 130' INT
trap 'trap - EXIT INT TERM; cleanup; exit 143' TERM
trap 'trap - EXIT HUP; cleanup; exit 129' HUP

acquire_global_lock() {
    local start
    start="$(date +%s)"

    while ! mkdir "$lock_dir" 2>/dev/null; do
        local owner_pid=""
        local owner_command=""
        local now
        now="$(date +%s)"
        if [[ -f "$lock_dir/pid" ]]; then
            owner_pid="$(cat "$lock_dir/pid" 2>/dev/null || true)"
        fi

        if [[ -n "$owner_pid" ]]; then
            if [[ -n "$owner_pid" ]] && ! kill -0 "$owner_pid" 2>/dev/null; then
                echo "Removing stale iOS test lock from PID ${owner_pid}." >&2
                rm -rf "$lock_dir"
                continue
            fi
            owner_command="$(ps -p "$owner_pid" -o command= 2>/dev/null || true)"
        else
            local lock_mtime
            lock_mtime="$(stat -f %m "$lock_dir" 2>/dev/null || printf '%s\n' "$now")"
            if (( now - lock_mtime >= lock_owner_metadata_grace )); then
                echo "Removing stale iOS test lock without an owner PID: ${lock_dir}" >&2
                rm -rf "$lock_dir"
                continue
            fi
        fi

        if (( now - start >= lock_timeout )); then
            echo "Timed out waiting for iOS test lock: ${lock_dir}" >&2
            if [[ -n "$owner_pid" ]]; then
                echo "Lock owner PID: ${owner_pid}" >&2
                echo "Lock owner command: ${owner_command:-unknown}" >&2
            fi
            exit 3
        fi

        if [[ -n "$owner_pid" ]]; then
            echo "Waiting for iOS test lock: ${lock_dir} (owner PID ${owner_pid}: ${owner_command:-unknown})" >&2
        else
            echo "Waiting for iOS test lock: ${lock_dir}" >&2
        fi
        sleep 2
    done

    lock_acquired=1
    printf '%s\n' "$$" > "$lock_dir/pid"
    printf '%s\n' "${PPID:-}" > "$lock_dir/ppid"
    ps -p "$$" -o command= > "$lock_dir/command" 2>/dev/null || true
    pwd > "$lock_dir/cwd" 2>/dev/null || true
    date > "$lock_dir/started_at" 2>/dev/null || true
}

prepare_derived_data() {
    if [[ -n "$derived_data_path" ]]; then
        if [[ "$keep_derived_data" != "1" ]]; then
            if ! is_auto_cleanup_derived_data_path "$derived_data_path"; then
                echo "Refusing to use IOS_TEST_DERIVED_DATA_PATH without IOS_TEST_KEEP_DERIVED_DATA=1: ${derived_data_path}" >&2
                echo "Use a vvterm-* directory directly under the system temp directory for auto-cleanup, or set IOS_TEST_KEEP_DERIVED_DATA=1 for intentional diagnostics." >&2
                exit 6
            fi
            cleanup_derived_data=1
        fi
        mkdir -p "$derived_data_path"
        return
    fi

    derived_data_path="$(mktemp -d -t vvterm-ios-derived-data.XXXXXX)"
    cleanup_derived_data=1
}

is_auto_cleanup_derived_data_path() {
    local path="$1"
    local parent
    local canonical_parent
    local temp_parent
    local base

    parent="$(dirname "$path")"
    base="$(basename "$path")"

    case "$base" in
    vvterm-* | vvterm-ios-derived-data.*)
        ;;
    *)
        return 1
        ;;
    esac

    if [[ ! -d "$parent" ]]; then
        return 1
    fi

    canonical_parent="$(cd "$parent" && pwd -P)"
    temp_parent="$(cd "${TMPDIR:-/tmp}" && pwd -P)"

    [[ "$canonical_parent" == "$temp_parent" ]] ||
        [[ "$canonical_parent" == "/private/tmp" ]] ||
        [[ "$canonical_parent" == /private/var/folders/*/T ]] ||
        [[ "$canonical_parent" == /var/folders/*/T ]]
}

prepare_cloned_source_packages() {
    mkdir -p "$cloned_source_packages_path"
}

resolve_packages() {
    xcodebuild -resolvePackageDependencies \
        -project "$project" \
        -scheme "$scheme" \
        -clonedSourcePackagesDirPath "$cloned_source_packages_path"
}

patch_mlx_swift_metal_warnings() {
    local attention_header

    attention_header="${cloned_source_packages_path}/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal/steel/attn/kernels/steel_attention.h"
    if [[ ! -f "$attention_header" ]]; then
        return
    fi

    perl -0pi -e '
        s/if constexpr \(is_bool\)/if (is_bool)/g;
        s/if constexpr \(BD == 128\)/if (BD == 128)/g;
    ' "$attention_header"

    if grep -Eq 'if constexpr \((is_bool|BD == 128)\)' "$attention_header"; then
        echo "Unable to patch mlx-swift Metal C++17 extension warnings in ${attention_header}." >&2
        exit 4
    fi
}

validate_xcodebuild_action() {
    case "$xcodebuild_action" in
    test | build-for-testing)
        ;;
    *)
        echo "Unsupported IOS_TEST_XCODEBUILD_ACTION: ${xcodebuild_action}" >&2
        exit 5
        ;;
    esac
}

validate_unsigned_integer() {
    local name="$1"
    local value="$2"
    local exit_code="$3"

    case "$value" in
    '' | *[!0-9]*)
        echo "Unsupported ${name}: ${value}" >&2
        exit "$exit_code"
        ;;
    *)
        ;;
    esac
}

validate_test_logging_settings() {
    validate_unsigned_integer "IOS_TEST_PROGRESS_INTERVAL" "$progress_interval" 7
    validate_unsigned_integer "IOS_TEST_PROGRESS_LOG_LINES" "$progress_log_lines" 8
    validate_unsigned_integer "IOS_TEST_FAILURE_LOG_LINES" "$failure_log_lines" 9
}

print_xcodebuild_process_snapshot() {
    echo "xcodebuild PID: ${xcode_pid}"
    ps -o pid,ppid,etime,pcpu,pmem,state,command -p "$xcode_pid" || true

    local child_pids
    child_pids="$(pgrep -P "$xcode_pid" 2>/dev/null || true)"
    if [[ -n "$child_pids" ]]; then
        echo "xcodebuild direct child processes:"
        ps -o pid,ppid,etime,pcpu,pmem,state,command -p "$(printf '%s\n' "$child_pids" | paste -sd, -)" || true
    else
        echo "xcodebuild direct child processes: none"
    fi
}

print_recent_xcodebuild_log() {
    local line_count="$1"
    local now="$2"
    local last_output_at

    if [[ -s "$log_file" ]]; then
        last_output_at="$(stat -f %m "$log_file")"
        echo "Seconds since last xcodebuild output: $((now - last_output_at))"
        echo "Recent xcodebuild log (${line_count} lines):"
        tail -n "$line_count" "$log_file" 2>/dev/null || true
    else
        echo "No xcodebuild output has been captured yet."
    fi
}

start_progress_reporter() {
    local started_at="$1"

    if [[ "$progress_interval" == "0" ]]; then
        return
    fi

    (
        local elapsed
        local now

        while kill -0 "$xcode_pid" 2>/dev/null; do
            sleep "$progress_interval" || exit 0
            kill -0 "$xcode_pid" 2>/dev/null || exit 0

            now="$(date +%s)"
            elapsed=$((now - started_at))

            if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
                echo "::group::iOS test progress (${elapsed}s)"
            fi

            echo "iOS test still running after ${elapsed}s."
            echo "Project: ${project}"
            echo "Scheme: ${scheme}"
            echo "Action: ${xcodebuild_action}"
            echo "Destination: platform=iOS Simulator,id=${udid}"
            print_xcodebuild_process_snapshot
            print_recent_xcodebuild_log "$progress_log_lines" "$now"

            if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
                echo "::endgroup::"
            fi
        done
    ) &
    progress_pid="$!"
}

resolve_destination_id() {
    if [[ -n "$destination_id" ]]; then
        printf '%s\n' "$destination_id"
        return 0
    fi

    local candidate
    local candidate_id
    IFS=',' read -ra candidates <<< "$device_name_candidates"
    for candidate in "${candidates[@]}"; do
        candidate="${candidate#"${candidate%%[![:space:]]*}"}"
        candidate="${candidate%"${candidate##*[![:space:]]}"}"
        [[ -n "$candidate" ]] || continue

        candidate_id="$(
            xcrun simctl list devices available |
                sed -n "s/^[[:space:]]*${candidate} (\([0-9A-F-]\{36\}\)) .*/\1/p" |
                head -n 1
        )"
        if [[ -n "$candidate_id" ]]; then
            printf '%s\n' "$candidate_id"
            return 0
        fi
    done

    if [[ "$allow_device_fallback" == "1" ]]; then
        echo "No requested simulator found; falling back to the first available iPhone simulator." >&2
        xcrun simctl list devices available |
            sed -n "s/^[[:space:]]*iPhone[^()]*(\([0-9A-F-]\{36\}\)) .*/\1/p" |
            head -n 1
    fi
}

prepare_simulator() {
    local udid="$1"

    xcrun simctl terminate "$udid" "$app_identifier" >/dev/null 2>&1 || true
    xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
    sleep 2
    xcrun simctl boot "$udid" >/dev/null 2>&1 || true
    xcrun simctl bootstatus "$udid" -b
    sleep 1
}

is_preflight_failure() {
    local log_file="$1"

    grep -Eq \
        'Application failed preflight checks|Failed to install or launch the test runner|Simulator device failed to launch .*Busy' \
        "$log_file"
}

run_xcodebuild_test() {
    local status_file
    local timeout_file
    local -a xcodebuild_args
    local last_output_at
    local now
    local started_at

    status_file="$(mktemp -t vvterm-ios-test-status.XXXXXX)"
    timeout_file="$(mktemp -t vvterm-ios-test-timeout.XXXXXX)"
    rm -f "$timeout_file"
    : > "$log_file"

    xcodebuild_args=("$xcodebuild_action")
    if [[ "$xcodebuild_quiet" == "1" ]]; then
        xcodebuild_args+=(-quiet)
    fi

    xcodebuild "${xcodebuild_args[@]}" \
        -project "$project" \
        -scheme "$scheme" \
        -destination "platform=iOS Simulator,id=${udid}" \
        -derivedDataPath "$derived_data_path" \
        -clonedSourcePackagesDirPath "$cloned_source_packages_path" \
        -parallel-testing-enabled NO \
        "$@" \
        ENABLE_DEBUG_DYLIB=NO >"$log_file" 2>&1 &
    xcode_pid="$!"
    started_at="$(date +%s)"

    tail -n +1 -f "$log_file" &
    tail_pid="$!"
    start_progress_reporter "$started_at"

    if [[ "$no_output_timeout" != "0" ]]; then
        (
            last_output_at="$(date +%s)"
            while kill -0 "$xcode_pid" 2>/dev/null; do
                if [[ -s "$log_file" ]]; then
                    last_output_at="$(stat -f %m "$log_file")"
                fi

                now="$(date +%s)"
                if (( now - last_output_at >= no_output_timeout )); then
                    {
                        echo "xcodebuild produced no output for ${no_output_timeout}s; terminating stalled iOS test run."
                        print_xcodebuild_process_snapshot
                        print_recent_xcodebuild_log "$failure_log_lines" "$now"
                    } >&2
                    touch "$timeout_file"
                    kill -TERM "$xcode_pid" >/dev/null 2>&1 || true
                    sleep 5
                    kill -KILL "$xcode_pid" >/dev/null 2>&1 || true
                    exit 0
                fi

                sleep 5
            done
        ) &
        watchdog_pid="$!"
    fi

    wait "$xcode_pid"
    printf '%s\n' "$?" > "$status_file"
    xcode_pid=""

    if [[ -n "$watchdog_pid" ]]; then
        kill "$watchdog_pid" >/dev/null 2>&1 || true
        wait "$watchdog_pid" >/dev/null 2>&1 || true
        watchdog_pid=""
    fi
    if [[ -n "$progress_pid" ]]; then
        kill "$progress_pid" >/dev/null 2>&1 || true
        wait "$progress_pid" >/dev/null 2>&1 || true
        progress_pid=""
    fi
    if [[ -n "$tail_pid" ]]; then
        kill "$tail_pid" >/dev/null 2>&1 || true
        wait "$tail_pid" >/dev/null 2>&1 || true
        tail_pid=""
    fi

    if [[ -f "$timeout_file" ]]; then
        rm -f "$status_file" "$timeout_file"
        return 124
    fi

    last_status="$(cat "$status_file")"
    if [[ "$last_status" -ne 0 ]]; then
        local finished_at
        finished_at="$(date +%s)"
        if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
            echo "::group::iOS test failure diagnostics"
        fi
        echo "xcodebuild exited with status ${last_status}."
        print_recent_xcodebuild_log "$failure_log_lines" "$finished_at"
        if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
            echo "::endgroup::"
        fi
    fi
    rm -f "$status_file" "$timeout_file"
    return "$last_status"
}

validate_xcodebuild_action
validate_test_logging_settings
acquire_global_lock
prepare_derived_data
prepare_cloned_source_packages
resolve_packages
patch_mlx_swift_metal_warnings

udid="$(resolve_destination_id)"
if [[ -z "$udid" ]]; then
    echo "Unable to find an available iOS simulator from: ${device_name_candidates}" >&2
    echo "Set IOS_TEST_DESTINATION_ID to a simulator UDID if the default name is unavailable." >&2
    exit 2
fi

attempt=1
total_attempts=$((retries + 1))
last_status=0
while (( attempt <= total_attempts )); do
    echo "Preparing iOS simulator ${device_name} (${udid}) for test attempt ${attempt}/${total_attempts}."
    echo "Using isolated DerivedData at ${derived_data_path}."
    echo "Using shared cloned source packages at ${cloned_source_packages_path}."
    if [[ "$progress_interval" != "0" ]]; then
        echo "Reporting iOS test progress every ${progress_interval}s."
        echo "Progress log tail lines: ${progress_log_lines}."
    fi
    echo "Failure log tail lines: ${failure_log_lines}."
    prepare_simulator "$udid"

    log_file="$(mktemp -t vvterm-ios-test.XXXXXX)"
    set +e
    run_xcodebuild_test "$@"
    last_status="$?"
    set -e

    if [[ "$last_status" -eq 0 ]]; then
        rm -f "$log_file"
        log_file=""
        exit 0
    fi

    if (( attempt <= retries )) && is_preflight_failure "$log_file"; then
        echo "xcodebuild hit a simulator preflight launch failure; retrying after simulator cleanup." >&2
        rm -f "$log_file"
        log_file=""
        attempt=$((attempt + 1))
        continue
    fi

    rm -f "$log_file"
    log_file=""
    exit "$last_status"
done

exit "$last_status"
