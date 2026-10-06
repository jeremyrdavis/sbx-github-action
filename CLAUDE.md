# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A demo repo for Docker's "Running AI agents in GitHub Actions with Docker Sandboxes" pattern, built from two composite actions that drive `sbx` directly. A Copilot agent runs inside a Docker Sandbox microVM and runs Testcontainers-based Java tests against the sandbox's private Docker daemon. It finds a seeded bug, and a separate job opens a draft PR limited to `src/**`. `SPEC.md` is the original brief, written for gh-aw: gh-aw dropped its `docker-sbx` runtime (v0.90), so the gh-aw parts of the spec no longer apply. `README.md` is the user-facing doc and `DEMO.md` is the presenter script.

## Critical rule: the seeded bug must stay

The case-sensitive email uniqueness bug in `RegistrationService` is the point of the demo. **Do not fix it, and do not commit a case-variation test.** The agent in CI is meant to find both. Keep `register()` free of normalization and of hint comments, and keep the schema's plain `TEXT NOT NULL UNIQUE` (no `citext`, no `lower(email)` index). `RegistrationServiceIT` has exactly two tests (`registersNewEmail`, `rejectsExactDuplicate`).

To re-prove the bug or the one-line fix (`email.trim().toLowerCase(Locale.ROOT)` before insert), add the case test or the fix temporarily, run the suite, then `git checkout -- src` and confirm `src/` is clean.

## Commands

Docker is the only prerequisite; there is no local Maven or JDK requirement.

- All tests: `./scripts/test-in-docker.sh`
- One test: `./scripts/test-in-docker.sh -Dtest=RegistrationServiceIT#rejectsExactDuplicate` (arguments go to `mvn --batch-mode <args> test`)
- Lint (none of these tools are installed locally; run them in containers): `koalaman/shellcheck` on every `*.sh`, `rhysd/actionlint` on `.github/workflows`, and `yamllint` (relaxed, no line-length rule) on `.github`.

## Architecture

- `src/main/.../registration/`: `RegistrationService` (plain JDBC over a `DataSource`, creates the schema from `Schema.DDL` in its constructor, `register()` returns `false` on SQLState `23505`) and `Schema`.
- `src/test/.../RegistrationServiceIT.java`: Testcontainers PostgreSQL. Surefire includes `*Test` and `*IT`, so `mvn test` runs it.
- Testcontainers is 2.x: artifacts are `testcontainers-postgresql` and `testcontainers-junit-jupiter`, and the container class is the non-generic `org.testcontainers.postgresql.PostgreSQLContainer`. A digest-pinned image name needs `DockerImageName.parse(...).asCompatibleSubstituteFor("postgres")`.
- `scripts/test-in-docker.sh` runs Maven in a digest-pinned container with `/var/run/docker.sock` mounted. PostgreSQL starts as a sibling container, so the Maven container reaches it through `--add-host=host.testcontainers.internal:host-gateway` and `TESTCONTAINERS_HOST_OVERRIDE`. Inside a sandbox, that socket is the sandbox's private daemon.

## Workflow (`.github/`)

- `workflows/sandbox-explorer.yml`: manual trigger, `permissions: {}` at the top. Job `agent` (`contents: read`) uses `actions/sbx-agent`. Job `publish` (`contents: write`, `pull-requests: write`, runs no agent) uses `actions/publish-patch`. Third-party actions are pinned by commit SHA resolved with `git ls-remote`; never invent a SHA.
- `actions/sbx-agent`: `install-sbx.sh` (apt `docker-sbx`, KVM check) and `run-agent.sh`. The script starts the daemon, runs `sbx login` with the Docker PAT, applies the network preset, stores the Copilot PAT as the sbx `github` secret, runs `sbx create --clone`, runs `sbx exec <name> copilot --yolo -p <prompt>`, and extracts the changes as a base64 patch between random markers. Always use `sbx exec`, never `sbx run`: `sbx run` swallows the agent's output without a TTY.
- `actions/publish-patch`: `validate-patch.sh` treats the patch as untrusted (only plain text edits under `src/`; rejects binaries, renames, mode changes, symlinks, submodules, `.git/`, `.github/`, odd characters, and large patches). `publish-patch.sh` applies it on a new branch and opens a **draft** PR with `gh`.
- `prompts/sandbox-explorer.md`: the agent prompt. It tells the agent to leave changes uncommitted. The prompt guardrails are advisory; the enforced boundaries are the sandbox, the network policy, the read-only token, and the validator.
- `workflows/kvm-probe.yml`: a manual check that `/dev/kvm` is usable on the hosted runner.
- Secrets: `DOCKER_USERNAME`, `DOCKER_PAT` (Docker Hub, Read scope), and `COPILOT_GITHUB_TOKEN` (fine-grained PAT, Copilot Requests permission only). The secret name `COPILOT_GITHUB_TOKEN` is an assumption; it appears once, in the workflow.

## Testing the actions without sbx

The actions can't run end to end outside a KVM-capable runner. These parts were tested locally with throwaway repos and stubs, and should be tested the same way after changes:

- `validate-patch.sh`: build patches with `git diff --cached --no-renames --full-index` for good and hostile cases (other paths, `.github/`, symlink edits, mode changes, binaries, traversal, oversize). Editing a symlink only shows its mode on the `index` line, which the validator also checks.
- `publish-patch.sh`: run against a local bare remote with a stub `gh` on `PATH`.
- `run-agent.sh`: run with a stub `sbx` that clones the workspace and emulates `exec`, including noise on stdout and the failure and no-change paths.

## Conventions

- Container images are pinned by digest (Maven image in the script, `postgres:16.6-alpine` in the IT, `alpine:3.21` in the agent prompt). Resolve real digests with `docker buildx imagetools inspect`; never invent one. Dependency versions in `pom.xml` are pinned.
- Shell scripts need `set -euo pipefail` and LF endings (enforced by `.gitattributes`). With `pipefail`, avoid `cmd | grep -q`: capture the output first.
- sbx facts that are easy to get wrong: network presets are `allow-all`, `balanced` and `deny-all`. Unmatched requests ask for human approval, so a CI allowlist must be complete. Under Docker organization governance, only org allow rules grant access and local allow rules are inactive. Org filesystem rules govern workspace mounts only.
- Report only what was actually verified. A real Actions run needs the user's repo, secrets and a KVM-capable runner, so it can't be verified from here.
