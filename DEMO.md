# Running the demo

A step-by-step script for running and presenting this demo. For background on the pattern, see [README.md](README.md).

**The story:** an AI agent in CI gets root and its own Docker daemon *inside* a disposable Docker Sandbox microVM, and almost no power *outside* it. It finds a seeded bug, fixes it, and a separate job opens a draft PR that can only touch `src/**`.

Plan for about 15 minutes: roughly 5 for setup the first time and about 11 for the agent run. Do the setup before you present.

## 0. Before you start

You need:

- A GitHub account with **Copilot** access
- A **Docker Hub** account, plus an access token (Docker Hub → Account settings → Personal access tokens). Use a token with minimal scope, not your password.
- Locally: `git`, `docker`, and `gh` with the gh-aw extension (`gh extension install github/gh-aw`)
- Permission to create a repo, to set Actions secrets, and to change Actions settings on it

## 1. Check the app locally (optional, 2 minutes)

```bash
./scripts/test-in-docker.sh
```

You should see `Tests run: 2, Failures: 0` and `BUILD SUCCESS`. This proves the chain works: a Maven container, the Docker socket, Testcontainers, and PostgreSQL.

The bug is already in this code, and the tests pass anyway. That is the setup for the demo: the existing tests only check an exact duplicate (`bob@example.com` twice), never a case variant. [REQUIREMENTS.md](REQUIREMENTS.md) says emails are case-insensitive.

> **Do not fix the bug on `main`.** The agent is meant to find it.

## 2. Create the repo and push

```bash
gh repo create <name> --public --source=. --push
```

If you already have a remote, use `git remote add origin <url>` and `git push -u origin HEAD`.

The generated `.github/workflows/sandbox-explorer.lock.yml` is already committed. If you change `sandbox-explorer.md`, recompile and commit both files:

```bash
gh aw compile sandbox-explorer
```

## 3. Configure the repo (one time)

**Secrets** (the sandbox template is pulled from Docker Hub):

```bash
gh secret set DOCKER_USERNAME          # paste your Docker Hub username
gh secret set DOCKER_PAT               # paste your Docker Hub access token
```

**Copilot access:** the workflow requests `copilot-requests: write`, which works with a Copilot entitlement. If your setup needs it, add a `COPILOT_GITHUB_TOKEN` secret instead (see the gh-aw docs).

**Allow the PR to be created:** go to **Settings → Actions → General → Workflow permissions** and tick **Allow GitHub Actions to create and approve pull requests**. If the box is greyed out, an organization policy is blocking it. Ask an org admin, or use a personal repo.

## 4. Check the runner (recommended)

Docker Sandboxes run in a microVM, which needs `/dev/kvm`. Nested virtualization on GitHub-hosted runners is not officially guaranteed, so check first:

```bash
gh workflow run kvm-probe.yml
gh run watch
```

- **Green:** `/dev/kvm` is present and accessible. Continue.
- **Red:** the hosted runner has no KVM. Use a self-hosted Ubuntu 24.04 runner with KVM, change `runs-on` in `sandbox-explorer.md`, and recompile. See "Runner requirements" in the README.

## 5. Run the agent

```bash
gh aw run sandbox-explorer
gh run watch
```

(`gh run list --workflow sandbox-explorer.lock.yml` shows the run if you want its link.)

The run takes roughly 11 minutes. While it runs, here is what to point out, in order:

| Stage | What to look for in the log |
| :-- | :-- |
| **Pre-checks** | The Docker Hub secrets check passes. If it fails, see Troubleshooting. |
| **Sandbox start** | `sbx` is installed by the compiled workflow and the microVM starts. You didn't install it. |
| **Environment evidence** | The agent prints `uname -a`, `docker version`, `docker info`, and an Alpine `uname -a`. This is the microVM's kernel and a private daemon, not the runner's. |
| **Baseline** | `./scripts/test-in-docker.sh` passes with 2 tests. |
| **Probe** | The agent adds a case-variation test and it **fails** (`expected: <false> but was: <true>`). |
| **Fix** | The agent makes a small change under `src/`, usually normalizing the email before insert. |
| **Full suite** | All tests pass, now 3. |
| **Safe output** | A separate job, not the agent, opens the PR. |

> The step names above describe what the prompt in `sandbox-explorer.md` asks for. Exact log wording depends on gh-aw, so use the table as a guide, not a script.

## 6. Review the result

```bash
gh pr list
gh pr view <number> --json isDraft,files,title --jq '{isDraft, title, files: [.files[].path]}'
```

Check that:

- [ ] The PR is a **draft**, with the title prefix `[docker-sbx sample]`
- [ ] Every changed file is under `src/**` (the regression test and the fix)
- [ ] The description lists the commands the agent ran and their results
- [ ] The existing tests are unchanged and none were skipped or deleted

## 7. The talking points

- **Inside the boundary**, the agent can do anything: root, any shell command, its own Docker daemon. It ran Testcontainers against a daemon that is not the runner's.
- **Outside the boundary**, it can do very little:
  - the network is limited to an allowlist (`defaults`, `github`, `containers`, `java`)
  - its token is `contents: read`, so it can't push
  - the PR comes from a separate job that accepts only `src/**`, as a draft, for a human to review
- **The prompt guardrails are advisory** ("don't touch `pom.xml`"). The enforced limits are the sandbox, the network allowlist, the read-only token, and `allowed-files: src/**`. You can show this in `sandbox-explorer.md`, in the frontmatter above the prompt.

## 8. Reset for the next run

```bash
gh pr close <number> --delete-branch
git pull
git grep -c 'toLowerCase' -- src/main || echo "bug still present on main"
```

Don't merge the PR if you want to run the demo again. `main` should still have the bug and only the two seeded tests.

## Optional: try it locally with sbx

Run the same task on your own machine, without GitHub Actions:

```bash
sbx login
cd path/to/this/repo
sbx run claude        # or codex / opencode
```

Give it the task from the prompt in `sandbox-explorer.md`. See the [Docker Sandboxes docs](https://docs.docker.com/ai/sandboxes/).

## Troubleshooting

| Symptom | Likely cause and fix |
| :-- | :-- |
| `gh aw compile` fails with `Unknown property` | The schema changed between gh-aw versions. Check `gh aw version`, then the schema at `github/gh-aw` for that tag. See the note in the README (`sudo` is rejected on v0.89.21). |
| Pre-check reports missing Docker Hub secrets | `DOCKER_USERNAME` or `DOCKER_PAT` isn't set, or is set in the wrong repo. Re-run `gh secret set`. |
| Sandbox fails to start, mentions `/dev/kvm` | The runner has no usable KVM. Run `kvm-probe.yml` and see step 4. |
| Agent step fails on authentication or quota | No Copilot entitlement for the repo owner, or the `COPILOT_GITHUB_TOKEN` secret is missing or expired. |
| The agent finishes but no PR appears | "Allow GitHub Actions to create and approve pull requests" is off (step 3), or an org policy blocks it. The log of the PR job says which. |
| The baseline fails in the agent's run | The prompt tells the agent to report infrastructure failures and stop, not fix them. Read the report in the log. Image pulls and Maven Central are the usual suspects. |

> **Not yet tested end to end:** the local tests, the bug, and the compile were verified. A full Actions run needs your repo, secrets, and a KVM-capable runner, so the log details in step 5 describe the intended flow. If the real log differs, update this file.
