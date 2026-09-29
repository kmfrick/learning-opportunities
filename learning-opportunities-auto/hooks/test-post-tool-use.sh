#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
HOOK="$SCRIPT_DIR/post-tool-use.sh"
TEST_TMP=$(mktemp -d)
readonly LARGE_RESPONSE_BYTES=500000
readonly MAX_HOOK_SECONDS=3
readonly MANY_JSON_STRINGS=40000
trap 'rm -rf "$TEST_TMP"' EXIT

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

REPO="$TEST_TMP/repo"
git init -q "$REPO"
git -C "$REPO" commit -q --allow-empty -m initial

# Each case runs the hook's pre phase, the command in $REPO, then the post
# phase, as Claude Code and Codex do. A staged change is always available, so
# only a real commit changes the reflog.
json_string() {
  python3 -c 'import json, sys; print(json.dumps(sys.argv[1]))' "$1"
}

run_case() {
  local session="$1"
  local command="$2"
  local payload

  printf '%s\n' "$RANDOM" >>"$REPO/file"
  git -C "$REPO" add file
  payload="{\"session_id\":\"$session\",\"cwd\":$(json_string "$REPO"),\"tool_input\":{\"command\":$(json_string "$command")},\"tool_response\":{}}"
  TMPDIR="$TEST_TMP" bash "$HOOK" pre <<<"$payload"
  (cd "$REPO" && bash -c "$command") >/dev/null 2>&1 || true
  TMPDIR="$TEST_TMP" bash "$HOOK" <<<"$payload"
}

assert_case() {
  local want="$1"
  local name="$2"
  local command="$3"
  local output

  output=$(run_case "case-$RANDOM-$RANDOM" "$command")
  if [[ "$want" == trigger && "$output" != *hookSpecificOutput* ]]; then
    printf 'FAIL: %s should trigger\n' "$name" >&2
    exit 1
  fi
  if [[ "$want" == ignore && -n "$output" ]]; then
    printf 'FAIL: %s should be ignored, got: %s\n' "$name" "$output" >&2
    exit 1
  fi
}

# Runs both phases from $REPO without a command in between, for payloads
# whose outcome does not depend on what the command did.
run_hook() {
  TMPDIR="$TEST_TMP" bash "$HOOK" pre <<<"$1"
  TMPDIR="$TEST_TMP" bash "$HOOK" <<<"$1"
}

assert_payload() {
  local want="$1"
  local name="$2"
  local payload="$3"
  local max_seconds="${4:-0}"
  local output
  local started_at=$SECONDS

  output=$(cd "$REPO" && run_hook "$payload")
  if (( max_seconds && SECONDS - started_at > max_seconds )); then
    printf 'FAIL: %s took longer than %s seconds\n' "$name" "$max_seconds" >&2
    exit 1
  fi
  if [[ "$want" == trigger && "$output" != *hookSpecificOutput* ]]; then
    printf 'FAIL: %s should trigger\n' "$name" >&2
    exit 1
  fi
  if [[ "$want" == ignore && -n "$output" ]]; then
    printf 'FAIL: %s should be ignored, got: %s\n' "$name" "$output" >&2
    exit 1
  fi
}

assert_case trigger "plain commit" 'git commit -q -m test'
assert_case trigger "amend" 'git commit -q --amend -m amended'
assert_case trigger "commit after cd" 'cd . && git commit -q -m test'
assert_case trigger "commit behind timeout" 'timeout 30 git commit -q -m test 2>/dev/null || git commit -q -m test'
assert_case trigger "commit inside bash -c" "bash -c 'git commit -q -m test'"
assert_case trigger "commit behind env and global option" 'env FOO=1 git -c core.quotepath=off commit -q -m test'
assert_case trigger "commit in multi-line bash -c" $'bash -c \'\ngit commit -q -m test\n\''
assert_case trigger "multi-line message with help-shaped text" $'git commit -q -m "Fix -h\nhandling"'
assert_case trigger "message from heredoc substitution" $'git commit -q -m "$(cat <<\'EOF\'\nFix --dry-run handling\nEOF\n)"'
assert_case trigger "commit substitution in heredoc body" $'cat <<EOF >/dev/null\n$(\ngit commit -q -m test\n)\nEOF'

assert_case ignore "dry run" 'git commit --dry-run -m test'
assert_case ignore "commit help" 'git commit -h'
assert_case ignore "failed commit" 'git commit -q -m test --no-such-flag'
assert_case ignore "commit text in heredoc body" $'cat > release.sh <<\'EOF\'\ngit add -A\ngit commit -m release\nEOF'
assert_case ignore "commit text in echo" 'echo "git commit -m test"'
assert_case ignore "git log mentioning commit" 'git log -1 --format=%s commit'
assert_case ignore "non-commit reflog entry" 'git checkout -q -b "branch-$RANDOM" && git reset -q --soft HEAD~1 && echo git commit'

assert_case trigger "commit then checkout back" 'old=$(git rev-parse HEAD) && git commit -q -m test && git checkout -q "$old"'
git -C "$REPO" checkout -q -

git -C "$REPO" commit -q --allow-empty -m before
assert_case ignore "commit made before the command" 'git status # git commit'

payload='{"session_id":"trigger-no-snapshot","cwd":"'"$REPO"'","tool_input":{"command":"git commit -m test"},"tool_response":{}}'
git -C "$REPO" commit -q --allow-empty -m unseen
if [[ -n "$(TMPDIR="$TEST_TMP" bash "$HOOK" <<<"$payload")" ]]; then
  printf 'FAIL: post phase without a pre snapshot should be ignored\n' >&2
  exit 1
fi

# Runs both phases around a commit made in directory $2 with cwd $2.
assert_commit_in() {
  local name="$1"
  local dir="$2"
  local payload

  payload='{"session_id":"dir-'"$RANDOM"'","cwd":"'"$dir"'","tool_input":{"command":"git commit -m test"},"tool_response":{}}'
  TMPDIR="$TEST_TMP" bash "$HOOK" pre <<<"$payload"
  git -C "$dir" commit -q --allow-empty -m "$name"
  if [[ "$(TMPDIR="$TEST_TMP" bash "$HOOK" <<<"$payload")" != *hookSpecificOutput* ]]; then
    printf 'FAIL: commit in %s should trigger\n' "$name" >&2
    exit 1
  fi
}

mkdir -p "$REPO/sub/dir"
assert_commit_in "repository subdirectory" "$REPO/sub/dir"
git -C "$REPO" worktree add -q "$TEST_TMP/worktree" -b "worktree-$RANDOM"
assert_commit_in "worktree" "$TEST_TMP/worktree"

new_repo="$TEST_TMP/new-repo"
mkdir "$new_repo"
payload='{"session_id":"trigger-git-init","cwd":"'"$new_repo"'","tool_input":{"command":"git init -q && git commit -q --allow-empty -m first"},"tool_response":{}}'
TMPDIR="$TEST_TMP" bash "$HOOK" pre <<<"$payload"
(cd "$new_repo" && git init -q && git commit -q --allow-empty -m first)
if [[ "$(TMPDIR="$TEST_TMP" bash "$HOOK" <<<"$payload")" != *hookSpecificOutput* ]]; then
  printf 'FAIL: first commit in a repository created by the command should trigger\n' >&2
  exit 1
fi

session="cap-$RANDOM"
for offer in 1 2 3; do
  output=$(run_case "$session" 'git commit -q -m test')
  if (( offer <= 2 )) && [[ "$output" != *hookSpecificOutput* ]]; then
    printf 'FAIL: session offer %s should trigger\n' "$offer" >&2
    exit 1
  fi
  if (( offer > 2 )) && [[ -n "$output" ]]; then
    printf 'FAIL: session offer %s should be capped\n' "$offer" >&2
    exit 1
  fi
done

payload='{"session_id":"trigger-no-cwd","tool_input":{"cmd":"git commit -m test"},"tool_response":{}}'
(cd "$REPO" && TMPDIR="$TEST_TMP" bash "$HOOK" pre <<<"$payload")
git -C "$REPO" commit -q --allow-empty -m no-cwd
if [[ "$(cd "$REPO" && TMPDIR="$TEST_TMP" bash "$HOOK" <<<"$payload")" != *hookSpecificOutput* ]]; then
  printf 'FAIL: payload without cwd should use the hook directory\n' >&2
  exit 1
fi

assert_payload ignore \
  "empty session id" \
  '{"session_id":"","tool_input":{"command":"git commit -m test"},"tool_response":{}}'

assert_payload ignore \
  "commit command only in tool response" \
  '{"session_id":"ignore-response-command","tool_input":{"command":"git status"},"tool_response":{"command":"git commit -m test"}}'

assert_payload ignore \
  "not a repository" \
  '{"session_id":"ignore-no-repo","cwd":"/","tool_input":{"command":"git commit -m test"},"tool_response":{}}'

large_response=$(awk -v size="$LARGE_RESPONSE_BYTES" 'BEGIN { printf "%*s", size, "" }')
assert_payload ignore \
  "large response before tool input" \
  '{"session_id":"ignore-large-response","tool_response":{"stdout":"'"$large_response"'"},"tool_input":{"command":"git status --short"}}' \
  "$MAX_HOOK_SECONDS"

many_strings=$(awk -v count="$MANY_JSON_STRINGS" 'BEGIN { for (i = 1; i < count; i++) printf "\"ab\","; printf "\"ab\"" }')
assert_payload ignore \
  "session id after many response strings" \
  '{"tool_input":{"command":"git commit -m test"},"tool_response":{"items":['"$many_strings"']},"session_id":"ignore-late-session-id"}' \
  "$MAX_HOOK_SECONDS"

many_escapes=$(awk -v count="$MANY_JSON_STRINGS" 'BEGIN { for (i = 0; i < count; i++) printf "say \\\"hi\\\" -h\\n" }')
assert_payload ignore \
  "large heredoc with many escapes" \
  '{"session_id":"ignore-large-heredoc","tool_input":{"command":"cat > notes <<EOF\n'"$many_escapes"'EOF\ngit status"},"tool_response":{}}' \
  "$MAX_HOOK_SECONDS"

# Each hook config resolves the script via a plugin-root variable and a
# matcher. Rather than pattern-match the JSON, actually run the configured
# command so a wrong variable name, wrong subpath, or a broken
# missing-script guard fails here instead of only at runtime.
config_command() {
  tr -d '\r' <"$1" | sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/p' | sed 's/\\"/"/g'
}

config_matcher() {
  tr -d '\r' <"$1" | sed -n 's/.*"matcher"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

plugin_root="$(cd -- "$SCRIPT_DIR/.." && pwd)"

# Checks that both phases in config $1 match Bash and, run with plugin-root
# variable $2 set, detect a commit made between them.
check_config() {
  local config="$1"
  local root_variable="$2"
  local matcher
  local pre_command
  local post_command
  local payload
  local output

  while read -r matcher; do
    if [[ "$matcher" != *Bash* ]]; then
      printf 'FAIL: %s matcher %s does not cover the Bash tool\n' "$config" "$matcher" >&2
      exit 1
    fi
  done < <(config_matcher "$config")

  pre_command=$(config_command "$config" | sed -n 1p)
  post_command=$(config_command "$config" | sed -n 2p)
  if [[ "$pre_command" != *" pre"* || "$post_command" == *" pre"* ]]; then
    printf 'FAIL: %s should run the pre phase first, got %s then %s\n' "$config" "$pre_command" "$post_command" >&2
    exit 1
  fi

  payload='{"session_id":"config-'"$root_variable"'","cwd":"'"$REPO"'","tool_input":{"command":"git commit -m test"},"tool_response":{}}'
  output=$(env TMPDIR="$TEST_TMP" "$root_variable=$plugin_root" bash -c "$pre_command" <<<"$payload" 2>&1)
  git -C "$REPO" commit -q --allow-empty -m "config $root_variable"
  output+=$(env TMPDIR="$TEST_TMP" "$root_variable=$plugin_root" bash -c "$post_command" <<<"$payload" 2>&1)
  if [[ "$output" != *hookSpecificOutput* ]]; then
    printf 'FAIL: %s commands did not resolve to a working hook, got: %s\n' "$config" "$output" >&2
    exit 1
  fi
}

check_config "$SCRIPT_DIR/hooks.json" CLAUDE_PLUGIN_ROOT
check_config "$SCRIPT_DIR/../hooks.codex.json" PLUGIN_ROOT

missing_root="$TEST_TMP/no-such-plugin-root"
while read -r codex_command; do
  set +e
  output=$(PLUGIN_ROOT="$missing_root" bash -c "$codex_command" <<<'{"session_id":"x","tool_input":{"command":"git commit"}}' 2>&1)
  status=$?
  set -e
  if (( status != 0 )) || [[ -n "$output" ]]; then
    printf 'FAIL: hooks.codex.json command should no-op silently when PLUGIN_ROOT is missing, got status %s output: %s\n' "$status" "$output" >&2
    exit 1
  fi
done < <(config_command "$SCRIPT_DIR/../hooks.codex.json")

printf 'post-tool-use hook tests passed\n'
