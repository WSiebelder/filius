FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
ARG RUNNER_VERSION=2.338.2

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        jq \
        docker.io \
        libicu74 \
        nodejs \
        sudo \
        tar \
        tini \
        unzip \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 1001 --shell /bin/bash runner \
    && install -d -o runner -g runner /opt/actions-runner /home/runner/_work \
    && curl -fsSL "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz" \
       | tar -xz -C /opt/actions-runner \
    && /opt/actions-runner/bin/installdependencies.sh \
    && chown -R runner:runner /opt/actions-runner

COPY runner-entrypoint.sh /usr/local/bin/runner-entrypoint
COPY runner-token.sh /usr/local/bin/runner-token
RUN chmod 0755 /usr/local/bin/runner-entrypoint /usr/local/bin/runner-token

ENV RUNNER_ALLOW_RUNASROOT=0 \
    RUNNER_VERSION=${RUNNER_VERSION} \
    RUNNER_NAME=build-runner \
    RUNNER_LABELS=self-hosted,linux,x64,docker-build \
    RUNNER_EPHEMERAL=true

WORKDIR /opt/actions-runner
USER runner

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/runner-entrypoint"]
