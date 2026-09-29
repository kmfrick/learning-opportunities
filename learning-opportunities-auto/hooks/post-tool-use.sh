#!/usr/bin/env bash
set -uo pipefail

# learning-opportunities-auto: PreToolUse and PostToolUse hook (matches Bash tool)
#
# Run with `pre` before a Bash tool use to snapshot the repository's HEAD
# reflog, and without arguments after it. If the command added a commit to
# the reflog, suggest that Claude offer a learning exercise.
# The skill itself decides whether the commit's content is worth an
# exercise; this hook just provides the nudge at the right moment.
#
# No external dependencies beyond bash and standard Unix tools.

readonly ROOT_OBJECT_DEPTH=1
readonly TOOL_INPUT_KEY='tool_input'
readonly SESSION_ID_KEY='session_id'
readonly CWD_KEY='cwd'
readonly COMMAND_KEY='command'
readonly LEGACY_COMMAND_KEY='cmd'
readonly UNICODE_ESCAPE_HEX_LENGTH=4
readonly ASCII_CODE_POINT_LIMIT=128
readonly MAX_SESSION_OFFERS=2
readonly PHASE="${1:-post}"

# Parse the top-level session_id and cwd, and whether the direct command in
# tool_input mentions both "git" and "commit". The command is only searched,
# never decoded, so large commands stay cheap. A single awk process avoids
# scanning large tool responses once the fields are found.
parse_hook_input() {
  LC_ALL=C awk \
    -v root_depth="$ROOT_OBJECT_DEPTH" \
    -v tool_input_key="$TOOL_INPUT_KEY" \
    -v session_id_key="$SESSION_ID_KEY" \
    -v cwd_key="$CWD_KEY" \
    -v command_key="$COMMAND_KEY" \
    -v legacy_command_key="$LEGACY_COMMAND_KEY" \
    -v unicode_hex_length="$UNICODE_ESCAPE_HEX_LENGTH" \
    -v ascii_code_point_limit="$ASCII_CODE_POINT_LIMIT" '
    function decoded_unicode(hex, code, j, digit) {
      if (length(hex) != unicode_hex_length || hex ~ /[^[:xdigit:]]/) return "?"
      code = 0
      for (j = 1; j <= unicode_hex_length; j++) {
        digit = index("0123456789abcdef", tolower(substr(hex, j, 1))) - 1
        code = code * 16 + digit
      }

      # \001 is the escaped-backslash placeholder in decoded_json.
      if (code == 1) return "?"
      return code < ascii_code_point_limit ? sprintf("%c", code) : "?"
    }

    # Concatenate pieces[low..high] in O(n log n) instead of appending one by
    # one, which copies the growing string each time.
    function joined(pieces, low, high, middle) {
      if (low > high) return ""
      if (low == high) return pieces[low]

      middle = int((low + high) / 2)
      return joined(pieces, low, middle) joined(pieces, middle + 1, high)
    }

    # Decode with whole-string substitutions so commands with thousands of
    # escapes stay linear. Escaped backslashes hide behind \001 until the end,
    # and \u escapes are decoded last, so decoded text never starts an escape.
    function decoded_json(raw, parts, count, part) {
      if (index(raw, "\\") == 0) return raw

      gsub(/\\\\/, "\001", raw)
      gsub(/\\[nr]/, "\n", raw)
      gsub(/\\t/, "\t", raw)
      gsub(/\\[bf]/, " ", raw)
      gsub(/\\"/, "\"", raw)
      gsub(/\\\//, "/", raw)
      if (index(raw, "\\u")) {
        count = split(raw, parts, /\\u/)
        for (part = 2; part <= count; part++) {
          parts[part] = decoded_unicode(substr(parts[part], 1, unicode_hex_length)) \
            substr(parts[part], unicode_hex_length + 1)
        }
        raw = joined(parts, 1, count)
      }
      gsub(/\001/, "\\", raw)
      return raw
    }

    function finish_string() {
      if (string_is_key) {
        key[depth] = decoded_json(value)
        expect_key[depth] = 0
        return
      }
      if (!capture_string) return

      value = decoded_json(value)

      if (depth == root_depth && key[depth] == session_id_key) {
        # session_id becomes the first line of this output; strip newlines
        # so an embedded one is never mistaken for that line split.
        gsub(/[\r\n]/, "", value)
        session_id = value
        found_session_id = 1
      } else if (depth == root_depth && key[depth] == cwd_key) {
        gsub(/[\r\n]/, "", value)
        cwd = value
        found_cwd = 1
      }
    }

    function finish_command(mentions) {
      mentions = mentions_git && mentions_commit
      if (key[depth] == command_key) {
        command_mentions_commit = mentions
        found_command = 1
      } else {
        legacy_command_mentions_commit = mentions
        found_legacy_command = 1
      }
    }

    # Payloads without a cwd are read to the end, where emit_input runs from END.
    function emit_input() {
      if (emitted || !found_session_id || (!found_cwd && !at_end)) return

      emitted = 1
      if (!found_command && found_legacy_command) {
        command_mentions_commit = legacy_command_mentions_commit
        found_command = 1
      }
      if (!found_command) exit

      print session_id
      print cwd
      print command_mentions_commit
      exit
    }

    function scan_structure(text, text_length, position, c, parent_depth) {
      text_length = length(text)
      for (position = 1; position <= text_length; position++) {
        c = substr(text, position, 1)

        if (c == "{") {
          parent_depth = depth
          depth++
          container[depth] = "object"
          expect_key[depth] = 1

          if (parent_depth == root_depth && key[parent_depth] == tool_input_key) {
            tool_input_depth = depth
          }
          continue
        }
        if (c == "[") {
          depth++
          container[depth] = "array"
          continue
        }
        if (c == "}" || c == "]") {
          if (depth == tool_input_depth) {
            tool_input_depth = 0
            tool_input_complete = 1
            emit_input()
          }

          delete container[depth]
          delete expect_key[depth]
          delete key[depth]
          depth--

          if (depth == 0 && tool_input_complete) emit_input()
          continue
        }
        if (c == "," && container[depth] == "object") {
          expect_key[depth] = 1
          delete key[depth]
        }
      }
    }

    # Records split at quotes alternate between JSON structure and string
    # contents, so each payload byte is copied once rather than once per string.
    BEGIN { RS = "\"" }

    in_string {
      if (capture_command) {
        if (index($0, "git")) mentions_git = 1
        if (index($0, "commit")) mentions_commit = 1
      } else if (capture_string) {
        value_piece[++value_pieces] = $0
      }

      # An odd run of trailing backslashes escapes the quote that ended this
      # record, so the string continues into the next one.
      if (substr($0, length($0)) == "\\" && match($0, /\\+$/) && RLENGTH % 2) {
        if (capture_string) value_piece[++value_pieces] = "\""
        next
      }

      in_string = 0
      if (capture_command) {
        finish_command()
      } else {
        value = joined(value_piece, 1, value_pieces)
        finish_string()
      }
      if (tool_input_complete) emit_input()
      next
    }

    {
      scan_structure($0)

      string_is_key = container[depth] == "object" && expect_key[depth]
      capture_command = !string_is_key && depth == tool_input_depth &&
        (key[depth] == command_key || key[depth] == legacy_command_key)
      capture_string = string_is_key || capture_command ||
        (depth == root_depth &&
          (key[depth] == session_id_key || key[depth] == cwd_key))
      if (value_pieces) delete value_piece
      value_pieces = 0
      mentions_git = mentions_commit = 0
      in_string = 1
    }

    END {
      at_end = 1
      if (tool_input_complete) emit_input()
    }
  '
}

PARSED_INPUT=$(parse_hook_input)
SESSION_ID=${PARSED_INPUT%%$'\n'*}
REMAINING_INPUT=${PARSED_INPUT#*$'\n'}
if [[ "$PARSED_INPUT" != *$'\n'* || "$REMAINING_INPUT" != *$'\n'* ]]; then
  exit 0
fi
CWD=${REMAINING_INPUT%%$'\n'*}
COMMAND_MENTIONS_COMMIT=${REMAINING_INPUT#*$'\n'}

# An empty session id can't rate-limit per session, so treat it like no
# session id at all rather than sharing one state file across callers.
if [[ -z "$SESSION_ID" ]]; then
  exit 0
fi

# Cheap filter: a command that never mentions both words did not commit.
if [[ "$COMMAND_MENTIONS_COMMIT" != 1 ]]; then
  exit 0
fi

STATE_PREFIX="${TMPDIR:-/tmp}/lo_auto_${SESSION_ID//[^a-zA-Z0-9_-]/_}"
SNAPSHOT_FILE="$STATE_PREFIX.reflog"
REPO_DIR="${CWD:-$PWD}"

# Ask the repository instead of parsing the shell command. A commit appends a
# HEAD reflog line however it was run (wrappers, sh -c, scripts), and dry runs,
# failed commits, or commit text in heredocs append none. The pre phase records
# the reflog's length so the post phase reads only lines this command added.
# Find the HEAD reflog of the repository containing REPO_DIR without starting
# git, which costs more than the rest of the hook. A .git file marks a
# worktree or submodule and points at its git directory.
reflog_path() {
  local dir="$REPO_DIR"
  local git_dir

  while true; do
    if [[ -d "$dir/.git" ]]; then
      printf '%s\n' "$dir/.git/logs/HEAD"
      return 0
    fi
    if [[ -f "$dir/.git" ]]; then
      read -r git_dir <"$dir/.git"
      git_dir=${git_dir#gitdir: }
      [[ "$git_dir" == /* ]] || git_dir="$dir/$git_dir"
      printf '%s\n' "$git_dir/logs/HEAD"
      return 0
    fi
    if [[ -z "$dir" || "$dir" != */* ]]; then
      return 1
    fi
    dir=${dir%/*}
  done
}

# Byte size, so the post phase can seek straight to the new lines however
# long the reflog is.
file_size() {
  local size=0
  if [[ -f "$1" ]]; then
    size=$(wc -c <"$1")
  fi
  printf '%s\n' "$(( size ))"
}

if [[ "$PHASE" == pre ]]; then
  reflog=$(reflog_path) || reflog=''
  printf '%s\n%s\n' "$reflog" "$(file_size "$reflog")" >"$SNAPSHOT_FILE"
  exit 0
fi

# Without a snapshot from the pre phase there is no way to tell whether the
# newest commit came from this command, so stay quiet.
if [[ ! -f "$SNAPSHOT_FILE" ]]; then
  exit 0
fi
{ read -r reflog; read -r offset; } <"$SNAPSHOT_FILE"
rm -f "$SNAPSHOT_FILE"
if [[ -z "$reflog" ]]; then
  reflog=$(reflog_path) || exit 0
fi
if [[ ! -f "$reflog" || ! "$offset" =~ ^[0-9]+$ ]]; then
  exit 0
fi
# Reflog expiry (for example from `git gc --auto`) can shrink the file; then
# only the newest line can be from this command.
if (( $(file_size "$reflog") < offset )); then
  new_entries=$(tail -n 1 "$reflog")
else
  new_entries=$(tail -c +"$(( offset + 1 ))" "$reflog")
fi

# Each reflog line ends in a tab and the entry message, such as
# "commit: ...", "commit (amend): ...", or "checkout: ...".
committed=0
while IFS=$'\t' read -r _ message; do
  if [[ "$message" =~ ^commit(\ \([a-z]+\))?: ]]; then
    committed=1
    break
  fi
done <<<"$new_entries"
if (( ! committed )); then
  exit 0
fi

# Cap automatic nudges per session. The skill separately suppresses offers
# after a decline or two completed exercises.
STATE_FILE="$STATE_PREFIX.state"

offers=0
if [[ -f "$STATE_FILE" ]]; then
  offers=$(<"$STATE_FILE")
fi
if [[ ! "$offers" =~ ^[0-9]+$ ]]; then
  offers=0
fi
if (( offers >= MAX_SESSION_OFFERS )); then
  exit 0
fi

printf '%s\n' "$(( offers + 1 ))" >"$STATE_FILE"
# ---------------------------------------------------------------------------
# Emit suggestion for Claude via structured JSON. PostToolUse hooks must
# output JSON with hookSpecificOutput on exit 0 to inject context.
# The message contains no special characters that need escaping.
# ---------------------------------------------------------------------------

cat <<'HOOK_JSON'
{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"[learning-opportunities-auto] The user just made a git commit. Use the learning-opportunities skill to consider whether this is a good moment to offer a learning exercise. If the committed work involved new files, schema changes, architectural decisions, refactors, or unfamiliar patterns, ask the user (one short sentence) if they'd like a 10-15 minute exercise. Do not start the exercise until they confirm. If they decline, note it — no more offers this session."}}
HOOK_JSON

exit 0
