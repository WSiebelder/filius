#!/usr/bin/env bash
set -euo pipefail

: "${GITHUB_URL:?Set GITHUB_URL to the repository or organization URL}"
: "${RUNNER_TOKEN:?Set RUNNER_TOKEN to a short-lived runner registration token}"

runner_name="${RUNNER_NAME:-build-runner}"
runner_labels="${RUNNER_LABELS:-self-hosted,linux,x64,docker-build}"
current_version="${RUNNER_VERSION:-unknown}"

latest_version="$(curl --silent --show-error --fail --max-time 10 \
  --header 'Accept: application/vnd.github+json' \
  https://api.github.com/repos/actions/runner/releases/latest \
  | jq -er '.tag_name | sub("^v"; "")' 2>/dev/null)" || latest_version=""

if [[ ! "${latest_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "WARNING: Could not check the latest GitHub Actions runner version; using ${current_version}." >&2
elif [[ "${current_version}" != "${latest_version}" ]] \
  && [[ "$(printf '%s\n' "${current_version}" "${latest_version}" | sort -V | tail -n 1)" == "${latest_version}" ]]; then
  echo "WARNING: This image has Actions runner ${current_version}; GitHub's latest stable release is ${latest_version}. Update RUNNER_VERSION and rebuild the image." >&2
fi

./config.sh \
  --url "${GITHUB_URL}" \
  --token "${RUNNER_TOKEN}" \
  --name "${runner_name}" \
  --labels "${runner_labels}" \
  --work /home/runner/_work \
  ${RUNNER_EPHEMERAL:+--ephemeral} \
  --disableupdate \
  --unattended \
  --replace

unset RUNNER_TOKEN
./run.sh
