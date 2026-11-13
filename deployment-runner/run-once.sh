#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export RUNNER_IMAGE="${RUNNER_IMAGE:-filius-deployer:local}"
export RUNNER_KIND=deploy

exec "${SCRIPT_DIR}/../build-runner/run-once.sh" "$@"
