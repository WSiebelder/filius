#!/usr/bin/env bash
set -euo pipefail

: "${GITHUB_URL:?Set GITHUB_URL}"
: "${RUNNER_NAME:?Set RUNNER_NAME}"
: "${FILIUS_RUNNER_INSTANCE:?Start this runner through the host run.sh launcher}"
socket="${FILIUS_TOKEN_SOCKET:-/filius-token/broker.sock}"
[[ -S "${socket}" ]] || { echo "Token broker socket is missing; install/start the host runtime with setup.sh." >&2; exit 1; }

# Do not retry: even a failed/lost request consumes this startup's grant.
if ! response="$(jq -nc --arg instance "${FILIUS_RUNNER_INSTANCE}" --arg repository "${GITHUB_URL}" --arg name "${RUNNER_NAME}" \
  '{instance: $instance, repository: $repository, name: $name}' \
  | curl --silent --show-error --fail --connect-timeout 5 --max-time 30 \
      --unix-socket "${socket}" --header 'Content-Type: application/json' \
      --data-binary @- http://localhost/token)"; then
  echo "Token request failed; startup grants are not retried. Inspect filius-token-broker.service on the host." >&2
  exit 1
fi
jq -er '.token | select(type == "string" and length > 0)' <<<"${response}"
