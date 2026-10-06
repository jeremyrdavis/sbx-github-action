# Running the demo

A step-by-step script for running and presenting this demo. For background on the pattern, see [README.md](README.md).

**The story:** an AI agent in CI gets its own Docker daemon *inside* a disposable Docker Sandbox microVM, and almost no power *outside* it. It finds a seeded bug and fixes it. A separate job validates the patch and opens a draft PR that can only touch `src/**`.

Plan for about 15 minutes of setup the first time, plus the run itself. Do the setup before you present.

## 0. Before you start

You need:

- A GitHub account with **Copilot**, and a **fine-grained PAT** owned by that personal account with only the **Copilot Requests** permission (github.com/settings/personal-access-tokens)
- A **Docker Hub** account and an access token with at least **Read** scope (Docker Hub → Account settings → Personal access tokens). Use a token, not your password.
- Locally: `git`, `docker`, and `gh`
- Permission to create a repo, set Actions secrets, and change Actions settings

## 1. Check the app locally (optional, 2 minutes)

```bash
./scripts/test-in-docker.sh
```

You should see `Tests run: 2, Failures: 0` and `BUILD SUCCESS`. This proves the chain works: a Maven container, the Docker socket, Testcontainers, and PostgreSQL.

The bug is already in this code, and the tests pass anyway. The existing tests only check an exact duplicate (`bob@example.com` twice), never a case variant. [REQUIREMENTS.md](REQUIREMENTS.md) says emails are case-insensitive.

> **Do not fix the bug on `main`.** The agent is meant to find it.

## 2. Create the repo and push

```bash
gh repo create <name> --public --source=. --push
```

If you already have a remote, use `git remote add origin <url>` and `git push -u origin HEAD`.

## 3. Configure the repo (one time)

```bash
gh secret set DOCKER_USERNAME          # your Docker Hub username
gh secret set DOCKER_PAT               # your Docker Hub access token
gh secret set COPILOT_GITHUB_TOKEN     # the fine-grained PAT with Copilot Requests only
```

Then go to **Settings → Actions → General → Workflow permissions** and tick **Allow GitHub Actions to create and approve pull requests**. If the box is greyed out, an organization policy is blocking it. Ask an org admin, or use a personal repo.

**Governed Docker account?** See "Governed Docker accounts" in the README. The organization's network rules must allow the hosts in `sandbox-explorer.yml`.

## 4. Check the runner (recommended)

Docker Sandboxes run in a microVM, which needs `/dev/kvm`. Nested virtualization on GitHub-hosted runners is not officially guaranteed, so check first:

```bash
gh workflow run kvm-probe.yml
gh run watch
```

- **Green:** `/dev/kvm` is present and accessible. Continue.
- **Red:** the hosted runner has no KVM. Use a self-hosted Ubuntu 24.04 runner with KVM and change `runs-on` in `sandbox-explorer.yml`.

## 5. Run the agent

```bash
gh workflow run sandbox-explorer.yml
gh run watch
```

While it runs, here is what to point out. The log groups are named after these stages:

| Stage | What to look for in the log |
| :-- | :-- |
| **Install** | `docker-sbx` is installed by the action, then `sbx version` prints. |
| **Network policy** | The preset and the allowed hosts are applied (or ignored under organization governance). |
| **Create the sandbox** | `sbx create --clone` makes a microVM with the repo as a clone. The agent never touches the runner's checkout. |
| **Run the agent** | The agent prints `uname -a`, `docker version`, `docker info` and an Alpine run: the microVM's kernel and a private daemon, not the runner's. |
| **Baseline** | `./scripts/test-in-docker.sh` passes with 2 tests. |
| **Probe** | The agent adds a case-variation test and it **fails** (`expected: <false> but was: <true>`). |
| **Fix** | The agent makes a small change under `src/`, usually normalizing the email before insert. |
| **Full suite** | All tests pass, now 3. |
| **Extract the patch** | Only a text patch leaves the sandbox. |
| **sbx diagnostics** | `sbx policy ls` and `sbx policy log` show what the policy allowed and blocked. |
| **`publish` job** | A separate job validates the patch and opens the PR. |

> This table describes the intended flow from the prompt in `.github/prompts/sandbox-explorer.md`. The action has not yet been run on a GitHub runner, so exact log wording may differ. Update this file after the first run.

## 6. Review the result

```bash
gh pr list
gh pr view <number> --json isDraft,files,title --jq '{isDraft, title, files: [.files[].path]}'
```

Check that:

- [ ] The PR is a **draft**, with the title prefix `[docker-sbx sample]`
- [ ] Every changed file is under `src/` (the regression test and the fix)
- [ ] The description links the run and lists the changed files
- [ ] The existing tests are unchanged and none were skipped or deleted

The run's artifact `sbx-agent-output` holds the exact patch and the agent's log.

## 7. The talking points

- **Inside the boundary**, the agent can do anything the sandbox allows. It ran Testcontainers against a daemon that is not the runner's.
- **Outside the boundary**, it can do very little:
  - the network is governed by sbx's host-side proxy, and by your Docker organization if it has governance
  - the agent job's token is `contents: read`, so it can't push
  - the Copilot token lives in sbx's proxy, so the sandbox only sees a placeholder
  - changes leave only as a text patch, which `validate-patch.sh` checks
  - the PR comes from a separate job that accepts only `src/`, as a draft, for a human to review
- **The prompt guardrails are advisory** ("don't touch `pom.xml`"). The enforced limits are the sandbox, the network policy, the read-only token, and the patch validator. Show `.github/actions/publish-patch/validate-patch.sh`.

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
sbx secret set github -t "<fine-grained PAT with Copilot Requests>"
sbx create --clone --name try copilot .
sbx exec try copilot --yolo -p "$(cat .github/prompts/sandbox-explorer.md)"
sbx rm --force try
```

Use `sbx exec`, not `sbx run`: `sbx run` doesn't pass the agent's output through without a terminal. See the [Docker Sandboxes docs](https://docs.docker.com/ai/sandboxes/).

## Troubleshooting

| Symptom | Likely cause and fix |
| :-- | :-- |
| Install step fails: `/dev/kvm is missing` | The runner has no KVM. Run `kvm-probe.yml` and see step 4. |
| `sbx login` fails | `DOCKER_USERNAME` or `DOCKER_PAT` is wrong, or set in the wrong repo. Re-run `gh secret set`. |
| `The 'copilot-token' input is empty` (or another input) | The secret doesn't exist in this repository under the name the workflow uses. Check `gh secret list`. |
| Notice: "Network policy is managed by your Docker organization" | Expected with a governed account. The organization's rules decide network access, and the `allowed-hosts` input is not applied. |
| `403 Forbidden: mount policy denied` | Your Docker organization's filesystem policy doesn't allow the workspace path. A rule like `~/**` should cover it. Check `sbx policy ls --wide` for the account behind the secret. |
| Agent fails with `Authentication failed` | `COPILOT_GITHUB_TOKEN` is missing, expired, or lacks the **Copilot Requests** permission, or the account has no Copilot entitlement. Classic `ghp_` tokens are not supported. |
| Agent step stalls, or an image pull or Maven download fails | The network policy blocks a host. Read `sbx policy log` in the `sbx diagnostics` group, then add the host to `allowed-hosts` (or to your organization's policy). |
| The agent finishes but no PR appears | Either the agent made no changes (the `publish` job is skipped), or the patch was rejected: read the `Validate the patch` group in the `publish` job. If the push or PR step failed, check that "Allow GitHub Actions to create and approve pull requests" is on. |
| The baseline fails inside the sandbox | The prompt tells the agent to report infrastructure failures and stop. Image pulls and Maven Central are the usual suspects, so check the network policy. |

> **Not yet tested end to end:** the local tests, the bug, the patch validator and the publisher were verified, and `sbx exec` with Copilot worked on a laptop. A full Actions run needs your repo, secrets, and a KVM-capable runner. If the real log differs from step 5, update this file.
