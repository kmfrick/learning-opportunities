# Changelog

## learning-opportunities-auto 1.0.3

**Changed:**
- Detect commits from the repository's HEAD reflog instead of parsing the shell command. A new `PreToolUse` hook records the reflog's size, and the `PostToolUse` hook nudges only when the command added a commit entry. Commits are recognized however they are run (wrappers, `sh -c`, scripts, multi-line messages), and dry runs, failed commits, and commit text in heredocs or echoed output never trigger
- The nudge no longer asks Claude to check whether the commit succeeded, since only successful commits trigger it

**Fixed:**
- Use Codex's plugin root environment variable instead of a version-specific cache path, while still failing silently if the resolved script is missing
- Read the command only from the top-level hook input, and stop parsing once the required fields are found, so large tool responses do not delay every shell command
- Keep JSON parsing linear for payloads with many strings or escapes
- Preserve the automatic two-offer session cap, including for an empty or newline-containing session id

## learning-opportunities-auto 1.0.2

**Fixed:**
- Fixed Codex hook execution from repository working directories by resolving the hook script from Codex's plugin cache instead of using a repo-relative path

## orient 1.0.0

Added orient plugin to the learning-opportunities marketplace.

**New:**
- `orient` skill for generating repo-specific orientation files using program comprehension research
- Showboat mode for detailed linear code walkthroughs

## learning-opportunities-auto 1.0.1

**Fixed:**
- Moved hook declaration from inline `plugin.json` format to `hooks/hooks.json`, which is the format Claude Code actually reads at runtime
- Moved `scripts/post-tool-use.sh` to `hooks/post-tool-use.sh` to colocate with hook configuration

## learning-opportunities-auto 1.0.0

Initial release of the automatic hook companion plugin.

**New:**
- `PostToolUse` hook that triggers after `git commit` and nudges Claude to offer a learning exercise when appropriate
- Bash implementation — works on Linux and macOS out of the box; Windows users need to configure `CLAUDE_CODE_GIT_BASH_PATH` (see README)
- Session state tracking: respects the learning-opportunities skill's two-exercise-per-session limit and declined-offer flag

## learning-opportunities 1.0.0

Initial release as a Claude Code plugin.

**New:**
- `learning-opportunities` skill for science-based deliberate practice during AI-assisted coding
- Exercise types: Prediction/Observation/Reflection, Generation/Comparison, Trace the Path, Debug This, Teach It Back, Retrieval Check-in
- Supporting resources: PRINCIPLES.md (learning science foundations), MEASURE-THIS.md (team experiment playbook)
