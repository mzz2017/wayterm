#!/usr/bin/env bash
set -euo pipefail

project_file="${1:-Waterm.xcodeproj/project.pbxproj}"
resolved_file="${2:-Waterm.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved}"

failed=0

report_matches() {
  local file="$1"
  local pattern="$2"
  local message="$3"

  while IFS=: read -r line_number line; do
    [[ -n "${line_number}" ]] || continue
    echo "::error file=${file},line=${line_number}::${message}: ${line}"
    failed=1
  done < <(grep -nE "${pattern}" "${file}" || true)
}

if [[ ! -f "${project_file}" ]]; then
  echo "::error::Missing Xcode project file: ${project_file}"
  exit 1
fi

if [[ ! -f "${resolved_file}" ]]; then
  echo "::error::Missing SwiftPM resolved file: ${resolved_file}"
  exit 1
fi

report_matches \
  "${project_file}" \
  'kind = branch;' \
  'SwiftPM package requirements must use immutable versions or revisions, not branches'

report_matches \
  "${resolved_file}" \
  '"branch"[[:space:]]*:' \
  'Package.resolved must not record branch-based package state'

if [[ "${failed}" -ne 0 ]]; then
  exit 1
fi

echo "SwiftPM package requirements are pinned to immutable versions or revisions."
