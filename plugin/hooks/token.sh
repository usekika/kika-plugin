#!/usr/bin/env bash
#
# Finding the one credential, shared by every Kika hook.
#
# Lifted out of capture.sh when a second hook needed it. Two copies of a
# credential search is two copies that drift, and the one that drifts is the one
# nobody notices — a hook that silently finds no token looks exactly like a hook
# with nothing to say.
#
# Sourced, not executed. Sets TOKEN, empty when there is nothing to find.
# Callers must treat empty as "exit quietly": an uninstalled or unauthenticated
# setup has to cost nothing and say nothing.
#
# Usage:  CWD=<dir> API=<url> . "$(dirname "$0")/token.sh"

# ── The token: ONE credential, the one you already pasted ──────────────────
#
# You configured the MCP server with a token. Asking for a second one — an env
# var, a dotfile — for the half of the product that runs three seconds later is
# friction we invented, not friction the design requires. So this reads the
# Authorization header out of the MCP configuration itself.
#
# The result is that the whole install is one command:
#
#   claude mcp add --transport http kika https://api.getkika.app/mcp \
#     --header "Authorization: Bearer kika_mcp_…"
#
# Looked for in the order Claude Code resolves MCP servers: a project .mcp.json
# first, then the per-project section of ~/.claude.json, then the global one.
# The cwd may be a subdirectory of the project root, so parents are walked.
# Where Claude Code keeps its files. CLAUDE_CONFIG_DIR moves all of it —
# settings, history, plugins — and a hook that hardcodes ~/.claude finds nothing
# for anyone who has set it. On Windows ~/.claude is %USERPROFILE%\.claude, so
# the same path works there under Git Bash.
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# Say why nothing happened, when asked. Capture is silent by design — a hook
# that complains after every message gets disabled within a day — but silence
# also means someone whose capture never fires has no way to find out. This is
# the way out, and it goes to stderr so it can never contaminate a hook whose
# stdout is injected as context.
kika_debug() { [ -n "${KIKA_DEBUG:-}" ] && printf 'kika: %s\n' "$1" >&2; return 0; }

token_from_mcp() {
  local f dir
  # A committed project config, if the team shares one.
  for dir in "${CLAUDE_PROJECT_DIR:-$CWD}" "$CWD"; do
    [ -n "$dir" ] || continue
    f="$dir/.mcp.json"
    if [ -r "$f" ]; then
      jq -r '.mcpServers.kika.headers.Authorization // empty' "$f" 2>/dev/null && return
    fi
  done

  # Also relocatable, so try the configured directory before $HOME.
  for f in "$CONFIG_DIR/.claude.json" "$HOME/.claude.json"; do
    [ -r "$f" ] && break
  done
  [ -r "$f" ] || return
  # Per-project, walking up from the working directory.
  dir="$CWD"
  while [ -n "$dir" ] && [ "$dir" != "/" ]; do
    jq -r --arg d "$dir" '.projects[$d].mcpServers.kika.headers.Authorization // empty' "$f" 2>/dev/null       | grep . && return
    dir=$(dirname "$dir")
  done
  # Global.
  jq -r '.mcpServers.kika.headers.Authorization // empty' "$f" 2>/dev/null
}

# Connected over OAuth instead? Then there is no header to read — but Claude
# Code is holding a live access token for this very server, and keeps it
# refreshed. Using it means OAuth users get capture with no second credential
# either, which is the difference between "capture works" and "capture works if
# you also went and made a token".
#
# The token is OURS: our authorization server issued it, for our resource, to
# this user. Reading it is not reaching into somebody else's secret.
#
# Matched on the serverUrl, OR on the entry key naming this server. The key
# carries a hash suffix (`kika|2df240d1…`) so only its name part is compared.
# Both, because either alone is brittle: a self-hosted or staging API breaks a
# URL-only match, and a server the user named something else breaks a key-only
# one.
token_from_oauth() {
  # Initialised, because under `set -u` an unset local is a crash, and this one
  # stays unset on any Linux box without a credentials file — there is no
  # keychain to fall back to, so neither branch below runs. Verified in a
  # container: the hook died with "raw: unbound variable" on exactly the
  # machines the platform note claimed to support.
  local raw=""
  # The portable store first; the macOS keychain second. Neither existing is
  # normal and must stay silent.
  if [ -r "$CONFIG_DIR/.credentials.json" ]; then
    raw=$(cat "$CONFIG_DIR/.credentials.json" 2>/dev/null)
  elif command -v security >/dev/null 2>&1; then
    raw=$(security find-generic-password -s 'Claude Code-credentials' -w 2>/dev/null)
  fi
  [ -n "$raw" ] || return
  printf '%s' "$raw" | jq -r --arg api "$API" '
    (.mcpOAuth // {})
    | to_entries
    | map(select(
        ((.value.serverUrl // "") | startswith($api))
        # The key is "kika|<hash>" for a server added by hand and
        # "plugin:kika:kika|<hash>" for one the plugin installed, so compare
        # the last colon-separated part of the name, not the whole of it.
        or ((.key | split("|")[0] | ascii_downcase | split(":") | last) == "kika")
      ))
    # Expired tokens are skipped rather than sent: Claude Code refreshes on its
    # own schedule, so the next turn will find a live one.
    | map(select((.value.expiresAt // 0) > (now * 1000)))
    | .[0].value.accessToken // empty' 2>/dev/null
}

# Where the token came from, so a caller can tell a sign-in that renews itself
# (oauth) from a key on disk, and knows which file to drop if it is rejected.
HOOKS_KEY_FILE="$HOME/.kika/hooks-key"
TOKEN="${KIKA_TOKEN:-}"
TOKEN_SOURCE=env
if [ -z "$TOKEN" ]; then
  # Strip the scheme: the config holds "Bearer kika_mcp_…", we want the token.
  TOKEN=$(token_from_mcp | head -1 | sed -E 's/^[Bb]earer[[:space:]]+//' | tr -d '[:space:]')
  TOKEN_SOURCE=header
fi
if [ -z "$TOKEN" ]; then
  TOKEN=$(token_from_oauth | tr -d '[:space:]')
  TOKEN_SOURCE=oauth
fi
# Last resort, and now genuinely a last resort.
if [ -z "$TOKEN" ] && [ -r "$HOME/.kika/token" ]; then
  TOKEN=$(tr -d '[:space:]' < "$HOME/.kika/token")
  TOKEN_SOURCE=file
fi
# The capture hooks' own key, fetched by session-start.sh while the OAuth
# sign-in still worked. It is what keeps capture alive after the hour: the OAuth
# access token expires and only the agent renews it, which the hooks cannot.
if [ -z "$TOKEN" ] && [ -r "$HOOKS_KEY_FILE" ]; then
  TOKEN=$(tr -d '[:space:]' < "$HOOKS_KEY_FILE")
  TOKEN_SOURCE=hooks-key
fi
[ -z "$TOKEN" ] && TOKEN_SOURCE=""

kika_debug "config dir: $CONFIG_DIR"
if [ -n "$TOKEN" ]; then
  kika_debug "found a token (${#TOKEN} chars, from $TOKEN_SOURCE)"
else
  kika_debug "NO token — looked at: \$KIKA_TOKEN, the Authorization header on the kika MCP server in $CONFIG_DIR/.claude.json and .mcp.json, the OAuth token in $CONFIG_DIR/.credentials.json (and the macOS keychain), $HOME/.kika/token and $HOOKS_KEY_FILE"
fi
