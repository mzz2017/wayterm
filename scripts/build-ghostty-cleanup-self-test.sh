#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

"${repo_root}/scripts/build.sh" self-test-ghostty-cleanup
