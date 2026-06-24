#!/usr/bin/env bash
set -uo pipefail

# learning-opportunities-auto: PostToolUse hook (matches Bash tool)
#
# Fires after every Bash tool use. Checks whether the command was a
# `git commit` and, if so, suggests that Claude offer a learning exercise.
# The skill itself decides whether the commit's content is worth an
# exercise; this hook just provides the nudge at the right moment.
#
# No external dependencies beyond bash and standard Unix tools.

INPUT=$(cat)
JSON=$(printf '%s' "$INPUT" | tr '\n' ' ')

# Claude Code sends shell text in tool_input.command; Codex sends it in
# tool_input.cmd. Ignore command-like fields elsewhere in the payload so
# tool_response output cannot trigger this hook.
json_string() {
  local key="$1"
  local text="$2"

  printf '%s' "$text" |
    sed -nE 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)".*/\1/p'
}

# Extract only a depth-1 object, so nested tool_response payloads are ignored.
json_object() {
  local key="$1"
  local text="$2"
  local -r JSON_CHARACTER_BYTES=1

  printf '%s' "$text" |
    LC_ALL=C fold -b -w "$JSON_CHARACTER_BYTES" |
    LC_ALL=C awk -v key="$key" '
      {
        c = $0
        if (capturing) {
          if (in_string) {
            printf "%s", c
            if (escaped) escaped = 0
            else if (c == "\\") escaped = 1
            else if (c == "\"") in_string = 0
            next
          }

          if (c == "\"") in_string = 1
          else if (c == "{") capture_depth++
          else if (c == "}") capture_depth--
          if (capture_depth == 0) exit

          printf "%s", c
          next
        }

        if (in_string) {
          if (escaped) {
            escaped = 0
            candidate = 0
            next
          }
          if (c == "\\") {
            escaped = 1
            candidate = 0
            next
          }
          if (c == "\"") {
            in_string = 0
            after_key = candidate && key_position > length(key)
            next
          }
          if (!candidate) next

          candidate = c == substr(key, key_position, 1)
          key_position++
          next
        }

        if (after_key && c ~ /[[:space:]]/) next
        if (after_key && c == ":") {
          after_key = 0
          after_colon = 1
          next
        }
        after_key = 0

        if (after_colon && c ~ /[[:space:]]/) next
        if (after_colon && c == "{") {
          after_colon = 0
          capturing = capture_depth = 1
          next
        }
        after_colon = 0

        if (c == "\"") {
          in_string = 1
          candidate = depth == 1
          key_position = 1
        } else if (c == "{") {
          depth++
        } else if (c == "}") {
          depth--
        }
      }'
}

SESSION_ID=$(json_string session_id "$JSON")
TOOL_INPUT=$(json_object tool_input "$JSON")
COMMAND=$(json_string cmd "$TOOL_INPUT")
if [[ -z "$COMMAND" ]]; then
  COMMAND=$(json_string command "$TOOL_INPUT")
fi

# Heuristic hook detector. Collapse quoted text to one argument before splitting,
# so quoted command examples stay ignored without losing real argument positions.
git_commit_segments() {
  local -r QUOTED_ARGUMENT='__quoted_argument__'
  local -r VALUE_OPTIONS='-m -F -C -c -t --message --file --reuse-message --reedit-message --fixup --squash --template --author --date --cleanup --trailer --pathspec-from-file'
  local -r SHORT_VALUE_OPTIONS='mFCct'
  local -r NON_MUTATING_OPTIONS='--help -h --dry-run'

  printf '%s\n' "$1" |
    sed -E "s/'[^']*'/$QUOTED_ARGUMENT/g; s/\\\\?\"([^\"\\\\]|\\\\.)*\\\\?\"/$QUOTED_ARGUMENT/g" |
    awk '{ gsub(/\\r\\n|\\n|\\r/, "\n"); print }' |
    tr ';|&(){}' '\n' |
    sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' |
    sed -nE '/^git([[:space:]]+-C[[:space:]]+[^[:space:]]+|[[:space:]]+-C[^[:space:]]+|[[:space:]]+-c[[:space:]]+[^[:space:]]+|[[:space:]]+-c[^[:space:]]+|[[:space:]]+--(no-pager|paginate|bare|literal-pathspecs|no-optional-locks|no-replace-objects))*[[:space:]]+commit([[:space:]]|$)/p' |
    awk -v value_options="$VALUE_OPTIONS" -v short_value_options="$SHORT_VALUE_OPTIONS" \
      -v non_mutating_options="$NON_MUTATING_OPTIONS" '
      BEGIN {
        split(value_options, values)
        for (i in values) value_option[values[i]] = 1

        split(non_mutating_options, flags)
        for (i in flags) non_mutating_option[flags[i]] = 1
      }

      {
        for (i = 1; i <= NF && $i != "commit"; i++);

        expects_value = 0
        for (i++; i <= NF; i++) {
          token = $i
          if (expects_value) {
            expects_value = 0
            continue
          }
          if (token == "--") break
          if (token in non_mutating_option) next

          option = token
          sub(/=.*/, "", option)
          if (option in value_option && token == option) {
            expects_value = 1
            continue
          }
          if (token !~ /^-[^-]+$/) continue

          short_options = token
          sub(/^-/, "", short_options)
          for (j = 1; j <= length(short_options); j++) {
            short_option = substr(short_options, j, 1)
            if (!index(short_value_options, short_option)) continue

            expects_value = (j == length(short_options))
            break
          }
        }

        matched = 1
        print
      }

      END { exit !matched }'
}

if [[ -z "$SESSION_ID" ]] || [[ -z "$COMMAND" ]] || ! git_commit_segments "$COMMAND" >/dev/null; then
  exit 0
fi

# ---------------------------------------------------------------------------
# Session state: track how many exercises have been offered this session.
# Uses a temp file keyed on session ID; resets when the session ends.
# ---------------------------------------------------------------------------

STATE_FILE="${TMPDIR:-/tmp}/lo_auto_${SESSION_ID//[^a-zA-Z0-9_-]/_}.state"

offers=0
if [[ -f "$STATE_FILE" ]]; then
  offers=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
fi

# Stop after 2 offers per session.
if [[ "$offers" -ge 2 ]]; then
  exit 0
fi

# Record the offer.
echo $(( offers + 1 )) > "$STATE_FILE"

# ---------------------------------------------------------------------------
# Emit suggestion for Claude via structured JSON. PostToolUse hooks must
# output JSON with hookSpecificOutput on exit 0 to inject context.
# The message contains no special characters that need escaping.
# ---------------------------------------------------------------------------

cat <<'HOOK_JSON'
{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"[learning-opportunities-auto] The user just committed code. Per the learning-opportunities skill, consider whether this is a good moment to offer a learning exercise. If the committed work involved new files, schema changes, architectural decisions, refactors, or unfamiliar patterns, ask the user (one short sentence) if they'd like a 10-15 minute exercise. Do not start the exercise until they confirm. If they decline, note it — no more offers this session."}}
HOOK_JSON

exit 0
