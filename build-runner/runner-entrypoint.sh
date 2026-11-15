#!/usr/bin/env bash
set -euo pipefail

: "${GITHUB_URL:?Set GITHUB_URL to the repository or organization URL}"

runner_name="${RUNNER_NAME:-build-runner}"
runner_labels="${RUNNER_LABELS:-self-hosted,linux,x64,docker-build}"
current_version="${RUNNER_VERSION:-unknown}"
if [[ -n "${FILIUS_RUNNER_INSTANCE:-}" ]]; then
  unset RUNNER_TOKEN
  runner_token="$(/usr/local/bin/runner-token)"
else
  # Allow image-first upgrades from an installed pre-broker host runtime.
  : "${RUNNER_TOKEN:?Start this runner with the host run.sh launcher}"
  echo "WARNING: Legacy registration-token startup; install the broker runtime with setup.sh." >&2
  runner_token="${RUNNER_TOKEN}"
fi
unset RUNNER_TOKEN
unset FILIUS_RUNNER_INSTANCE

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
  --token "${runner_token}" \
  --name "${runner_name}" \
  --labels "${runner_labels}" \
  --work /home/runner/_work \
  ${RUNNER_EPHEMERAL:+--ephemeral} \
  --disableupdate \
  --unattended \
  --replace

unset runner_token
./run.sh
