# Backlog

## Scope and priorities

The first objective is documentation: `STATE.md` records the inspected source
and staged changes. All implementation below is future work, not functionality
delivered by this documentation change.

The destination is an idempotent `setup.sh` for a headless Ubuntu-based Linux
Mint host, manually requested queue discovery, repository-scoped build runners,
one central deployment worker, and reusable Docker build/test workflows. Keep
the dedicated rootless daemon, one-job ephemeral runners and host-only PAT.
Do not alter GitHub account configuration without explicit consent.

P0 establishes bootstrap, supervision and manual orchestration. P1 delivers
current runner maintenance and application delivery. P2 completes operational
hardening and verification tooling. Acceptance criteria are future checks; no
tests or host setup were executed for this documentation task.

## Locked target architecture

This replaces the earlier organization-wide pool proposal and blanket revival
of every configured repository. Manual dispatch now performs an on-demand
queue scan. No organization, repository migration, periodic queue polling or
continuously running scheduler is required.

- **Always-available orchestration:** one worker registered to this repository
  has a dedicated orchestration label and boot-persistent host supervision.
  It accepts manual `workflow_dispatch` requests even after other workers expire.
  Availability is maintained by launching a fresh ephemeral runner after each job,
  not by making a single runner registration permanent.
- **Central eligibility configuration:** this repository specifies the allowed
  repository URLs, build-worker capacity limits and deployment settings.
  The list grants eligibility, not an instruction to start workers for every
  entry. Setup validates and installs this configuration on the host.
- **Manual discovery and revival:** the `runner_dispatch` workflow, triggered
  by `workflow_dispatch`, queries GitHub for pending work under the configured
  account. Only allowlisted repositories with runnable queued jobs matching the
  supported runner labels can receive new workers. Account repository discovery
  must never expand the allowlist. The workflow can delegate authenticated API
  reads and launches to the host so the host PAT remains outside containers.
- **Capacity-aware launches:** reuse existing healthy workers and account for
  idle, busy and starting workers before launching more. Start only the missing
  capacity justified by queued jobs, up to each repository's configured limit.
  An eligible repository without matching queued work receives no new runner.
- **Repository-scoped builds:** each build runner is registered to the
  repository whose jobs it accepts. Capacity is limited per repository;
  discovery happens only on explicit dispatch, not in a continuous scheduler.
- **Eight-hour continuous idle limit:** revived build/deployment workers wait
  at most eight continuous hours without accepting a job. Job start cancels the
  idle deadline; after completion a fresh runner gets a new idle period.
  Active jobs are never killed by this limit, even when they run longer than
  eight hours. Expiry removes the idle runner and disables its worker until
  another manual revival; retry/reboot must not resurrect expired workers.
  Orchestration is exempt from this limit.
- **One central deployment worker:** register it to this repository and execute
  deployment workflows here, serialized globally. Dispatch also checks this
  repository's deployment queue and starts that worker only if matching pending
  deployment work needs it; reuse an existing worker instead of duplicating it.
  Participating repositories submit successful release information here using an explicitly
  authorized trigger. Merely calling a reusable workflow hosted here does not
  move execution out of the caller repository.
- **Expected queue behavior:** dispatch scans current runnable work, including
  queued jobs within already-running workflows. It does not start workers for
  jobs blocked by dependencies/approvals or requiring unsupported labels.
  Jobs becoming ready later can use already-enabled matching workers; otherwise
  another manual dispatch is needed. Receiving a build/deployment request does
  not automatically trigger discovery or revival.
- **No always-on workload pool:** setup/boot ensures orchestration is available;
  build/deployment workers are activated by explicit dispatch when work exists.
  Re-running setup must not silently re-enable expired workers.

The mechanism for authenticated host control, release submission and the
deployment settings contract remains to be implemented. These details do not
reopen the above target choices.

## B01 - Configure repository-scoped runners and central roles

**Priority:** P0. **Dependencies:** none.

**Evidence:** `setup.sh:56-65` and `build-runner/run-once.sh:69-100` require a
repository URL and repository registration endpoint. The current pool targets
one repository and cannot yet distinguish orchestration from ordinary builds.

**Deliverable:** Define central configuration for this control repository,
eligible build repositories, per-repository worker capacity limits and
application deployment mappings. Prompt/validate the owner URL and explicit repository
URLs during setup; an owner URL is a configuration aid, not a registration
scope. Validate repository access, Actions read permission for run/job discovery
and repository Administration write permission for registration when using a
fine-grained PAT. Introduce distinct orchestration/build/deployment labels and keep all registrations
repository-scoped.

**Acceptance:** Build workers register only to their configured repository;
orchestration and the single deployment worker register here. Jobs select the
intended role without consuming the orchestration worker for ordinary builds
or deployments. An allowlist entry alone never launches a workload runner.
Invalid targets/counts, missing repository access and inadequate
credentials fail clearly without exposing tokens. Personal-account repositories
work without organization creation, migration or organization registration.

**Open:** Configuration format, worker-count defaults, credential mechanism and
selected repository permissions. Account discovery cannot automatically enroll
repositories outside the configured eligibility list.
See [GitHub runner scopes](https://docs.github.com/en/actions/concepts/runners/self-hosted-runners).

## B02 - Complete safe, repeatable Linux Mint bootstrap

**Priority:** P0. **Dependencies:** none; configuration integrates with B01.

**Evidence:** `setup.sh:10-32,34-82` still prompts on reruns;
`rootless-docker/setup.sh:70-98` requires Docker CLI and matching rootless
tooling, with conditional package installation.

**Deliverable:** Make root `setup.sh` contain or orchestrate all prerequisites,
validated configuration and installation steps. Declare supported Mint/Ubuntu
base, architecture, Docker package source, Compose/rootless requirements and
cgroup constraints. Preserve the existing rootful daemon and deployment data.
Separate first-run prompts from noninteractive reruns. Declare host-changing
operations and provide clear prerequisite failures.

**Acceptance:** Authorized fresh-host setup prepares the chosen supported
platform; repeat setup reuses valid configuration without duplicate accounts,
services or data loss. Missing/incompatible tooling and account/home conflicts
produce actionable errors. Credentials stay outside checkout, images, job
containers and output. Required daemon restarts are explicit and coordinated
with live jobs/applications rather than unexpectedly disrupting them.

**Open:** Supported Mint base/architecture, Docker installation/update policy,
configuration schema and noninteractive input interface.

## B03 - Make concurrent worker lifecycle recoverable

**Priority:** P0. **Dependencies:** none.

**Evidence:** `build-runner/run-once.sh:44-65,87-99` adds shared socket state but
uses second-based names; `build-runner/runner-entrypoint.sh:32` uses `--replace`.
`runner-pool.sh:125-157` lacks a shared start/stop lock and partial-pool repair.

**Deliverable:** Use collision-resistant worker/runner/container identities,
serialize pool transitions, repair missing enabled workers and handle
signals/cleanup deterministically. Implement the eight-hour continuous idle
deadline with race-safe job-start detection: expire waiting runners, never busy
ones. Persist enabled/expired state so cleanup, retries and supervision do not
undo expiry. Define token/registration failures, stale state and socket recovery.
Restore original socket permissions when the final active consumer exits while
preserving the private host runtime-directory invariant.

**Acceptance:** Parallel launches do not replace each other or restore socket
permissions prematurely. Concurrent start cannot duplicate capacity; partial
failure recovers. Stop/drain has defined active-job behavior and verifies worker
and runner-container exit without stopping deployed applications. A waiting
worker expires after eight continuous idle hours and remains stopped until
manual revival; a job beginning near the deadline is not interrupted. A job
lasting over eight hours completes normally and its replacement starts a fresh
idle period. Expiry removes the idle registration/container and does not stop
application containers. Failed registration, forced termination and daemon/socket
replacement have safe, documented recovery.

**Open:** Explicit operator stop/drain semantics, shutdown bounds, stale GitHub
registration reconciliation and retry/backoff policy. Idle expiry is fixed at
eight hours; ordinary failure recovery must not reset an existing idle deadline.

## B04 - Integrate headless boot-persistent supervision

**Priority:** P0. **Dependencies:** B01, B02, B03.

**Evidence:** `setup.sh:134-138` only prints a manual start command;
`runner-pool.sh:7,83-146` fixes capacity and opens an interactive dashboard.

**Deliverable:** Integrate systemd-managed supervision with setup. Keep one
orchestration worker registered here continuously available, replacing its
ephemeral runner after each job or failure. Manage configured per-repository
build workers and one centrally registered deployment worker only while
explicitly enabled by B11. Separate supervision from optional interactive
viewing. Establish daemon/network ordering, fresh-token cycling, backoff,
status/logs and persisted idle-expiry state. Keep the long-lived PAT host-only.

**Acceptance:** Setup/reboot makes orchestration available without a login or
manual bootstrap. It can accept revival when every workload worker has expired.
Expired or never-enabled workload workers stay stopped across reboot/setup;
previously enabled workers respect their persisted idle budget on recovery.
Fresh tokens are requested for every ephemeral launch. Duplicate setup/start
does not duplicate capacity; B03 expiry is not undone by service restart policy.
Stop/drain follows B03 semantics. Outages do not cause tight loops or leaks.

**Open:** Service layout, resource budget, active-job recovery across reboot,
configuration-change/drain policy and dashboard retention.

## B11 - Add on-demand queue discovery and constrained host launches

**Priority:** P0. **Dependencies:** B01, B03, B04.

**Evidence:** The existing workflows have no orchestration role or pool revival
operation. Root-only launchers cannot safely be invoked from an ordinary runner
container merely by mounting the Docker socket.

**Deliverable:** Add the `runner_dispatch` workflow in this repository, triggered
by `workflow_dispatch` on the dedicated orchestration label. Invoke an
authenticated, constrained host operation to query account repository/workflow
metadata, intersect candidates with the installed eligibility list, and inspect
queued jobs. Include active workflow runs containing queued downstream jobs;
do not rely only on queued workflow-run status. Handle pagination, rate limits
and per-repository API failures without exposing secrets.

Match runnable queued jobs against all required runner labels and exclude
completed/cancelled, approval/dependency-blocked and unsupported jobs. Reuse
existing capacity and launch only missing repository-scoped workers within
configured limits. Reconcile state/recheck demand before launch to reduce
duplicates and stale launches. Also inspect this repository's central deployment
jobs and start at most its one deployment worker when needed. Do not expose the
host PAT, arbitrary root execution or unrestricted host mounts. Host-installed
configuration remains authoritative; API discovery or workflow inputs cannot
authorize additional repositories.

**Acceptance:** Manual dispatch works after workload expiry. An eligible
repository with matching queued work gets needed capacity; an ineligible
repository with work and an eligible repository with no work get no new runner.
Jobs queued in active workflows and later API pages are found. Blocked jobs and
unsupported labels do not launch runners. Existing workers count against limits;
concurrent dispatches converge without duplication or interrupting busy jobs.
Central deployment demand yields at most one deployment worker. A scan with no
matching demand is a successful no-op. API errors are reported, not interpreted
as permission to launch. Output summarizes demand, launches/reuse/skips and
failures. The workflow exits while host supervision keeps launched workers
running independently. No periodic polling or automatic job-driven scan is
installed.

**Open:** Minimal host-control transport/authentication and configuration
installation/update mechanism and API retry policy. A scan need not extend an
already healthy worker's idle deadline. There is no background or post-job scan
of other repositories; new demand without matching live capacity needs another
manual dispatch.

## B05 - Build and maintain the latest stable runner safely

**Priority:** P1. **Dependencies:** B02, B03; integrate scheduling with B04.

**Evidence:** `build-runner/Dockerfile:4` pins the version; the entrypoint
(`build-runner/runner-entrypoint.sh:11-20`) only warns about a newer release.
The rebuild workflow requires a working self-hosted runner.

**Deliverable:** Resolve the latest stable release at setup/update time, verify
the selected distribution and pass an explicit version to the build. Rebuild
both images, validate before promotion, and retain disabled per-job self-updates.
Provide a maintenance path independent of a healthy runner and define failed
release lookup/build behavior.

**Acceptance:** Authorized setup builds the resolved stable release in both
images and records it. New launches use validated replacement images; active
jobs remain intact. Lookup/build failure is visible and does not silently
replace a working image with an invalid one. Repeat builds/updates are
deterministic for the resolved version and support a documented fallback.

**Open:** Scheduled versus operator-triggered updates, integrity verification,
offline/failure policy, image promotion and fallback retention.

## B06 - Define reusable merge-result and master CI

**Priority:** P1. **Dependencies:** B01, B04, B11.

**Evidence:** `.github/workflows/build.yml:3-39` is push/manual smoke testing,
not application CI or a reusable workflow.

**Deliverable:** Define versioned reusable workflows that participating
repositories reference, with Dockerfile/context, test commands, naming/version
inputs and explicit outputs. Test the proposed PR merged with its base before
merge; build/test `master` again after merge. Gate release output on successful
checks and distinguish untrusted PR work from trusted release/deployment code.
Build jobs run on caller-repository runners, not on orchestration or the central
deployment worker. Document that expired workers require manual revival.

**Acceptance:** A representative caller repository uses the shared workflow
without duplicating its core logic. PR checks exercise the merge result;
post-merge master checks exercise the resulting commit. Failed checks cannot
release/deploy an image. Outputs identify the repository-defined image/version
and source revision. Required permissions and secrets are explicit. A queued
build after expiry resumes when B11 discovers its eligible queued work and
launches that repository's workers.

**Open:** Workflow hosting/versioning, test interface, naming/version schema,
fork/approval policy, branch variation and optional merge-queue `merge_group`
support. No merge queue requirement is assumed.

## B07 - Define image handoff and retention

**Priority:** P1. **Dependencies:** B06.

**Evidence:** Current images are local to the rootless daemon. Registry
publishing is not implemented (`README.md:3`, opening scope statement).

**Deliverable:** Choose a local-daemon or registry-backed handoff and define
immutable release identity, outputs consumed by deployment, credentials if
needed, collision avoidance and retention. Keep application images distinct
from local runner images and build cache.

**Acceptance:** A successful master build hands deployment an unambiguous image
name/version and immutable identity where supported by the chosen transport.
Deployment resolves that exact release. Missing artifacts, conflicting
identities and authorization failures are reported; cleanup preserves active
and rollback-required releases.

**Open:** Local versus registry images, registry/provider if chosen,
tag/digest contract, publication permission and retention depth.

## B08 - Implement centrally executed Compose deployment

**Priority:** P1. **Dependencies:** B04, B06, B07, B11.

**Evidence:** `deployment-runner/` provides tooling and a persistent mount.
`README.md` provides a sample; there is no shipped deployment workflow.

**Deliverable:** Define a validated per-repository deployment settings contract
and deployment workflow executed in this repository on its single
`docker-deploy` worker. Establish an explicitly authorized cross-repository
release-submission trigger; verify the allowed source repository, successful
master build and exact image identity against central configuration. A reusable
workflow called from an application repository alone cannot provide central
execution. Serialize all deployment jobs globally. Identify the configured
project/service, safely update its image reference, and reconcile with
`docker compose up -d` to recreate the affected service. A plain Compose
restart does not apply a changed image. Preserve unrelated services and data;
define health/failure/rollback handling within the globally serialized workflow.

**Acceptance:** Participating repositories submit release information without
requiring a deployment runner registered to each source repository. Exactly one
deployment job runs globally; concurrent requests serialize. An expired deploy
worker leaves requests queued until manual dispatch discovers deployment demand.
Unauthorized or unverified
release submissions cannot update applications. A tested master release updates
only its intended Compose project/service to the exact B07 image. Persistent
files and daemon-visible bind mounts live under the deployment directory, not
the ephemeral checkout.
Repeated deployment converges; stale/concurrent runs cannot overwrite a newer
release silently. Failed rollout has an observable result and an explicit
rollback/recovery path. Secrets do not enter source, image layers or logs.

**Open:** Release-submission API/event and narrowly scoped credentials, settings
schema, Compose image substitution/editing technique, automatic submission versus
approved release submission, health criteria, rollback, secret storage,
application ports/networking and multi-service policy. Discovery remains
manually triggered regardless of how release requests are submitted.

## B09 - Bound resources and add operational visibility

**Priority:** P2. **Dependencies:** B03, B04; release cleanup also depends on B07-B08.

**Evidence:** Build and deployment runners share Docker control; current pool
state/log files are not monitoring or resource isolation.

**Deliverable:** Reserve application capacity; bound build resources, logs,
cache and disk growth. Define cleanup that preserves live containers, deployment
volumes and rollback images. Add runner/daemon/deployment health visibility,
credential expiry guidance and recovery runbooks.

**Acceptance:** Selected workload limits preserve application availability
under expected build load. Storage/log retention is bounded without removing
live data. Operators can distinguish idle, busy, retrying and unhealthy
workers, receive useful failure signals, and recover from documented outages.

**Open:** Budgets, alert destination, trusted repository policy, retention
thresholds and acceptable contention on the shared daemon.

## B10 - Add focused checks and authorized host acceptance

**Priority:** P2. **Dependencies:** none for adding checks; full host acceptance
depends on the applicable B01-B09 and B11 implementation.

**Evidence:** No automated test suite/lint configuration was found among
tracked files. Server behavior has not been verified for this assessment.

**Deliverable:** Add focused shell/lifecycle/workflow checks alongside changed
behavior. Document an explicitly authorized Mint-host acceptance procedure,
labeling commands run as root versus `filius-runner` and identifying changes to
packages, accounts, services, jobs and applications.

**Acceptance:** Checks cover repeat setup, target/credential rejection, parallel
launch, fresh-token cycling, cancellation and restart recovery. Host acceptance
demonstrates orchestration boot/recovery, manual queue discovery, eligibility
filtering, label matching, pagination, queued jobs in active workflows, no-demand
no-op and capacity accounting alongside per-repository routing,
eight-hour continuous idle expiry, no cancellation of busy jobs, persistence of
expiry across restart/setup, and duplicate-dispatch safety. Include central
deployment routing/global serialization, PR merge-result/master CI, runner
update, exact-image deployment and agreed rollback behavior. Record what was
actually verified; do not substitute syntax checks for host lifecycle evidence.

**Open:** Test harness and dedicated test-host availability. No commands should
be executed merely because they appear in the runbook.
