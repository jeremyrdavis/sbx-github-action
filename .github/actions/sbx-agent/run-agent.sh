#!/usr/bin/env bash
# Runs the Copilot agent inside a Docker Sandbox (sbx) microVM and extracts its
# working-tree changes as a patch. The agent never gets a write token: it edits a
# clone inside the sandbox, and this script copies out only a text patch.
#
# Inputs (environment): DOCKER_USERNAME, DOCKER_PAT, COPILOT_TOKEN, PROMPT_FILE, and
# optionally OUT_DIR, NETWORK_PRESET, ALLOWED_HOSTS, AGENT_TIMEOUT_MINUTES.
# Outputs: $OUT_DIR/changes.patch, $OUT_DIR/agent.log, and `changed` and `output-dir`
# in $GITHUB_OUTPUT.
set -euo pipefail

# A secret that doesn't exist reaches this script as an empty string, so say which input.
missing=0
for pair in "docker-username:DOCKER_USERNAME" "docker-pat:DOCKER_PAT" "copilot-token:COPILOT_TOKEN" "prompt-file:PROMPT_FILE"; do
  input="${pair%%:*}"
  var="${pair##*:}"
  if [[ -z "${!var:-}" ]]; then
    echo "::error::The '${input}' input is empty. If it comes from a secret, check that the secret exists in this repository and that the name in the workflow matches."
    missing=1
  fi
done
[[ "${missing}" -eq 0 ]] || exit 1
OUT_DIR="${OUT_DIR:-${RUNNER_TEMP:-/tmp}/sbx-agent-out}"
NETWORK_PRESET="${NETWORK_PRESET:-balanced}"
ALLOWED_HOSTS="${ALLOWED_HOSTS:-}"
AGENT_TIMEOUT_MINUTES="${AGENT_TIMEOUT_MINUTES:-20}"
TEMPLATE_IMAGE="docker/sandbox-templates:copilot"
SANDBOX="ci-agent-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"

if [[ ! "${AGENT_TIMEOUT_MINUTES}" =~ ^[0-9]+$ ]]; then
  echo "::error::agent-timeout-minutes must be a whole number"
  exit 1
fi
case "${NETWORK_PRESET}" in
  allow-all | balanced | deny-all) ;;
  *)
    echo "::error::network-preset must be allow-all, balanced or deny-all"
    exit 1
    ;;
esac

cd "${GITHUB_WORKSPACE:?}"
[[ -f "${PROMPT_FILE}" ]] || { echo "::error::Prompt file not found: ${PROMPT_FILE}"; exit 1; }
mkdir -p "${OUT_DIR}"
BASE_SHA="$(git rev-parse HEAD)"

set_output() {
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "$1=$2" >> "${GITHUB_OUTPUT}"
  fi
}
set_output changed false
set_output output-dir "${OUT_DIR}"

cleanup() {
  set +e
  echo "::group::sbx diagnostics"
  sbx ls
  sbx policy ls
  sbx policy log
  echo "::endgroup::"
  sbx rm --force "${SANDBOX}" > /dev/null 2>&1
}
trap cleanup EXIT

echo "::group::Start the sbx daemon"
nohup sbx daemon start > "${OUT_DIR}/sbx-daemon.log" 2>&1 &
running=false
for _ in $(seq 1 30); do
  # Capture first: with pipefail, `grep -q` closing the pipe early can fail the pipeline.
  daemon_status="$(sbx daemon status 2> /dev/null || true)"
  if grep -q -i running <<< "${daemon_status}"; then
    running=true
    break
  fi
  sleep 1
done
if [[ "${running}" != "true" ]]; then
  echo "::error::sbx daemon did not start within 30 seconds"
  cat "${OUT_DIR}/sbx-daemon.log" >&2 || true
  exit 1
fi
echo "::endgroup::"

echo "::group::Authenticate with Docker Hub"
printf '%s' "${DOCKER_PAT}" | sbx login --username "${DOCKER_USERNAME}" --password-stdin
# Pre-pull the sandbox template with the runner's Docker, using a throwaway config dir.
(
  DOCKER_CONFIG="$(mktemp -d)"
  export DOCKER_CONFIG
  trap 'rm -rf "${DOCKER_CONFIG}"' EXIT
  printf '%s' "${DOCKER_PAT}" | docker login --username "${DOCKER_USERNAME}" --password-stdin
  docker pull "${TEMPLATE_IMAGE}"
) || echo "::warning::Could not pre-pull ${TEMPLATE_IMAGE}; sbx will pull it when the sandbox is created"
echo "::endgroup::"

echo "::group::Network policy"
# With organization governance, org rules decide what is reachable and local allow
# rules are inactive. Without it, the preset plus the allowed hosts apply.
sbx policy init "${NETWORK_PRESET}"
hosts="$(printf '%s' "${ALLOWED_HOSTS}" | tr -s ' \n,' ',' | sed -e 's/^,//' -e 's/,$//')"
if [[ -n "${hosts}" ]]; then
  sbx policy allow network "${hosts}"
fi
echo "::endgroup::"

echo "::group::Store the Copilot token as an sbx secret"
# The host-side proxy injects this into requests to GitHub and Copilot endpoints.
# The sandbox itself only ever sees a placeholder.
sbx secret set github -t "${COPILOT_TOKEN}"
echo "::endgroup::"

echo "::group::Create the sandbox"
# --clone: the agent edits a separate git clone inside the sandbox, never the runner's tree.
sbx create --clone --name "${SANDBOX}" copilot "${GITHUB_WORKSPACE}" <<< "y"
echo "::endgroup::"

echo "::group::Run the agent"
prompt="$(cat "${PROMPT_FILE}")"
set +e
timeout --signal=TERM --kill-after=30 "${AGENT_TIMEOUT_MINUTES}m" \
  sbx exec "${SANDBOX}" copilot --yolo -p "${prompt}" 2>&1 | tee "${OUT_DIR}/agent.log"
agent_rc="${PIPESTATUS[0]}"
set -e
echo "::endgroup::"
if [[ "${agent_rc}" -ne 0 ]]; then
  echo "::error::The agent exited with code ${agent_rc} (124 means it hit the ${AGENT_TIMEOUT_MINUTES} minute timeout)"
  exit "${agent_rc}"
fi

echo "::group::Extract the agent's changes as a patch"
# The patch is built inside the sandbox, so git never runs the clone's config or hooks
# on the runner. It travels as base64 between random markers, which keeps it intact
# even if sbx prints extra lines around the command output.
marker="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
read -r -d '' extract_script <<'EOF' || true
set -euo pipefail
base="$1"; marker="$2"
git -c core.hooksPath=/dev/null add -A -- .
echo "BEGIN-${marker}"
git -c core.hooksPath=/dev/null diff --cached --no-ext-diff --no-textconv --no-renames --full-index "${base}" -- | base64 -w0
echo
echo "END-${marker}"
EOF
sbx exec "${SANDBOX}" bash -c "${extract_script}" _ "${BASE_SHA}" "${marker}" > "${OUT_DIR}/extract.raw"
sed -n "/^BEGIN-${marker}\$/,/^END-${marker}\$/p" "${OUT_DIR}/extract.raw" \
  | sed -e '1d' -e '$d' | tr -d '\n' | base64 -d > "${OUT_DIR}/changes.patch"
rm -f "${OUT_DIR}/extract.raw"
grep -q . "${OUT_DIR}/changes.patch" || : > "${OUT_DIR}/changes.patch"
echo "::endgroup::"

if [[ -s "${OUT_DIR}/changes.patch" ]]; then
  echo "The agent changed $(git apply --numstat "${OUT_DIR}/changes.patch" | wc -l) file(s)."
  set_output changed true
else
  echo "The agent made no changes."
fi
