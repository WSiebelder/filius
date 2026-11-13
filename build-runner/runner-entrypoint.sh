#!/usr/bin/env bash
set -euo pipefail

: "${GITHUB_URL:?Set GITHUB_URL to the repository or organization URL}"
: "${RUNNER_TOKEN:?Set RUNNER_TOKEN to a short-lived runner registration token}"

runner_name="${RUNNER_NAME:-build-runner}"
runner_labels="${RUNNER_LABELS:-self-hosted,linux,x64,docker-build}"

./config.sh \
  --url "${GITHUB_URL}" \
  --token "${RUNNER_TOKEN}" \
  --name "${runner_name}" \
  --labels "${runner_labels}" \
  --work /home/runner/_work \
  ${RUNNER_EPHEMERAL:+--ephemeral} \
  --unattended \
  --replace

unset RUNNER_TOKEN
./run.sh
