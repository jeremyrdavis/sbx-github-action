#!/usr/bin/env bash
# Validates an agent-produced patch before it is applied. This is the enforced
# boundary for what the agent may change: the patch is untrusted text.
#
# Usage: validate-patch.sh <patch-file> <allowed-prefixes> [max-bytes]
#   allowed-prefixes  space-separated path prefixes, for example "src/"
#
# Prints the validated file paths, one per line. Exits non-zero on any violation.
set -euo pipefail

patch="${1:?usage: validate-patch.sh <patch-file> <allowed-prefixes> [max-bytes]}"
allowed="${2:?usage: validate-patch.sh <patch-file> <allowed-prefixes> [max-bytes]}"
max_bytes="${3:-1048576}"

fail() {
  echo "::error::Patch rejected: $*" >&2
  exit 1
}

[[ -f "${patch}" ]] || fail "patch file not found"
size="$(wc -c < "${patch}")"
[[ "${size}" -gt 0 ]] || fail "patch is empty"
[[ "${size}" -le "${max_bytes}" ]] || fail "patch is ${size} bytes, over the ${max_bytes} byte limit"

# Only plain text edits to regular files: no binaries, renames, copies, or mode changes.
if grep -qE '^(GIT binary patch|Binary files )' "${patch}"; then
  fail "binary changes are not allowed"
fi
if grep -qE '^(rename|copy) (from|to) |^similarity index |^dissimilarity index |^old mode |^new mode ' "${patch}"; then
  fail "renames, copies and mode changes are not allowed"
fi
if grep -E '^(new|deleted) file mode ' "${patch}" | grep -qvE ' 100644$'; then
  fail "only regular, non-executable files may be added or deleted (no symlinks)"
fi
# Editing an existing entry shows its mode only on the index line. Anything other
# than a regular file (symlink 120000, submodule 160000) is refused.
if grep -E '^index [0-9a-f]+\.\.[0-9a-f]+ [0-9]+$' "${patch}" | grep -qvE ' 100644$'; then
  fail "only regular files may be edited (no symlinks or submodules)"
fi

# Each header must name the same path on both sides.
while IFS=$'\t' read -r old new; do
  [[ "${old}" == "${new}" ]] || fail "path mismatch in diff header: ${old} vs ${new}"
done < <(sed -nE 's#^diff --git a/(.*) b/(.*)$#\1\t\2#p' "${patch}")

# Every touched path must be a plain relative path under an allowed prefix.
count=0
while IFS= read -r -d '' record; do
  path="${record#*$'\t'}"
  path="${path#*$'\t'}"
  [[ "${path}" =~ ^[A-Za-z0-9_./-]+$ ]] || fail "unsupported characters in path: ${path}"
  [[ "${path}" != /* ]] || fail "absolute path: ${path}"
  [[ "/${path}/" != *"/../"* && "/${path}/" != *"/./"* && "${path}" != *"//"* ]] \
    || fail "path is not normalized: ${path}"
  [[ "/${path}/" != *"/.git/"* && "/${path}/" != *"/.github/"* ]] \
    || fail "protected location: ${path}"
  ok=false
  for prefix in ${allowed}; do
    if [[ "${path}" == "${prefix}"* ]]; then
      ok=true
      break
    fi
  done
  [[ "${ok}" == "true" ]] || fail "${path} is outside the allowed paths (${allowed})"
  echo "${path}"
  count=$((count + 1))
done < <(git apply --numstat -z "${patch}")

[[ "${count}" -gt 0 ]] || fail "patch touches no files"
