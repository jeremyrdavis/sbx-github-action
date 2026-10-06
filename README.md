# AI agent in GitHub Actions inside a Docker Sandbox

A small demo of the pattern from Docker's post [Running AI agents in GitHub Actions with Docker Sandboxes](https://www.docker.com/blog/running-ai-agents-in-github-actions-with-docker-sandboxes/). A CI coding agent gets broad freedom (root, any shell command, its own Docker daemon) **inside** a disposable Docker Sandbox (`sbx`) microVM, and a very narrow surface **outside** it.

```
GitHub Actions runner (ubuntu-24.04)
└── Docker Sandbox microVM (own kernel, filesystem, network)
    ├── gh-aw agent (Copilot)
    └── private Docker daemon
        ├── Maven / Java 21 test container
        └── PostgreSQL (Testcontainers)
```

Source to runtime: Markdown workflow → `gh aw compile` → `.lock.yml` → hosted runner → sbx microVM → agent + tools.

## Inside vs outside the boundary

| Inside the sandbox | Outside the sandbox |
| :-- | :-- |
| root, arbitrary shell commands | network allowlist (`defaults`, `github`, `containers`, `java`) |
| its own private Docker daemon | `contents: read` token, so the agent cannot write to the repo |
| edits to the working tree | PR created by a separate safe-output job, **draft only**, files limited to `src/**` |
| | a human reviews the PR |

The guardrails in the agent prompt (don't touch `pom.xml`, workflows, scripts, docs) are advisory. The **enforced** boundaries are the sandbox, the network allowlist, the read-only token, and `allowed-files: src/**` on the safe output.

## The seeded task

`REQUIREMENTS.md` says email addresses are case-insensitive. The code does not do that: `RegistrationService.register` inserts the email as given, and the `users.email` column is a plain `TEXT ... UNIQUE`, which is case-sensitive in PostgreSQL. So `Alice@example.com` and `alice@example.com` both register.

The existing tests only check the exact-duplicate case, so they pass. The agent is expected to find the gap, add a case-variation regression test, apply the smallest fix, and open a draft PR.

> **Do not fix this on `main`.** The bug is the point of the demo.

## Run the tests locally

Docker is the only prerequisite.

```bash
./scripts/test-in-docker.sh
# a single test:
./scripts/test-in-docker.sh -Dtest=RegistrationServiceIT#rejectsExactDuplicate
```

The script runs Maven in a digest-pinned container and mounts the Docker socket so Testcontainers can start PostgreSQL as a sibling container on the local daemon.

## Run the agentic workflow

1. Install the extension: `gh extension install github/gh-aw`
2. Add the secrets `DOCKER_USERNAME` and `DOCKER_PAT` (needed to pull the sandbox template), in repo settings or with `gh secret set`.
3. Copilot access: either a Copilot entitlement plus `copilot-requests: write` (already set), or a `COPILOT_GITHUB_TOKEN` secret as described in the gh-aw docs.
4. Enable **Settings → Actions → General → Allow GitHub Actions to create and approve pull requests**.
5. Compile, then commit and push both files:
   ```bash
   gh aw compile sandbox-explorer
   git add .github/workflows/sandbox-explorer.md .github/workflows/sandbox-explorer.lock.yml
   git commit -m "Compile sandbox-explorer" && git push
   ```
   The `.lock.yml` is generated and is not checked in until you run this.
6. Run it: `gh aw run sandbox-explorer`, then `gh run watch`.

> **Note on gh-aw keys.** The spec lists `sandbox.agent: {id: awf, runtime: docker-sbx, sudo: true}`. In gh-aw v0.89.21 the schema has no `sudo` key (compiling with it fails with `Unknown property: sudo`), and the compiler sets up the privileged sandbox itself, so `sandbox-explorer.md` uses only `id` and `runtime`. `runtime: docker-sbx` is valid and, per the schema, needs the `DOCKER_PAT` and `DOCKER_USERNAME` secrets and a KVM-capable runner. The public agent-runtimes docs page lags behind and does not list `docker-sbx`.

## Expected result

- [ ] sbx preflight succeeds
- [ ] environment evidence (`uname`, `docker version`, `docker info`, Alpine run) appears in the logs
- [ ] baseline passes
- [ ] the new case-variation test fails
- [ ] the full suite passes after the fix
- [ ] a separate job opens a draft PR that touches only `src/**`
- [ ] the sandbox is cleaned up

The reference run took roughly 11 minutes.

## Runner requirements

- KVM (`/dev/kvm`), passwordless sudo, Docker Engine, an apt-based distro.
- Nested virtualization on GitHub-hosted runners is not officially guaranteed. Run the **KVM probe** workflow (`.github/workflows/kvm-probe.yml`) first to check.
- Self-hosted: use Ubuntu 24.04 with KVM enabled, change `runs-on` in `sandbox-explorer.md`, and recompile.
- Don't preinstall `sbx`. The compiled workflow installs it.

## Try sbx locally

```bash
sbx login
cd path/to/this/repo
sbx run claude   # or codex / opencode, then give it the same task
```

See the [Docker Sandboxes docs](https://docs.docker.com/ai/sandboxes/).

## Resetting the demo

Close the draft PR and delete its branch, for example `gh pr close <number> --delete-branch`. `main` is unchanged, so the workflow can be run again.

## Credits

- Blog post: [Running AI agents in GitHub Actions with Docker Sandboxes](https://www.docker.com/blog/running-ai-agents-in-github-actions-with-docker-sandboxes/) by Oleg Šelajev
- Reference implementation: [shelajev/docker-sandbox-gh-aw-demo](https://github.com/shelajev/docker-sandbox-gh-aw-demo)
