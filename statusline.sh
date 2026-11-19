#!/bin/bash
# Claude Code status line: caches plan usage for the menu bar app, prints a one-line summary.
# Runs locally on each redraw — nothing here is sent to the model or uses tokens.
input=$(cat)
cache="$HOME/.claude/usage-cache.json"

# Merge this redraw's rate limits into the cache. Claude Code drops a window once it resets, so windows
# missing from this redraw are kept from the existing cache — Gauge shows them as reset (0%).
# Runs under a lock (see below), so concurrent sessions can't overwrite each other's merge.
if [ "$1" = "--update-cache" ]; then
  old=$(jq -c 'if type == "object" then . else {} end' "$cache" 2>/dev/null) || old='{}'
  [ -n "$old" ] || old='{}'
  tmp=$(mktemp "$cache.XXXXXX") || exit 0
  # Another Claude Code session may redraw with older numbers (redraws also happen without a new
  # API response). Usage within a window only goes up, so per window: a later reset time means a
  # newer window and wins; for the same window the higher percentage wins.
  # updated_at only moves forward when this redraw brings a *new API response* (the session's
  # total_api_duration_ms grew since we last saw it) and its numbers aren't older than what's cached.
  # `seen` remembers the last value per session (most recent 20 sessions).
  if echo "$input" | jq --argjson old "$old" '
      def newer(a; b):
        if a == null then b elif b == null then a
        elif b.resets_at > a.resets_at then b
        elif b.resets_at < a.resets_at then a
        elif b.used_percentage >= a.used_percentage then b else a end;
      ($old.rate_limits // {}) as $prev
      | (.rate_limits | {five_hour, seven_day} | with_entries(select(.value != null))) as $incoming
      | ([$incoming | to_entries[] | newer($prev[.key]; .value) == .value] | all) as $current
      | (.session_id // "unknown") as $sid
      | (.cost.total_api_duration_ms // 0) as $api
      | (($old.seen // {}) | if type == "object" then . else {} end) as $seen
      | ($api > ($seen[$sid] // -1)) as $newResponse
      | ($current and $newResponse) as $advance
      | {
          rate_limits: ([ "five_hour", "seven_day" ]
                        | map({ key: ., value: newer($prev[.]; $incoming[.]) })
                        | map(select(.value != null)) | from_entries),
          model: (if $advance or ($old.model == null) then .model.display_name else $old.model end),
          updated_at: (if $advance or ($old.updated_at == null) then (now | floor) else $old.updated_at end),
          seen: ($seen | del(.[$sid]) | . + { ($sid): $api } | to_entries | .[-20:] | from_entries)
        }' > "$tmp"; then
    mv "$tmp" "$cache"
  else
    rm -f "$tmp"
  fi
  exit 0
fi

# Update the cache only when this redraw carries at least one rate limit window, so a fresh session
# (no API response yet) doesn't wipe good data. lockf (built into macOS) holds a lock for the whole
# read-merge-write; if another session holds it for over 2s, skip this update.
if echo "$input" | jq -e '(.rate_limits // {}) | has("five_hour") or has("seven_day")' >/dev/null 2>&1; then
  echo "$input" | lockf -k -t 2 "$cache.lock" "$0" --update-cache 2>/dev/null
fi

# Terminal width (Claude Code sets COLUMNS). Lower-priority parts are dropped until the line fits.
cols=${COLUMNS:-200}

echo "$input" | jq -r --argjson cols "$cols" '
  def pct(w): if w then "\(w.used_percentage | floor)%" else "–" end;
  def dur(ms): (ms / 1000 | floor) as $s
    | if $s >= 3600 then "\($s / 3600 | floor)h\(($s % 3600) / 60 | floor)m" else "\($s / 60 | floor)m" end;
  def line(k): map(.[k] // .text) | join(" · ");
  # drop = 0 means always kept; otherwise the highest number goes first.
  # If only the kept parts are left and it still does not fit, switch them to their short labels.
  def fit: if (line("text") | length) <= ($cols - 2) then line("text")
           elif all(.drop == 0) then line("short")
           else (map(.drop) | max) as $d | map(select(.drop != $d)) | fit end;

  [
    { drop: 1, text: .model.display_name },

    # how full this conversation is
    (.context_window.used_percentage | if . then { drop: 0, text: "ctx \(floor)%", short: "ctx \(floor)%" } else empty end),

    # plan limits: 5-hour session window and 7-day window
    { drop: 0,
      text: "session \(pct(.rate_limits.five_hour)), week \(pct(.rate_limits.seven_day))",
      short: "5h \(pct(.rate_limits.five_hour)) 7d \(pct(.rate_limits.seven_day))" },

    # lines of code changed this session
    (.cost | if .total_lines_added then { drop: 3, text: "+\(.total_lines_added)/−\(.total_lines_removed)" } else empty end),

    # how long the session has been open, and how much of that Claude spent working
    (.cost | if .total_duration_ms then { drop: 4, text: "open \(dur(.total_duration_ms)) (\(dur(.total_api_duration_ms)) working)" } else empty end),

    # prompt cache on the Anthropic side: share of input tokens served from the cache
    (.prompt_cache | if . == null then empty
      elif .warm then { drop: 2, text: "cache \(.hit_ratio * 100 | floor)%" }
      else { drop: 2, text: "cache cold" } end)
  ] | fit'
