#!/usr/bin/env bash
#
# Stage 1 of deterministic capture: the free one.
#
# Runs when a turn ends and decides, without spending anything, whether this
# turn is even worth asking about. Most are not — "what does this function do",
# "run the tests", "fix that typo" — and dropping them here is what makes
# capture affordable enough to leave on permanently.
#
# It exits 0 in every path on purpose. A hook that fails loudly after every
# message is a hook the user disables within a day, and capture that is off is
# worth less than capture that occasionally misses a turn.
#
# Runs with async: true, so nothing here is on the user's critical path.

set -uo pipefail

INPUT=$(cat)
API="${KIKA_API_URL:-https://api.getkika.app}"

command -v jq >/dev/null 2>&1 || exit 0

CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""')

# The token: one credential, the one you already pasted. See token.sh — it is
# shared with the session-start hook so the two cannot drift apart.
# shellcheck source=token.sh
. "$(dirname "${BASH_SOURCE[0]}")/token.sh"

[ -z "$TOKEN" ] && exit 0
# `last_assistant_message` rather than the transcript, per Claude Code's own
# guidance: the transcript is written asynchronously and may not yet contain
# the turn that just ended.
# Bounded, like the user's side below. It was not, and the privacy policy and
# the README both claimed "4,000 characters at most" — true of the user message
# and not of this one, which can be a whole file dump. A document that overstates
# a limit is worse than one that states a larger limit honestly, and the server
# only reads the last 12,000 characters anyway, so nothing is lost by capping.
#
# The TAIL is kept, not the head: the conclusion of a reply is at the end, which
# is the same reason the server keeps the tail of the excerpt it classifies.
LAST=$(printf '%s' "$INPUT" | jq -r '.last_assistant_message // ""' | tail -c 8000)
TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // ""')

# The user's side of the turn, from the transcript. Worth reading even though
# it lags, because the DECISION is usually in what the user said ("no, use
# Postgres, we need RLS") while the assistant's reply is the work that followed.
# The HUMAN's last message — not the last entry of type "user". In Claude
# Code's transcript a tool result is also a "user" entry (that is how the API
# frames it), so on any turn that used a tool, "last user entry" was a page of
# {"tool_use_id": …, "content": …} JSON and the thing the person actually typed
# was never sent. The classifier was reading tool output where it expected a
# request, and the trail showed JSON where it should have shown a sentence.
#
# A human entry is one whose content is a plain string, or an array with text
# blocks and no tool_result block. The tail of it, since that is where a
# conclusion is.
#
# Far enough back to reach it. The window was 400 lines, and a long agentic turn
# writes more than that after the request: on 2026-10-29 a real turn ran ~950
# lines of tool calls, the human message fell outside the window, the classifier
# saw "User:" with nothing after it, dropped the turn — and the engagement it had
# just created stayed empty. Lines are streamed one at a time (not slurped), so a
# wide window costs no memory, and a half-written last line is skipped rather
# than failing the whole parse.
USER_MSG=""
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  USER_MSG=$(tail -n 20000 "$TRANSCRIPT" 2>/dev/null \
    | jq -cR '
        fromjson? // empty
        | select(.type == "user")
        | .message.content
        | if type == "string" then .
          elif type == "array" and any(.[]; .type == "tool_result") then empty
          elif type == "array" then map(select(.type == "text") | .text) | join("\n")
          else empty end
        | select(length > 0)' 2>/dev/null \
    | tail -n 1 | jq -r '. // ""' 2>/dev/null \
    | tail -c 4000)
fi

EXCERPT=$(printf 'User:\n%s\n\nAssistant:\n%s' "$USER_MSG" "$LAST")

# A decision can be short. "We're going with Postgres, we don't want a second
# datastore" is sixty characters and is exactly what this exists to keep, so
# length alone is the wrong test — a 179-character turn settling Vitest over
# Jest, with its reason, was dropped by a 200-character floor.
#
# The floor was guarding a cost that is not real: the classifier is Haiku on a
# couple of thousand tokens, a fraction of a cent, and it already answers "no"
# to most of what reaches it. So the cheap check now looks for the SHAPE of a
# decision and lets anything with one through at any length, while everything
# else still has to clear a much lower bar.
#
# Matched across the whole excerpt, not just the reply: the decision is often
# the user's ("no, use Rabbit, their ops team knows it") and the reply is the
# work that followed.
DECISION_SHAPE='(because|rather than|instead of|decided|decision|blocked|blocker|ruled out|going with|we will use|turns out|the reason)'
if printf '%s' "$EXCERPT" | grep -qiE "$DECISION_SHAPE"; then
  : # a reason is present — worth a look however short
elif [ ${#LAST} -lt 120 ]; then
  exit 0
fi

# The heuristic. Every pattern here is a turn shape that has never once
# contained durable project state, and together they are most turns.
#
# Deliberately matched against the ASSISTANT's reply only. Filtering on what
# the user said would drop "we're going with Postgres because of RLS" for
# being short, and that is precisely the sentence worth keeping.
if printf '%s' "$LAST" | grep -qiE '^(done|fixed|added|updated|removed)\.?$'; then
  exit 0
fi

# The git remote identifies the engagement across machines and people, which is
# what lets a teammate's capture land in the same project rather than a second
# graph. Normalisation happens server-side, so every spelling is fine here.
REMOTE=""
BRANCH=""
if [ -n "$CWD" ] && [ -d "$CWD" ]; then
  REMOTE=$(git -C "$CWD" remote get-url origin 2>/dev/null || true)
  # Which branch the decision was made on. A decision recorded on a branch
  # that never merged is a decision that never happened, and a reader six
  # weeks later cannot tell without this.
  BRANCH=$(git -C "$CWD" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
fi

RESP=$(jq -n \
  --arg excerpt "$EXCERPT" \
  --arg cwd "$CWD" \
  --arg gitRemote "$REMOTE" \
  --arg branch "$BRANCH" \
  --arg sessionId "$(printf '%s' "$INPUT" | jq -r '.session_id // ""')" \
  '{excerpt: $excerpt, cwd: $cwd, gitRemote: $gitRemote, branch: $branch, sessionId: $sessionId}' \
  | curl -s -m 120 -X POST "$API/hooks/turn" \
      -H "authorization: Bearer $TOKEN" \
      -H 'content-type: application/json' \
      --data-binary @- 2>/dev/null)

# ── Bootstrap: a new engagement starts with the repository's own docs ──────
#
# Capture learns from conversations, so a project born from a repository that
# had been worked on for days opened empty while its README and CLAUDE.md sat
# right here. The server says when it wants them — once per project, ever —
# and only then is anything beyond the turn sent.
#
# TRACKED markdown only, via git ls-files: whatever is committed is already
# shared with everyone who can clone it, and an untracked .env or scratch note
# can never be picked up. Bounded per file and in count; the server bounds it
# again.
[ "$(printf '%s' "$RESP" | jq -r '.bootstrap // false' 2>/dev/null)" = "true" ] || exit 0
ROOT=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || true)
[ -n "$ROOT" ] || exit 0

# The docs that say what an engagement IS come first; then the rest of the
# top-level markdown; then one level down (docs/, clients/…).
DOCS=$(git -C "$ROOT" ls-files -- '*.md' '*.MD' 2>/dev/null \
  | awk -F/ 'NF <= 2 && $0 !~ /^\./' \
  | awk '{
      b = tolower($0)
      top = index(b, "/") == 0
      if (top && b ~ /^readme/) p = 0
      else if (b == "claude.md" || b == "agents.md") p = 1
      else if (top && b ~ /^(architecture|overview|design|context)/) p = 2
      else if (top) p = 3
      else p = 4
      print p "\t" $0
    }' \
  | sort -t "$(printf '\t')" -k1,1n -k2,2 \
  | cut -f2- \
  | head -n 12)
[ -n "$DOCS" ] || exit 0

DOCS_JSON=$(printf '%s\n' "$DOCS" | while IFS= read -r f; do
  [ -f "$ROOT/$f" ] || continue
  head -c 8000 "$ROOT/$f" | jq -Rs --arg path "$f" '{path: $path, text: .}'
done | jq -s '.')

COMMITS=$(git -C "$ROOT" log -n 60 --date=short --format='%ad %s' 2>/dev/null | head -c 4000)

jq -n \
  --argjson docs "${DOCS_JSON:-[]}" \
  --arg commits "$COMMITS" \
  --arg cwd "$CWD" \
  --arg gitRemote "$REMOTE" \
  --arg branch "$BRANCH" \
  '{docs: $docs, commits: $commits, cwd: $cwd, gitRemote: $gitRemote, branch: $branch}' \
  | curl -s -m 20 -X POST "$API/hooks/bootstrap" \
      -H "authorization: Bearer $TOKEN" \
      -H 'content-type: application/json' \
      --data-binary @- >/dev/null 2>&1

exit 0
