#!/usr/bin/env bash
set -euo pipefail

project="${IOS_TEST_PROJECT:-VVTerm.xcodeproj}"
scheme="${IOS_TEST_SCHEME:-VVTerm}"
device_name="${IOS_TEST_DEVICE_NAME:-iPhone 17}"
device_name_candidates="${IOS_TEST_DEVICE_NAME_CANDIDATES:-$device_name}"
destination_id="${IOS_TEST_DESTINATION_ID:-}"
retries="${IOS_TEST_RETRIES:-2}"
app_identifier="${IOS_TEST_APP_IDENTIFIER:-app.vivy.VivyTerm}"
allow_device_fallback="${IOS_TEST_ALLOW_DEVICE_FALLBACK:-0}"
lock_dir="${IOS_TEST_LOCK_DIR:-${TMPDIR:-/tmp}/vvterm-ios-test.lock}"
lock_timeout="${IOS_TEST_LOCK_TIMEOUT:-600}"
derived_data_path="${IOS_TEST_DERIVED_DATA_PATH:-}"
keep_derived_data="${IOS_TEST_KEEP_DERIVED_DATA:-0}"
lock_acquired=0
created_derived_data=0
log_file=""

cleanup() {
    if [[ -n "$log_file" ]]; then
        rm -f "$log_file"
    fi
    if [[ "$created_derived_data" -eq 1 && "$keep_derived_data" != "1" ]]; then
        rm -rf "$derived_data_path"
    fi
    if [[ "$lock_acquired" -eq 1 ]]; then
        rm -rf "$lock_dir"
    fi
}

trap cleanup EXIT
trap 'trap - EXIT INT TERM; cleanup; exit 130' INT
trap 'trap - EXIT INT TERM; cleanup; exit 143' TERM

acquire_global_lock() {
    local start
    start="$(date +%s)"

    while ! mkdir "$lock_dir" 2>/dev/null; do
        if [[ -f "$lock_dir/pid" ]]; then
            local owner_pid
            owner_pid="$(cat "$lock_dir/pid" 2>/dev/null || true)"
            if [[ -n "$owner_pid" ]] && ! kill -0 "$owner_pid" 2>/dev/null; then
                echo "Removing stale iOS test lock from PID ${owner_pid}." >&2
                rm -rf "$lock_dir"
                continue
            fi
        fi

        local now
        now="$(date +%s)"
        if (( now - start >= lock_timeout )); then
            echo "Timed out waiting for iOS test lock: ${lock_dir}" >&2
            exit 3
        fi

        echo "Waiting for iOS test lock: ${lock_dir}" >&2
        sleep 2
    done

    lock_acquired=1
    printf '%s\n' "$$" > "$lock_dir/pid"
}

prepare_derived_data() {
    if [[ -n "$derived_data_path" ]]; then
        mkdir -p "$derived_data_path"
        return
    fi

    derived_data_path="$(mktemp -d -t vvterm-ios-derived-data.XXXXXX)"
    created_derived_data=1
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

acquire_global_lock
prepare_derived_data

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
    prepare_simulator "$udid"

    log_file="$(mktemp -t vvterm-ios-test.XXXXXX)"
    set +e
    xcodebuild test -quiet \
        -project "$project" \
        -scheme "$scheme" \
        -destination "platform=iOS Simulator,id=${udid}" \
        -derivedDataPath "$derived_data_path" \
        -parallel-testing-enabled NO \
        "$@" \
        ENABLE_DEBUG_DYLIB=NO 2>&1 | tee "$log_file"
    last_status="${PIPESTATUS[0]}"
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
