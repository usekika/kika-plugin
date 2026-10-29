#!/usr/bin/env bash
#
# Where this engagement stands, before you type anything.
#
# The MCP handshake tells the agent to call get_brief at the start of a session.
# Measured on real use: across 54 captured turns it called it eight times. So
# most sessions began blind on an engagement whose entire point is that you
# should not have to start blind — and the user never knew the difference,
# because a memory that goes unread looks exactly like a memory that is empty.
#
# A SessionStart hook does not depend on remembering. Claude Code injects a
# hook's stdout as session context, so this prints the standup and the agent
# simply has it.
#
# Silent whenever there is nothing to say: no repository, a repository nobody
# has an engagement for, or an engagement with nothing in it yet. A hook that
# prints noise at the top of every session is a hook that gets uninstalled.
#
# NOT silent when capture is off. It used to be: no token, exit 0. On
# 2026-10-29 a user found five weeks of one engagement missing — the plugin had
# not been able to authenticate, every hook exited quietly, and a memory that is
# not being written looks exactly like a memory with nothing new in it. So a
# missing or rejected credential is said out loud, once a day, in every
# directory, because it is the one state the user cannot see and can fix.
#
# Runs with async: true, so a slow reply never delays the session starting.

set -uo pipefail

INPUT=$(cat)
API="${KIKA_API_URL:-https://api.getkika.app}"

command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""')
[ -n "$CWD" ] && [ -d "$CWD" ] || exit 0

# Capture is off, and the user should know. Once a day per machine: often
# enough that weeks cannot pass unnoticed, rare enough not to be noise. Shown to
# the user (systemMessage) and handed to the agent (additionalContext), which
# is asked to pass it on — whichever of the two this client surfaces.
capture_off() {
  local mark="$HOME/.kika/warned-signed-out" today
  today=$(date +%Y-%m-%d)
  [ "$(cat "$mark" 2>/dev/null)" = "$today" ] && exit 0
  mkdir -p "$HOME/.kika" 2>/dev/null && printf '%s' "$today" > "$mark" 2>/dev/null
  local msg="Kika is not signed in ($1), so nothing from this session will be remembered. Run /mcp and reconnect kika."
  jq -n --arg msg "$msg" '{
    systemMessage: $msg,
    hookSpecificOutput: {
      hookEventName: "SessionStart",
      additionalContext: ("Tell the user this in one line at the start of your first reply, then carry on: " + $msg)
    }
  }'
  exit 0
}

# shellcheck source=token.sh
. "$(dirname "${BASH_SOURCE[0]}")/token.sh"
[ -z "$TOKEN" ] && capture_off "no credential found"

# A sign-in that works again clears the daily mark, so the next time it breaks
# is reported the same day rather than tomorrow.
signed_in() { rm -f "$HOME/.kika/warned-signed-out" 2>/dev/null; }

# The capture hooks' own key. An OAuth access token lives an hour and only the
# agent renews it, so capture used to stop an hour into any session where the
# agent did not happen to call Kika. While this sign-in is fresh, ask for a
# capture-only key and keep it (see token.sh). Once per machine; the server
# refuses it for anything but the hooks. A pasted key or ~/.kika/token never
# expires within a session, so only the OAuth path needs it.
if [ "$TOKEN_SOURCE" = "oauth" ] && [ ! -s "$HOOKS_KEY_FILE" ]; then
  KEY=$(curl -s -m 8 -X POST "$API/hooks/key" \
    -H "authorization: Bearer $TOKEN" 2>/dev/null | jq -r '.token // empty' 2>/dev/null)
  if [ -n "$KEY" ]; then
    ( umask 077 && mkdir -p "$HOME/.kika" \
      && printf '%s' "$KEY" > "$HOOKS_KEY_FILE.tmp" \
      && mv "$HOOKS_KEY_FILE.tmp" "$HOOKS_KEY_FILE" ) 2>/dev/null
  fi
fi

# The engagement is identified by the repository, exactly as capture does it.
# Outside a repository there is nothing to resolve and nothing to say.
REMOTE=$(git -C "$CWD" remote get-url origin 2>/dev/null || true)
[ -n "$REMOTE" ] || exit 0

# Short timeout on purpose. This is decoration on a session that is starting,
# not something worth waiting for — if Kika is slow or down, the session begins
# without it and nobody is told about a problem they cannot act on. A REJECTED
# credential is different: that one they can act on.
OUT=$(curl -s -m 12 -G "$API/hooks/brief" -w '\n%{http_code}' \
  --data-urlencode "repo=$REMOTE" \
  -H "authorization: Bearer $TOKEN" 2>/dev/null || true)
CODE=$(printf '%s' "$OUT" | tail -n 1)
BRIEF=$(printf '%s' "$OUT" | sed '$d')
case "$CODE" in
  401)
    # A revoked or expired hooks key is dropped, so the next fresh sign-in
    # fetches another instead of this one failing every turn.
    [ "$TOKEN_SOURCE" = "hooks-key" ] && rm -f "$HOOKS_KEY_FILE"
    capture_off "the key was rejected" ;;
  2*) signed_in ;;
  *) BRIEF="" ;;
esac

# Plain stdout is injected as context. Nothing to say → say nothing.
[ -n "$BRIEF" ] && printf '%s\n' "$BRIEF"
exit 0
