# AI agent in GitHub Actions inside a Docker Sandbox

A small demo of the pattern from Docker's post [Running AI agents in GitHub Actions with Docker Sandboxes](https://www.docker.com/blog/running-ai-agents-in-github-actions-with-docker-sandboxes/). A CI coding agent gets broad freedom (any shell command, its own Docker daemon) **inside** a disposable Docker Sandbox (`sbx`) microVM, and a very narrow surface **outside** it.

The workflow is built from two small composite actions in this repo. It does not use GitHub Agentic Workflows (gh-aw): gh-aw removed its `docker-sbx` runtime in v0.90, so this demo drives `sbx` directly.

```
GitHub Actions runner (ubuntu-24.04)
├── agent job (contents: read)
│   └── Docker Sandbox microVM (own kernel, filesystem, network)
│       ├── Copilot agent, working in a git clone
│       └── private Docker daemon
│           ├── Maven / Java 21 test container
│           └── PostgreSQL (Testcontainers)
└── publish job (contents: write, no agent, no sandbox)
    └── validates the patch, then opens a DRAFT pull request
```

Flow: `sandbox-explorer.yml` → `sbx-agent` action (install sbx, start the sandbox, run the agent, extract a patch) → artifact → `publish-patch` action (validate, branch, draft PR).

## Inside vs outside the boundary

| Inside the sandbox | Outside the sandbox |
| :-- | :-- |
| any shell command the agent runs | network policy enforced by sbx's host-side proxy (and your Docker organization's rules, if governed) |
| its own private Docker daemon | the agent job's token is `contents: read` |
| edits to its own git clone | the Copilot token is held by sbx's proxy, so the sandbox only sees a placeholder |
| | changes leave only as a text patch, checked by `validate-patch.sh` |
| | a separate job opens the PR: **draft only**, `src/**` only, human review required |

The prompt's guardrails (don't touch `pom.xml`, workflows, scripts, docs) are advisory. The **enforced** boundaries are the sandbox, the network policy, the read-only token, and the patch validator, which rejects any path outside `src/`, anything under `.github/` or `.git/`, binaries, renames, symlinks, submodules and mode changes.

## The seeded task

`REQUIREMENTS.md` says email addresses are case-insensitive. The code does not do that: `RegistrationService.register` inserts the email as given, and the `users.email` column is a plain `TEXT ... UNIQUE`, which is case-sensitive in PostgreSQL. So `Alice@example.com` and `alice@example.com` both register.

The existing tests only check the exact-duplicate case, so they pass. The agent is expected to find the gap, add a case-variation regression test, and apply the smallest fix.

> **Do not fix this on `main`.** The bug is the point of the demo.

## Run the tests locally

Docker is the only prerequisite.

```bash
./scripts/test-in-docker.sh
# a single test:
./scripts/test-in-docker.sh -Dtest=RegistrationServiceIT#rejectsExactDuplicate
```

The script runs Maven in a digest-pinned container and mounts the Docker socket so Testcontainers can start PostgreSQL as a sibling container on the local daemon.

## Run the workflow

1. **Secrets** (repo settings, or `gh secret set <NAME>`):
   - `DOCKER_USERNAME` and `DOCKER_PAT`: a Docker Hub account and a personal access token with at least **Read** scope. sbx needs these to start.
   - `COPILOT_GITHUB_TOKEN`: a fine-grained PAT owned by a personal account with the **Copilot Requests** permission and **nothing else**. The account needs a Copilot entitlement. Classic `ghp_` tokens don't work with Copilot CLI.
2. Enable **Settings → Actions → General → Allow GitHub Actions to create and approve pull requests**.
3. Run it: `gh workflow run sandbox-explorer.yml`, then `gh run watch`.

## Expected result

- [ ] sbx installs and the sandbox starts
- [ ] environment evidence (`uname`, `docker version`, `docker info`, Alpine run) appears in the agent log
- [ ] baseline passes
- [ ] the new case-variation test fails
- [ ] the full suite passes after the fix
- [ ] the `publish` job opens a draft PR that touches only `src/**`
- [ ] the sandbox is removed

The `sbx diagnostics` group at the end of the agent step prints `sbx ls`, `sbx policy ls` and `sbx policy log`. Check it first when something is blocked.

## Governed Docker accounts

If the Docker account behind `DOCKER_USERNAME` belongs to an organization with Docker Sandboxes governance:

- **Network:** only organization allow rules grant access. Local allow rules (the `network-preset` and `allowed-hosts` inputs) become inactive, but local deny rules still apply. The organization's policy must allow the destinations in `sandbox-explorer.yml`'s `allowed-hosts` list, or the agent's `docker pull`, Maven and Copilot calls fail. An org policy that allows everything works but doesn't enforce an allowlist. Policies can be scoped to teams, so a CI-only team can have its own.
- **Filesystem:** organization rules control which host paths a sandbox may mount as a workspace. This action mounts only the checked-out repository (clone mode), which lives under the runner's home directory, so a rule like `~/**` should be enough. Unlike the old gh-aw setup, the action itself asks for no `/tmp` or `/usr/local/bin` mounts. That follows the docs and is unconfirmed until the first run, so check the log if a mount is denied.
- A denied mount shows up as `403 Forbidden: mount policy denied` in the log. List the active rules with `sbx policy ls --wide`.

## Runner requirements

- KVM (`/dev/kvm`), passwordless sudo, Docker Engine, and an Ubuntu distro (sbx supports Ubuntu 24.04 or later).
- Nested virtualization on GitHub-hosted runners is not officially guaranteed. Run the **KVM probe** workflow (`.github/workflows/kvm-probe.yml`) first to check.
- Self-hosted: use Ubuntu 24.04 with KVM enabled and change `runs-on` in `sandbox-explorer.yml`.
- sbx is installed by the action. Pin a version with the action's `sbx-version` input (an apt package version), because sbx releases often.

## Known limitations

- **Not yet run end to end.** The pieces were tested separately: `sbx exec` running Copilot with a PAT-backed `github` secret worked on a laptop, and the patch validator and publisher were tested against a local repository. The action as a whole has not been run on a GitHub runner.
- **Approval prompts.** Under sbx's `balanced` and `deny-all` presets, a request that matches no rule asks for human approval, which can't happen in CI. Keep the allowlist complete. If a run stalls, read `sbx policy log` in the diagnostics.
- **sbx is pre-1.0 and changes quickly.** Behavior here follows the docs for v0.47.

## Try sbx locally

```bash
sbx login
cd path/to/this/repo
sbx run copilot   # or claude / codex / opencode, then give it the same task
```

See the [Docker Sandboxes docs](https://docs.docker.com/ai/sandboxes/) and the [CI page](https://docs.docker.com/ai/sandboxes/workflows/automation/).

## Resetting the demo

Close the draft PR and delete its branch, for example `gh pr close <number> --delete-branch`. `main` is unchanged, so the workflow can be run again.

## Credits

- Blog post: [Running AI agents in GitHub Actions with Docker Sandboxes](https://www.docker.com/blog/running-ai-agents-in-github-actions-with-docker-sandboxes/) by Oleg Šelajev
- Original gh-aw implementation: [shelajev/docker-sandbox-gh-aw-demo](https://github.com/shelajev/docker-sandbox-gh-aw-demo)
