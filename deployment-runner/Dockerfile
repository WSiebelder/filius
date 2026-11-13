FROM filius-builder:local

USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends docker-compose-v2 rsync \
    && rm -rf /var/lib/apt/lists/*

ENV RUNNER_NAME=deploy-runner \
    RUNNER_LABELS=self-hosted,linux,x64,docker-deploy

USER runner
