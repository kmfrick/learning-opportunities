#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
HOOK="$SCRIPT_DIR/post-tool-use.sh"
TEST_TMP=$(mktemp -d)
readonly LARGE_RESPONSE_BYTES=500000
readonly MAX_HOOK_SECONDS=3
trap 'rm -rf "$TEST_TMP"' EXIT

run_hook() {
  local payload="$1"

  TMPDIR="$TEST_TMP" bash "$HOOK" <<<"$payload"
}

assert_triggers() {
  local name="$1"
  local payload="$2"
  local output
  local status

  set +e
  output=$(run_hook "$payload")
  status=$?
  set -e

  if (( status != 0 )); then
    printf 'FAIL: %s hook exited with status %s\n' "$name" "$status" >&2
    exit 1
  fi
  if [[ "$output" != *hookSpecificOutput* ]]; then
    printf 'FAIL: %s should trigger\n' "$name" >&2
    exit 1
  fi
}

assert_ignores() {
  local name="$1"
  local payload="$2"
  local max_seconds="${3:-0}"
  local output
  local status
  local started_at=$SECONDS

  set +e
  output=$(run_hook "$payload")
  status=$?
  set -e

  if (( max_seconds && SECONDS - started_at > max_seconds )); then
    printf 'FAIL: %s took longer than %s seconds\n' "$name" "$max_seconds" >&2
    exit 1
  fi
  if (( status != 0 )); then
    printf 'FAIL: %s hook exited with status %s\n' "$name" "$status" >&2
    exit 1
  fi
  if [[ -n "$output" ]]; then
    printf 'FAIL: %s should be ignored, got: %s\n' "$name" "$output" >&2
    exit 1
  fi
}

assert_triggers \
  "basic git commit" \
  '{"session_id":"trigger-basic","tool_input":{"cmd":"git commit -m test"},"tool_response":{}}'

assert_triggers \
  "git commit after cd" \
  '{"session_id":"trigger-after-cd","tool_input":{"cmd":"cd repo && git commit -m test"},"tool_response":{}}'

assert_triggers \
  "git commit after escaped newline" \
  '{"session_id":"trigger-after-escaped-newline","tool_input":{"cmd":"git add .\ngit commit -m test"},"tool_response":{}}'

assert_triggers \
  "git commit with global option" \
  '{"session_id":"trigger-global-option","tool_input":{"cmd":"git -C repo commit --amend"},"tool_response":{}}'

assert_triggers \
  "git commit with quoted global option value" \
  '{"session_id":"trigger-quoted-global-option","tool_input":{"cmd":"git -C \"$repo\" commit -m test"},"tool_response":{}}'

assert_triggers \
  "dry-run as commit message" \
  '{"session_id":"trigger-dry-run-message","tool_input":{"cmd":"git commit -m --dry-run"},"tool_response":{}}'

assert_triggers \
  "help as combined short option value" \
  '{"session_id":"trigger-help-message","tool_input":{"cmd":"git commit -am --help"},"tool_response":{}}'

assert_triggers \
  "claude command field" \
  '{"session_id":"trigger-command-field","tool_input":{"command":"git commit -m test"},"tool_response":{}}'

assert_triggers \
  "pretty JSON session id" \
  $'{\n  "session_id" : "trigger-pretty-json",\n  "tool_input" : { "cmd" : "git commit -m test" },\n  "tool_response" : {}\n}'

assert_ignores \
  "output mentions git commit" \
  '{"session_id":"ignore-output","tool_input":{"cmd":"rg -n commit ."},"tool_response":{"stdout":"docs mention git commit here"}}'

assert_ignores \
  "nested response tool input after top-level tool input" \
  '{"session_id":"ignore-nested-tool-input-after","tool_input":{"command":"git status --short"},"tool_response":{"tool_input":{"command":"git commit -m bogus"}}}'

assert_ignores \
  "searching for git commit" \
  '{"session_id":"ignore-search","tool_input":{"cmd":"rg -n \"git commit\" ."},"tool_response":{}}'

assert_ignores \
  "echoing git commit" \
  '{"session_id":"ignore-echo","tool_input":{"cmd":"echo git commit"},"tool_response":{}}'

assert_ignores \
  "quoted separator and git commit" \
  '{"session_id":"ignore-quoted-separator","tool_input":{"cmd":"echo \"; git commit\""},"tool_response":{}}'

assert_ignores \
  "git status with commit in output" \
  '{"session_id":"ignore-status","tool_input":{"cmd":"git status --short"},"tool_response":{"stdout":"nothing to commit, working tree clean"}}'

assert_ignores \
  "git log grep commit" \
  '{"session_id":"ignore-log-grep","tool_input":{"cmd":"git log --grep commit"},"tool_response":{}}'

assert_ignores \
  "git commit help" \
  '{"session_id":"ignore-commit-help","tool_input":{"cmd":"git commit --help"},"tool_response":{}}'

assert_ignores \
  "git commit dry run" \
  '{"session_id":"ignore-commit-dry-run","tool_input":{"cmd":"git commit --dry-run"},"tool_response":{}}'

assert_ignores \
  "git commit dry run after message" \
  '{"session_id":"ignore-commit-dry-run-after-message","tool_input":{"cmd":"git commit -m test --dry-run"},"tool_response":{}}'

assert_ignores \
  "git commit dry run after attached message" \
  '{"session_id":"ignore-commit-dry-run-after-attached-message","tool_input":{"cmd":"git commit -mtest --dry-run"},"tool_response":{}}'

assert_ignores \
  "response command before tool input" \
  '{"session_id":"ignore-response-command-first","tool_response":{"command":"git commit -m bogus"},"tool_input":{"command":"git status --short"}}'

assert_ignores \
  "nested command without tool input" \
  '{"session_id":"ignore-nested-command-without-tool-input","tool_response":{"command":"git commit -m bogus"}}'

assert_ignores \
  "nested tool input before top-level tool input" \
  '{"session_id":"ignore-nested-tool-input-first","tool_response":{"tool_input":{"command":"git commit -m bogus"}},"tool_input":{"command":"git status --short"}}'

large_response=$(awk -v size="$LARGE_RESPONSE_BYTES" 'BEGIN { printf "%*s", size, "" }')
assert_ignores \
  "large response before tool input" \
  '{"session_id":"ignore-large-response","tool_response":{"stdout":"'"$large_response"'"},"tool_input":{"command":"git status --short"}}' \
  "$MAX_HOOK_SECONDS"

assert_ignores \
  "large shell command" \
  '{"session_id":"ignore-large-command","tool_input":{"command":"git status '"$large_response"'"},"tool_response":{}}' \
  "$MAX_HOOK_SECONDS"

printf 'post-tool-use hook tests passed\n'
