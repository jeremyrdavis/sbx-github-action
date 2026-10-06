---
name: "Docker Sandboxes sample: exploratory test"

on:
  workflow_dispatch:

runs-on: ubuntu-24.04

# The agent's token is read-only. Pull requests are created by a separate safe-output job.
permissions:
  contents: read
  copilot-requests: write

engine: copilot

network:
  allowed:
    - defaults
    - github
    - containers   # pull container images
    - java         # Maven Central

# ---- The integration this demo is about -------------------------------------
# Run the agent inside a Docker Sandbox (sbx) microVM, with its own private
# Docker daemon, instead of directly on the runner. The compiler adds the
# privileged setup (root in the sandbox, KVM access), so there is no `sudo` key.
sandbox:
  agent:
    id: awf
    runtime: docker-sbx
# ------------------------------------------------------------------------------

tools:
  edit:
  bash: [":*"]

safe-outputs:
  create-pull-request:
    title-prefix: "[docker-sbx sample] "
    draft: true
    protected-files: blocked
    allowed-files:
      - "src/**"
---

<!--
  After editing this file, recompile:  gh aw compile sandbox-explorer
  and commit the regenerated sandbox-explorer.lock.yml. Never hand-edit the lock file.
-->

# Exploratory tester

You are a bounded exploratory tester for a small Java user-registration service. Work through the steps below in order and keep a short log of each command and its result.

## 1. Record the environment

Before touching any code, run these and print the output so the workflow log shows where the work ran:

- `uname -a`
- `docker version`
- `docker info`
- `docker run --rm alpine:3.21@sha256:ce64758a109eb420d874a118f87920e625e12d3634e03b4a5573fd9f6e5d3507 uname -a`

## 2. Read the requirements and code

Read `REQUIREMENTS.md`, then the source under `src/main` and the existing tests under `src/test`.

## 3. Baseline

Run `./scripts/test-in-docker.sh` unchanged and report the result. If it fails for an infrastructure reason (Docker, networking, image pulls), report that and stop. Do not try to fix infrastructure.

## 4. Probe the invariant

Add a PostgreSQL Testcontainers test, in the same style as the existing integration test, that registers two addresses differing only in letter case (for example `Alice@example.com` then `alice@example.com`) and asserts the second registration is rejected.

## 5. Run the focused test

Run only that test, for example `./scripts/test-in-docker.sh -Dtest=RegistrationServiceIT#<your test name>`, and explain the behavior you observe.

## 6. Fix, if needed

If the implementation violates the invariant in `REQUIREMENTS.md`, make the smallest fix you can, under `src/` only.

## 7. Full suite

Run the complete suite again with `./scripts/test-in-docker.sh`.

## 8. Report

Create exactly one draft pull request containing the regression test and the fix. The description must list the commands you ran and their results.

## Guardrails

- Do not modify `pom.xml` or any dependency manifest, workflow files, scripts, documentation, or generated files.
- Do not weaken, skip, or delete existing tests.
- If the baseline fails for an infrastructure reason, report it and stop.
