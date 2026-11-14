#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly RUNNER_NAME=filius-orchestrator
readonly RUNNER_DOCKER_USER="${RUNNER_DOCKER_USER:-filius-runner}"
readonly RUNNER_HOME="${RUNNER_HOME:-/var/lib/filius-runner}"

[[ "${EUID}" -eq 0 ]] || { echo "Run this launcher as root." >&2; exit 1; }
runner_uid="$(id -u "${RUNNER_DOCKER_USER}")"
export DOCKER_SOCKET="${DOCKER_SOCKET:-/run/user/${runner_uid}/docker.sock}"
export DOCKER_HOST="unix://${DOCKER_SOCKET}"
export RUNNER_NAME RUNNER_DOCKER_USER RUNNER_HOME

case "${1:-start}" in
  start)
    : "${GITHUB_URL:?Set GITHUB_URL to the orchestration repository URL}"
    export RUNNER_KIND=orchestration
    export RUNNER_IMAGE=filius-builder:local
    export FILIUS_DEPLOYMENTS_DIR="${RUNNER_HOME}/deployments"
    exec /usr/bin/bash "${SCRIPT_DIR}/../build-runner/run-once.sh" "${GITHUB_URL}"
    ;;
  stop)
    docker info >/dev/null
    if ! container_id="$(docker container ls --all --quiet --filter "name=^/${RUNNER_NAME}$")"; then
      echo "Could not inspect the orchestration container." >&2
      exit 1
    fi
    [[ -n "${container_id}" ]] || exit 0
    service="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.service" }}' "${container_id}")"
    project="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' "${container_id}")"
    if [[ "${service}" != orchestration-runner || "${project}" != filius-runners ]]; then
      echo "Refusing to stop ${RUNNER_NAME}: it is not the managed orchestration container." >&2
      exit 1
    fi
    timeout 40s docker stop --time 30 "${container_id}" >/dev/null
    docker rm "${container_id}" >/dev/null 2>&1 || true
    ;;
  *)
    echo "Usage: $0 [start|stop]" >&2
    exit 2
    ;;
esac
