#!/usr/bin/env bash
# Claude Code statusline: repo | branch | model | effort | context | 5h | 7d
#
# Reads the statusline JSON payload on stdin (schema per Claude Code 2.1.220)
# and prints one line. The payload is re-rendered on a 300ms debounce, so the
# whole script must stay cheap: exactly one jq call, at most two git calls.
#
# Requires bash 4+ (for ${var^}), jq, and a 24-bit-colour terminal. git is
# optional: without it the repo and branch cells are simply absent.
#
# Install: save as ~/.claude/statusline-command.sh and add to settings.json
#
#   "statusLine": { "type": "command", "command": "bash ~/.claude/statusline-command.sh" }
#
# Tunables: CTX_ALERT_PCT, the c_* colour block, MIN_BAR_WIDTH/MAX_BAR_WIDTH.

set -u

if ! command -v jq >/dev/null 2>&1; then
  # Every field is derived from the JSON payload, so without jq there is
  # nothing to show. Say so rather than printing a silently empty line.
  printf 'statusline: jq not found\n'
  exit 0
fi

input="$(cat)"

# One jq call for every field. Joined on US (0x1f) rather than a tab: bash
# treats tab as IFS whitespace and collapses runs of it, which would silently
# shift every field left whenever an optional one is absent.
fields="$(printf '%s' "$input" | jq -r '
  [
    (.workspace.repo.name // ""),
    (.workspace.current_dir // .cwd // ""),
    (.workspace.project_dir // ""),
    (.model.display_name // ""),
    (.model.id // ""),
    (.effort.level // ""),
    (.context_window.used_percentage // ""),
    (.rate_limits.five_hour.used_percentage // ""),
    (.rate_limits.five_hour.resets_at // ""),
    (.rate_limits.seven_day.used_percentage // "")
  ] | map(tostring) | join("\u001f")' 2>/dev/null)"

IFS=$'\x1f' read -r repo_name cwd project_dir model_name model_id effort_level \
  ctx_pct h5_pct h5_reset d7_pct <<< "$fields"

[ -z "${cwd:-}" ] && cwd="$PWD"

# Drop the parenthetical qualifier from the model name ("Opus 5 (1M context)"
# -> "Opus 5"); the window size is already implied by the ctx meter.
model_name="${model_name%% (*}"

# display_name is not always versioned: the CLI reports Fable 5.1 as plain
# "Fable", and older payloads omit the field altogether. Whenever the name
# carries no digit, derive it from the id ("claude-fable-5-1[1m]",
# "claude-haiku-4-5-20251001"): family capitalised, version dotted, context
# flag and date dropped.
if [[ "$model_name" != *[0-9]* && "$model_id" == claude-* ]]; then
  model_id="${model_id#claude-}"
  model_id="${model_id%%\[*}"
  family="${model_id%%-*}"
  version="${model_id#"$family"}"
  version="${version#-}"
  version="${version%-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]}"
  version="${version//-/.}"
  model_name="${family^}${version:+ $version}"
fi

# Colors. Dim, because the status line renders on a dim background.
c_reset=$'\033[0m'
c_repo=$'\033[2;36m'    # dim cyan
c_branch=$'\033[2;32m'  # dim green
c_model=$'\033[2;35m'   # dim magenta
c_effort=$'\033[2;34m'  # dim blue
c_dim=$'\033[2;37m'
# Light red, deliberately outside the meter gradient (which tops out at a
# darker 220,0,0) so "context nearly full" reads as a different state, not
# just "high".
c_alert=$'\033[38;2;255;85;85m'
sep=$' \033[2m|\033[0m '

# Used only if the terminal size cannot be read (see detect_cols).
FALLBACK_COLS=113
# The status line is rendered inside a padded container, so the usable width is
# narrower than the terminal. Budgeting against the raw width overflows by
# exactly this much and the tail gets truncated.
PADDING_COLS=4
# Never squeeze the two names below this combined width, even if that means
# overflowing; a line of pure ellipses helps nobody.
MIN_NAME_BUDGET=6

detect_cols() {
  # Sets TERM_COLS. stdout is a pipe here, but the status line runs as a child
  # of the CLI, which owns the session's controlling terminal — so /dev/tty
  # resolves and carries the real winsize. Deliberately NOT `tput cols`: with
  # stdout on a pipe it silently returns the terminfo default (80) instead of
  # failing, which would quietly mis-budget the line on every other width.
  # The braces matter: without them the shell's own "no such device" complaint
  # about the failed redirection escapes to stderr when there is no tty.
  local sz cols
  sz="$( { stty size </dev/tty; } 2>/dev/null )"
  cols="${sz##* }"
  case "$cols" in ''|*[!0-9]*) cols="" ;; esac
  if [ -z "$cols" ] || [ "$cols" -le 0 ]; then
    cols="${COLUMNS:-}"
    case "$cols" in ''|*[!0-9]*) cols="" ;; esac
  fi
  if [ -z "$cols" ] || [ "$cols" -le 0 ]; then cols="$FALLBACK_COLS"; fi
  cols=$(( cols - PADDING_COLS ))
  [ "$cols" -lt 1 ] && cols=1
  TERM_COLS="$cols"
}

# Column widths are accumulated as the line is built rather than recovered by
# stripping SGR escapes afterwards: bash's extglob substitution needed to do
# that measured ~40ms per render, more than the rest of the script combined.

truncate_tail() {
  # truncate_tail <string> <max> — repo names are distinguished by their prefix.
  # The max<=1 guards matter: ${s:0:-1} would mean "all but the last character".
  [ "${#1}" -le "$2" ] && { printf '%s' "$1"; return; }
  [ "$2" -le 0 ] && return
  [ "$2" -eq 1 ] && { printf '…'; return; }
  printf '%s…' "${1:0:$(($2 - 1))}"
}

truncate_middle() {
  # truncate_middle <string> <max> — branch names carry meaning at both ends
  # ("feat/" vs "fix/" up front, the ticket or topic at the back), so drop the
  # middle instead of either end.
  local s="$1" max="$2" head tail
  [ "${#s}" -le "$max" ] && { printf '%s' "$s"; return; }
  [ "$max" -le 1 ] && { printf '…'; return; }
  head=$(( max / 2 ))
  tail=$(( max - 1 - head ))
  if [ "$tail" -le 0 ]; then printf '%s…' "${s:0:$((max - 1))}"; else printf '%s…%s' "${s:0:head}" "${s: -tail}"; fi
}

allocate_names() {
  # Split NAME_BUDGET between the two names. Whichever is shorter keeps its
  # full length and donates the remainder, so a short branch ("main") buys
  # room for a long repo name and vice versa; only if both exceed their half
  # is the budget split evenly.
  local rl=${#repo_name} bl=${#branch} half
  if [ $(( rl + bl )) -le "$NAME_BUDGET" ]; then
    repo_max=$rl; branch_max=$bl; return
  fi
  half=$(( NAME_BUDGET / 2 ))
  if [ "$rl" -le "$half" ]; then
    repo_max=$rl; branch_max=$(( NAME_BUDGET - rl ))
  elif [ "$bl" -le "$half" ]; then
    branch_max=$bl; repo_max=$(( NAME_BUDGET - bl ))
  else
    repo_max=$half; branch_max=$(( NAME_BUDGET - half ))
  fi
}

# Derive the repo name from git when the payload omits it.
if [ -z "${repo_name:-}" ]; then
  # --git-common-dir, not --show-toplevel: inside a linked worktree the latter
  # returns the worktree path, so the repo would be named after the worktree.
  common_dir="$(git --no-optional-locks -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  if [ -n "$common_dir" ]; then
    case "$(basename "$common_dir")" in
      .git) repo_name="$(basename "$(dirname "$common_dir")")" ;;  # normal checkout
      *)    repo_name="$(basename "${common_dir%.git}")" ;;        # bare repo
    esac
  else
    repo_name="$(basename "${project_dir:-$cwd}")"
  fi
fi

# Resolved from cwd, not project_dir: inside a git worktree those differ, and
# project_dir would report the branch of the original checkout.
branch=""
if git --no-optional-locks -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch="$(git --no-optional-locks -C "$cwd" branch --show-current 2>/dev/null)"
  # Detached HEAD: show the short commit sha instead.
  [ -z "$branch" ] && branch="$(git --no-optional-locks -C "$cwd" rev-parse --short HEAD 2>/dev/null)"
fi

# Context window and both rate limits share one renderer, so the gradient and
# glyphs stay identical across the line. Meters start at MIN and are widened
# later only into columns the names did not need — see the overflow handling
# at the end of the script.
# Past ~10 cells the extra resolution stops being readable at a glance.
MIN_BAR_WIDTH=5
MAX_BAR_WIDTH=10
BAR_WIDTH=$MIN_BAR_WIDTH

render_meter() {
  # render_meter <label> <percent> <width> [override_color]
  #   -> "label ███░░░ 42%" coloured on a green -> yellow -> red gradient.
  # override_color repaints the whole cell (label, bar, percentage) in one
  # colour, for states the gradient cannot express. Empty if percent is unusable.
  local label="$1" pct="$2" width="$3" ovr="${4:-}"
  local calc r g b pct_fmt filled empty color bar_filled="" bar_empty="" i
  local lbl_color lbl_reset fill_color empty_color pct_color
  METER_STR=""; METER_LEN=0
  calc="$(awk -v p="$pct" -v width="$width" 'BEGIN {
    if (p < 0) p = 0
    if (p > 100) p = 100
    if (p <= 50) {
      t = p / 50
      r = 46  + t * (230 - 46)
      g = 160 + t * (200 - 160)
      b = 67  + t * (0   - 67)
    } else {
      t = (p - 50) / 50
      r = 230 + t * (220 - 230)
      g = 200 + t * (0   - 200)
      b = 0
    }
    printf "%d %d %d %.0f %d", r, g, b, p, int(p / 100 * width + 0.5)
  }' 2>/dev/null)"
  read -r r g b pct_fmt filled <<< "$calc"
  [ -z "${r:-}" ] && return
  color=$'\033[38;2;'"${r};${g};${b}"'m'
  empty=$(( width - filled ))
  [ "$empty" -lt 0 ] && empty=0
  for ((i = 0; i < filled; i++)); do bar_filled+="█"; done
  for ((i = 0; i < empty; i++)); do bar_empty+="░"; done
  if [ -n "$ovr" ]; then
    # Label is reset explicitly; the bar's two halves inherit the open colour.
    lbl_color="$ovr"; lbl_reset="$c_reset"
    fill_color="$ovr"; empty_color=""; pct_color="$ovr"
  else
    # No reset after an uncoloured label — it would clear the dim attribute
    # the status line container applies to the whole row.
    lbl_color=""; lbl_reset=""
    fill_color="$color"; empty_color="$c_dim"; pct_color="$color"
  fi
  printf -v METER_STR '%s%s%s %s%s%s%s%s %s%s%%%s' \
    "$lbl_color" "$label" "$lbl_reset" \
    "$fill_color" "$bar_filled" "$empty_color" "$bar_empty" "$c_reset" \
    "$pct_color" "$pct_fmt" "$c_reset"
  # Plain form is "label ███░░ 42%": label + space + bar + space + digits + '%'
  METER_LEN=$(( ${#label} + 1 + width + 1 + ${#pct_fmt} + 1 ))
}

# Past this share of the window the whole ctx cell is repainted in c_alert
# rather than relying on the bar's own colour. Compared in awk: the payload
# may carry a fractional percentage.
CTX_ALERT_PCT=50
ctx_alert=""
if [ -n "${ctx_pct:-}" ] && awk -v p="$ctx_pct" -v t="$CTX_ALERT_PCT" 'BEGIN { exit !(p >= t) }' 2>/dev/null; then
  ctx_alert="$c_alert"
fi

format_reset() {
  # format_reset <resets_at> -> "1h20m" / "45m" remaining, empty if unusable.
  # resets_at may be an ISO-8601 string or an epoch in seconds or milliseconds.
  local raw="$1" target now delta h m
  case "$raw" in
    ''|null) return ;;
    *[!0-9]*) target="$(date -d "$raw" +%s 2>/dev/null)" ;;
    *) target="$raw"; [ "${#raw}" -ge 12 ] && target=$(( raw / 1000 )) ;;
  esac
  [ -z "${target:-}" ] && return
  now="$(date +%s)"
  delta=$(( target - now ))
  [ "$delta" -le 0 ] && return
  h=$(( delta / 3600 ))
  m=$(( (delta % 3600) / 60 ))
  if [ "$h" -gt 0 ]; then printf '%dh%02dm' "$h" "$m"; else printf '%dm' "$m"; fi
}

# Resolved once: format_reset costs two date calls and does not depend on width.
reset_in=""
[ -n "${h5_pct:-}" ] && reset_in="$(format_reset "${h5_reset:-}")"

render_all_meters() {
  # Renders all three meters at the current BAR_WIDTH. Safe to call twice.
  ctx_str=""; ctx_len=0
  if [ -n "${ctx_pct:-}" ]; then
    render_meter "ctx" "$ctx_pct" "$BAR_WIDTH" "$ctx_alert"
    ctx_str="$METER_STR"; ctx_len=$METER_LEN
  fi

  h5_str=""; h5_len=0
  if [ -n "${h5_pct:-}" ]; then
    render_meter "5h" "$h5_pct" "$BAR_WIDTH"
    h5_str="$METER_STR"; h5_len=$METER_LEN
    if [ -n "$h5_str" ] && [ -n "$reset_in" ]; then
      h5_str="${h5_str} ${c_dim}↻ ${reset_in}${c_reset}"
      h5_len=$(( h5_len + 3 + ${#reset_in} ))  # " ↻ " plus the duration
    fi
  fi

  d7_str=""; d7_len=0
  if [ -n "${d7_pct:-}" ]; then
    render_meter "7d" "$d7_pct" "$BAR_WIDTH"
    d7_str="$METER_STR"; d7_len=$METER_LEN
  fi

  METER_COUNT=0
  [ -n "$ctx_str" ] && METER_COUNT=$(( METER_COUNT + 1 ))
  [ -n "$h5_str" ]  && METER_COUNT=$(( METER_COUNT + 1 ))
  [ -n "$d7_str" ]  && METER_COUNT=$(( METER_COUNT + 1 ))
}

render_all_meters

build_line() {
  # build_line <repo_display> <branch_display> -> sets LINE and LINE_LEN
  local r="$1" b="$2" parts=() lens=() i n
  [ -n "$r" ] && { parts+=("${c_repo}${r}${c_reset}");          lens+=("${#r}"); }
  [ -n "$b" ] && { parts+=("${c_branch}${b}${c_reset}");        lens+=("${#b}"); }
  [ -n "${model_name:-}" ]   && { parts+=("${c_model}${model_name}${c_reset}");    lens+=("${#model_name}"); }
  [ -n "${effort_level:-}" ] && { parts+=("${c_effort}${effort_level}${c_reset}"); lens+=("${#effort_level}"); }
  [ -n "$ctx_str" ] && { parts+=("$ctx_str"); lens+=("$ctx_len"); }
  [ -n "$h5_str" ]  && { parts+=("$h5_str");  lens+=("$h5_len"); }
  [ -n "$d7_str" ]  && { parts+=("$d7_str");  lens+=("$d7_len"); }
  LINE=""; LINE_LEN=0
  n=${#parts[@]}
  for (( i = 0; i < n; i++ )); do
    if [ "$i" -eq 0 ]; then
      LINE="${parts[i]}"; LINE_LEN=${lens[i]}
    else
      LINE="${LINE}${sep}${parts[i]}"; LINE_LEN=$(( LINE_LEN + 3 + lens[i] ))
    fi
  done
}

# Budget the names from what the line actually measures rather than from a
# hardcoded overhead: this self-corrects for model name length, three-digit
# percentages, a missing reset time or absent rate limits.
repo_disp="$repo_name"; branch_disp="$branch"
build_line "$repo_disp" "$branch_disp"
detect_cols
overflow=$(( LINE_LEN - TERM_COLS ))

if [ "$overflow" -gt 0 ]; then
  # Too wide: buy the space back from the names, exactly the deficit.
  NAME_BUDGET=$(( ${#repo_name} + ${#branch} - overflow ))
  [ "$NAME_BUDGET" -lt "$MIN_NAME_BUDGET" ] && NAME_BUDGET=$MIN_NAME_BUDGET
  allocate_names
  repo_disp="$(truncate_tail "$repo_name" "$repo_max")"
  branch_disp="$(truncate_middle "$branch" "$branch_max")"
  build_line "$repo_disp" "$branch_disp"
elif [ "$overflow" -lt 0 ] && [ "${METER_COUNT:-0}" -gt 0 ] && [ "$BAR_WIDTH" -lt "$MAX_BAR_WIDTH" ]; then
  # Room to spare: widen the meters into it. Names are already whole here, so
  # this never trades a readable name for bar resolution — it only spends
  # columns nothing else claimed. Each extra cell costs one column per meter.
  grow=$(( -overflow / METER_COUNT ))
  if [ "$grow" -gt 0 ]; then
    BAR_WIDTH=$(( BAR_WIDTH + grow ))
    [ "$BAR_WIDTH" -gt "$MAX_BAR_WIDTH" ] && BAR_WIDTH=$MAX_BAR_WIDTH
    render_all_meters
    build_line "$repo_disp" "$branch_disp"
  fi
fi

printf '%s\n' "$LINE"
