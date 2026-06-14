#!/usr/bin/env bash
# shellcheck shell=bash
#
# roles.sh — the single source of truth for the write/read-only CLASSIFICATION of the
# 12 /auto roles:
#   (1) a capability class: write_capable | read_only
#   (2) a canonical tool-grant string MIRRORED into each agents/<role>.md `tools:`.
#
# This is how the user's write-access rule (critical-rules.md) is ENFORCED: a read-only
# role's subagent file grants NO Edit/Write/Bash, so it physically cannot modify files
# or run commands. (Subagents adopt their own `tools:` frontmatter when the
# session spawns auto:<role>; `role_allowed_tools` below is a legacy helper kept so the
# classification has one source of truth — it is no longer passed to any spawn.)
# An UNKNOWN role defaults to read_only (fail-safe).
#
# Write-capable (3 roles ONLY): implement-backend, implement-frontend, write-documentation.
# Read-only (9 roles): the consensus design solvers (solver-minimal / -structural / -delete),
#   the meta-judge, the review triplet (reviewer-requirements / -quality / -tests),
#   debug, and review-secrets-leaks.
#
# Tool grants (mirrored into agents/<role>.md):
#   writers   -> Read,Edit,Write,Bash,Grep,Glob
#   read-only -> Read,Grep,Glob   (no Edit/Write/Bash: cannot mutate the repo or run
#                commands; the orchestrator feeds reviewers the scoped diff)
#
set -euo pipefail

if [[ -z "${AUTO_CONSTANTS_SOURCED:-}" ]]; then
  # shellcheck source=constants.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/constants.sh"
fi

if [[ -n "${AUTO_ROLES_SOURCED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
readonly AUTO_ROLES_SOURCED=1

# --------------------------------------------------------------------------- #
# Tool-grant strings (mirrored into each agents/<role>.md `tools:`). Read-only roles get
# NO Bash at all — they cannot run commands; everything but Read/Grep/Glob is denied.
# --------------------------------------------------------------------------- #
readonly AUTO_TOOLS_WRITER="Read,Edit,Write,Bash,Grep,Glob"
readonly AUTO_TOOLS_READONLY="Read,Grep,Glob"

# The exhaustive set of write-capable roles (space-delimited; matched whole-word).
readonly AUTO_WRITE_ROLES="implement-backend implement-frontend write-documentation"

# --------------------------------------------------------------------------- #
# role_is_writer <role>
#   Exit 0 (true) if the role is write-capable; exit 1 (false) otherwise.
#   Unknown roles -> NOT a writer (read_only default; fail-safe).
# --------------------------------------------------------------------------- #
role_is_writer() {
  local role="${1:?role_is_writer: role required}"
  local w
  for w in $AUTO_WRITE_ROLES; do
    [[ "$role" == "$w" ]] && return 0
  done
  return 1
}

# --------------------------------------------------------------------------- #
# role_class <role>
#   Print "write_capable" or "read_only" on stdout. Always exits 0.
# --------------------------------------------------------------------------- #
role_class() {
  local role="${1:?role_class: role required}"
  if role_is_writer "$role"; then
    printf '%s\n' "write_capable"
  else
    printf '%s\n' "read_only"
  fi
}

# --------------------------------------------------------------------------- #
# role_allowed_tools <role>
#   Print the Claude --allowedTools string for the role on stdout. Always exits 0.
#   Unknown role -> read-only tool set (fail-safe; physically cannot write).
# --------------------------------------------------------------------------- #
role_allowed_tools() {
  local role="${1:?role_allowed_tools: role required}"
  if role_is_writer "$role"; then
    printf '%s\n' "$AUTO_TOOLS_WRITER"
  else
    printf '%s\n' "$AUTO_TOOLS_READONLY"
  fi
}
