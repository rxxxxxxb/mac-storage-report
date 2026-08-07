#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║  Mac Storage Report — Full System Overview                      ║
# ║  Scans your Mac, reports what's eating storage, and identifies  ║
# ║  files that are safe to remove.                                 ║
# ╚══════════════════════════════════════════════════════════════════╝

set -euo pipefail

# ── Colors & Formatting ──────────────────────────────────────────────
BOLD="\033[1m"
DIM="\033[2m"
RESET="\033[0m"
RED="\033[1;31m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
MAGENTA="\033[1;35m"
CYAN="\033[1;36m"
WHITE="\033[1;37m"
BG_RED="\033[41m"
BG_GREEN="\033[42m"
BG_BLUE="\033[44m"

# ── Helpers ──────────────────────────────────────────────────────────

# Print a styled section header
header() {
  echo ""
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "${WHITE}  $1${RESET}"
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
}

# Print a sub-section header
subheader() {
  echo ""
  echo -e "  ${CYAN}▸ $1${RESET}"
  echo -e "  ${DIM}──────────────────────────────────────────────────────────${RESET}"
}

# ── Progress indicator ───────────────────────────────────────────────
#
# The disk walk below is the one slow step in the report — a minute or more on a
# full Mac — and nothing can be printed until it finishes. Without a sign of
# life that reads as a hang, so animate a spinner next to the two things `du`
# tells us for free: how many directories it has indexed so far (lines in the
# index file) and where it currently is (the last line).
#
# Only on a terminal. Redirected into a file or a pipe, the escape codes and the
# redrawn line would be noise, so that path falls back to a plain notice.

SPINNER_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')

# Tracked so the cleanup trap can put the cursor back if the report is
# interrupted mid-scan — a hidden cursor outlives the process that hid it.
CURSOR_HIDDEN=0

is_tty() { [ -t 1 ]; }

hide_cursor() {
  printf '\033[?25l'
  CURSOR_HIDDEN=1
}

show_cursor() {
  if [ "$CURSOR_HIDDEN" -eq 1 ]; then
    printf '\033[?25h'
    CURSOR_HIDDEN=0
  fi
}

# Squeeze a path down to its last few components so it fits on the status line:
# "…/Application Support/Google/Chrome"
short_path() {
  LC_ALL=C awk -v p="${1/#$HOME/~}" -v keep=3 'BEGIN {
    n = split(p, part, "/")
    if (n <= keep) { print p; exit }
    out = ""
    for (i = n - keep + 1; i <= n; i++) out = out "/" part[i]
    print "…" out
  }'
}

# Animate the spinner until PID $1 exits, leaving the last frame on screen for
# the next step (or the summary line) to overwrite. Callers only reach this when
# stdout is a terminal.
scan_progress() {
  local pid="$1" frame=0 tick=0 count=0 where="" elapsed width status room trail

  width=$(tput cols 2>/dev/null) || width=80
  case "$width" in '' | *[!0-9]*) width=80 ;; esac

  hide_cursor
  while kill -0 "$pid" 2>/dev/null; do
    # Reading a file that grows to a few megabytes is cheap but not free, and
    # the numbers don't need to change ten times a second — refresh them once
    # per second and just spin in between.
    if [ $((tick % 10)) -eq 0 ] && [ -s "$DU_CACHE_FILE" ]; then
      count=$(wc -l <"$DU_CACHE_FILE" 2>/dev/null | tr -d ' ') || count=0
      where=$(tail -n 1 "$DU_CACHE_FILE" 2>/dev/null | cut -f2-) || where=""
      [ -z "$where" ] || where=$(short_path "$where")
    fi
    elapsed=$((SECONDS - SCAN_START))

    # The same text that gets printed below, uncolored, to measure how much room
    # is left for the path. Below ~12 columns there's nothing worth showing.
    status="  ${SPINNER_FRAMES[$frame]} Scanning disk…  $count folders · ${elapsed}s  "
    room=$((width - ${#status} - 1))
    trail=""
    if [ "$room" -ge 12 ]; then
      trail="$where"
      [ "${#trail}" -le "$room" ] || trail="${trail:0:$room}"
    fi

    # \r returns to the start of the line and \033[K wipes the rest of it, so a
    # shorter path never leaves the tail of a longer one behind.
    printf '\r\033[K  %b%s%b %bScanning disk…%b  %s folders · %ss  %b%s%b' \
      "$CYAN" "${SPINNER_FRAMES[$frame]}" "$RESET" "$WHITE" "$RESET" \
      "$count" "$elapsed" "$DIM" "$trail" "$RESET"

    frame=$(((frame + 1) % ${#SPINNER_FRAMES[@]}))
    tick=$((tick + 1))
    sleep 0.1
  done
  wait "$pid" 2>/dev/null || true
}

# ── du cache ─────────────────────────────────────────────────────────
#
# Measuring a directory means walking every file under it, and this report asks
# about the same trees over and over — ~/Library gets traversed for the Library
# breakdown, again for Application Support, again for Caches, and again for each
# individual cleanup candidate beneath it.
#
# So walk once, up front, and answer every later question from the result. `du`
# has to descend the whole tree to total it either way, so asking it to *print*
# every directory down to CACHE_DEPTH costs essentially nothing beyond the single
# `du -sk` it replaces.
#
# The index lives in a private temp file rather than a shell variable. Holding
# it in a variable was measurably worse: every lookup makes bash re-materialise
# the whole multi-megabyte blob, and 56 of those cost ~7s — more than the walk
# the cache exists to save. From a file the same lookups cost ~0.6s.
DU_CACHE_FILE=""

# 5 is the deepest the report asks about — the CrossOver bottles at
# ~/Library/Application Support/CrossOver/Bottles/<bottle>, the WhatsApp media at
# ~/Library/Group Containers/<group>/Message/Media, and the Docker VM disk at
# ~/Library/Containers/com.docker.docker/Data/vms all sit at depth 5. Going a
# level deeper would nearly double the index for nothing. Anything deeper, or
# outside these roots, simply misses and falls back to du.
CACHE_DEPTH=5

# PID of the walk currently running, so the spinner can watch it and the cleanup
# below can stop it if the report is interrupted mid-scan. SCAN_START anchors
# the elapsed-time counter across both walks.
SCAN_PID=""
SCAN_START=0

# Stops the walk and removes only the temp index created below via mktemp. It
# never touches a path being reported on — the report itself deletes nothing.
cache_cleanup() {
  show_cursor
  if [ -n "$SCAN_PID" ] && kill -0 "$SCAN_PID" 2>/dev/null; then
    # Reaped here, with stderr closed, purely to swallow bash's "Terminated: 15
    # du -kd 5 ..." job notice — noise to someone who just pressed Ctrl-C.
    { kill "$SCAN_PID" && wait "$SCAN_PID"; } 2>/dev/null || true
  fi
  if [ -n "$DU_CACHE_FILE" ] && [ -f "$DU_CACHE_FILE" ]; then
    rm -f -- "$DU_CACHE_FILE"
  fi
}
# INT and TERM exit rather than just cleaning up: a bare `trap handler INT`
# returns to whatever it interrupted, and the report would carry on scanning
# with its index already deleted.
trap cache_cleanup EXIT
trap 'cache_cleanup; exit 130' INT
trap 'cache_cleanup; exit 143' TERM

# Opens the index. Returns non-zero if there's nowhere to write it, in which
# case there's no scan and every lookup falls back to measuring directly.
cache_build_start() {
  DU_CACHE_FILE=$(mktemp -t storage-report) || { DU_CACHE_FILE=""; return 1; }
  SCAN_START=$SECONDS
  is_tty || echo -e "  ${DIM}Scanning disk (one pass, this takes a moment)...${RESET}"
}

# Walk one root ($1) to a given depth ($2) into the index, showing progress.
#
# The `du` is backgrounded on its own rather than inside a `{ ...; } &` group
# covering both roots, because `&` on a group forks a subshell: SCAN_PID would
# be that subshell, and killing it on Ctrl-C would leave its `du` child
# orphaned and still churning the disk. Backgrounded like this, SCAN_PID *is*
# the du. Both walks append, and lookups match on path rather than position, so
# the order they land in doesn't matter.
scan_step() {
  du -kd "$2" "$1" >>"$DU_CACHE_FILE" 2>/dev/null &
  SCAN_PID=$!
  if is_tty; then
    scan_progress "$SCAN_PID"
  else
    wait "$SCAN_PID" 2>/dev/null || true
  fi
  SCAN_PID=""
}

# Replace the spinner with what the scan came back with.
scan_finish() {
  is_tty || return 0
  local count=0
  if [ -s "$DU_CACHE_FILE" ]; then
    count=$(wc -l <"$DU_CACHE_FILE" 2>/dev/null | tr -d ' ') || count=0
  fi
  printf '\r\033[K  %b✓%b %bIndexed %s folders in %ss%b\n' \
    "$GREEN" "$RESET" "$DIM" "$count" "$((SECONDS - SCAN_START))" "$RESET"
  show_cursor
}

# If the index is missing or empty (mktemp failed, du produced nothing), every
# lookup misses and the callers fall back to measuring directly.
cache_ready() {
  [ -n "$DU_CACHE_FILE" ] && [ -s "$DU_CACHE_FILE" ]
}

# Exact-path lookup. Prints the KB count, or nothing on a miss.
cache_lookup() {
  cache_ready || return 0
  LC_ALL=C awk -F'\t' -v p="$1" '$2 == p { print $1; exit }' "$DU_CACHE_FILE"
}

# Emit "kb<TAB>path" for the direct subdirectories of $1, in one pass over the
# index. Used instead of a per-child lookup, which would rescan it N times.
cache_children() {
  cache_ready || return 0
  LC_ALL=C awk -F'\t' -v parent="$1" '
    BEGIN { prefix = parent "/"; n = length(prefix) }
    substr($2, 1, n) == prefix {
      rest = substr($2, n + 1)
      if (index(rest, "/") == 0) print
    }' "$DU_CACHE_FILE"
}

# Get a path's size in KB (0 if the path is missing).
#
# du exits non-zero when it hits a subdirectory it can't read — extremely common
# under ~/Library — but it still prints a total for everything it *could* read.
# Under `set -o pipefail` that non-zero status would kill the script, so swallow
# it and keep the partial number.
get_bytes() {
  local kb=""
  if [ -e "$1" ]; then
    kb=$(cache_lookup "$1")
    if [ -z "$kb" ]; then
      kb=$(du -sk "$1" 2>/dev/null | awk 'NR==1 {print $1}') || true
    fi
  fi
  [ -n "$kb" ] || kb=0
  printf '%s\n' "$kb"
}

# Render a KB count compactly: 1.5G / 340M / 12K
# LC_NUMERIC=C so the decimal separator doesn't follow the user's locale.
human_kb() {
  LC_NUMERIC=C awk -v kb="${1:-0}" 'BEGIN {
    if (kb >= 1048576)   printf "%.1fG\n", kb / 1048576
    else if (kb >= 1024) printf "%.1fM\n", kb / 1024
    else                 printf "%dK\n", kb
  }'
}

# Same, but spelled out for the summary block: 1.5 GB / 340 MB / 12 KB
format_kb() {
  LC_NUMERIC=C awk -v kb="${1:-0}" 'BEGIN {
    if (kb >= 1048576)   printf "%.1f GB\n", kb / 1048576
    else if (kb >= 1024) printf "%.1f MB\n", kb / 1024
    else                 printf "%d KB\n", kb
  }'
}

# Get a path's size as a human-readable string ("0K" if the path is missing)
get_size() {
  human_kb "$(get_bytes "$1")"
}

# Print a row: size + label, with color based on size
print_row() {
  local size="$1"
  local label="$2"
  local kb="${3:-0}"
  local color="$GREEN"

  if [ "$kb" -gt 10485760 ]; then       # > 10 GB
    color="$RED"
  elif [ "$kb" -gt 1048576 ]; then      # > 1 GB
    color="$YELLOW"
  elif [ "$kb" -gt 102400 ]; then       # > 100 MB
    color="$MAGENTA"
  fi

  printf "    ${color}%-10s${RESET} %s\n" "$size" "$label"
}

# Emit "kb<TAB>path" for the largest N direct children of a directory.
#
# Subdirectories come from the cache. Plain files aren't in it — `du -d` only
# reports directories — so they're measured here, which is free: there's nothing
# to recurse into. Hidden entries are included, since du lists them too.
top_children_kb() {
  local count="$1" parent="$2" rows="" files=""

  rows=$(cache_children "$parent")

  if [ -n "$rows" ]; then
    # Cache covered this parent's subdirectories. Add the plain files, which
    # `du -d` never reports.
    files=$(find "$parent" -maxdepth 1 ! -type d -exec du -sk {} + 2>/dev/null || true)
    [ -z "$files" ] || rows=$(printf '%s\n%s' "$rows" "$files")
  else
    # Not covered — outside the walked roots, deeper than CACHE_DEPTH, or the
    # walk failed. Measure the children directly. Deciding this on the *cache*
    # result rather than on the combined result matters: a parent holding files
    # but no cached subdirectories would otherwise list only its files.
    rows=$(du -sk "$parent"/* "$parent"/.[!.]* 2>/dev/null || true)
  fi

  [ -n "$rows" ] || return 0
  printf '%s\n' "$rows" | sort -nr | head -n "$count" || true
}

# Draw a bar of N repeats of a character. A plain loop, because BSD `seq 1 0`
# counts *down* and emits two values rather than none.
bar() {
  local n="${1:-0}" ch="$2" i
  for ((i = 0; i < n; i++)); do
    printf '%s' "$ch"
  done
}

# ── Accumulator for total reclaimable space ──────────────────────────
TOTAL_SAFE_KB=0
TOTAL_CAUTION_KB=0
TOTAL_YOURCALL_KB=0

# ═════════════════════════════════════════════════════════════════════
#  START OF REPORT
# ═════════════════════════════════════════════════════════════════════

echo ""
echo -e "${WHITE}╔══════════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${WHITE}║${RESET}  ${CYAN}${BOLD}   🖥️  Mac Storage Report${RESET}                                     ${WHITE}║${RESET}"
echo -e "${WHITE}║${RESET}  ${DIM}   Generated: $(date '+%Y-%m-%d %H:%M:%S')${RESET}                        ${WHITE}║${RESET}"
echo -e "${WHITE}╚══════════════════════════════════════════════════════════════════╝${RESET}"

# ── 1. Disk Overview ─────────────────────────────────────────────────
header "💾 DISK OVERVIEW"

# On APFS, "/" is the read-only system volume — it reports ~12GB used no matter
# how full the Mac actually is. User data lives on the Data volume, which shares
# the same container, so that's the one to measure.
disk_volume="/System/Volumes/Data"
[ -d "$disk_volume" ] || disk_volume="/"

disk_info=$(df -h "$disk_volume" | tail -1)
disk_total=$(echo "$disk_info" | awk '{print $2}')
disk_used=$(echo "$disk_info" | awk '{print $3}')
disk_avail=$(echo "$disk_info" | awk '{print $4}')
disk_pct=$(echo "$disk_info" | awk '{print $5}')

# Remove the % sign for comparison
pct_num=${disk_pct//%/}
[ -n "$pct_num" ] || pct_num=0
bar_filled=$((pct_num / 2))
bar_empty=$((50 - bar_filled))

bar_color="$GREEN"
if [ "$pct_num" -gt 90 ]; then
  bar_color="$RED"
elif [ "$pct_num" -gt 75 ]; then
  bar_color="$YELLOW"
fi

echo ""
echo -e "    Total: ${WHITE}${disk_total}${RESET}    Used: ${YELLOW}${disk_used}${RESET}    Free: ${GREEN}${disk_avail}${RESET}    Usage: ${bar_color}${disk_pct}${RESET}"
echo -e "    ${DIM}Volume: ${disk_volume}${RESET}"
echo ""
# %b, not %s: the color variables hold literal "\033[..." text, and only %b (or
# a format string, as elsewhere in this script) expands those escapes.
printf '    %b' "$bar_color"
bar "$bar_filled" "█"
printf '%b' "$DIM"
bar "$bar_empty" "░"
echo -e "${RESET}  ${disk_pct}"

# ── Build the du cache ───────────────────────────────────────────────
# The one and only full traversal. Everything from here on is a lookup, so
# announce it — it's the part that takes a while, and it runs before the next
# section can print anything.
echo ""
if cache_build_start; then
  scan_step "$HOME" "$CACHE_DEPTH"
  scan_step /Applications 1
  scan_finish
else
  echo -e "  ${DIM}Could not create a scan index — measuring each section directly.${RESET}"
fi

# ── 2. Home Directory Breakdown ──────────────────────────────────────
header "📁 HOME DIRECTORY BREAKDOWN  (~)"

echo ""

# Collect and sort
while IFS=$'\t' read -r kb path; do
  print_row "$(human_kb "$kb")" "$(basename "$path")" "$kb"
done < <(top_children_kb 15 "$HOME")

# ── 3. ~/Library Breakdown ───────────────────────────────────────────
header "📚 LIBRARY BREAKDOWN  (~/Library)"

echo ""
while IFS=$'\t' read -r kb path; do
  print_row "$(human_kb "$kb")" "$(basename "$path")" "$kb"
done < <(top_children_kb 10 "$HOME/Library")

# ── 4. Application Support ───────────────────────────────────────────
header "📦 APPLICATION SUPPORT  (~/Library/Application Support)"

echo ""
while IFS=$'\t' read -r kb path; do
  print_row "$(human_kb "$kb")" "$(basename "$path")" "$kb"
done < <(top_children_kb 10 "$HOME/Library/Application Support")

# ── 5. Installed Applications ────────────────────────────────────────
header "🚀 INSTALLED APPLICATIONS  (/Applications)"

echo ""
while IFS=$'\t' read -r kb path; do
  print_row "$(human_kb "$kb")" "$(basename "$path")" "$kb"
done < <(top_children_kb 10 "/Applications")

# ── 6. Caches ────────────────────────────────────────────────────────
header "🗑️  CACHES  (~/Library/Caches)"

echo ""
while IFS=$'\t' read -r kb path; do
  print_row "$(human_kb "$kb")" "$(basename "$path")" "$kb"
done < <(top_children_kb 10 "$HOME/Library/Caches")

# ── 7. Developer Tools ──────────────────────────────────────────────
header "🛠️  DEVELOPER TOOLS"

subheader "Xcode"
xcode_dd="$HOME/Library/Developer/Xcode/DerivedData"
xcode_archives="$HOME/Library/Developer/Xcode/Archives"
xcode_simulators="$HOME/Library/Developer/CoreSimulator"
xcode_device_support="$HOME/Library/Developer/Xcode/iOS DeviceSupport"

printf "    %-10s %s\n" "$(get_size "$xcode_dd")" "DerivedData (build cache)"
printf "    %-10s %s\n" "$(get_size "$xcode_archives")" "Archives (exported builds)"
printf "    %-10s %s\n" "$(get_size "$xcode_simulators")" "CoreSimulator (simulator devices)"
printf "    %-10s %s\n" "$(get_size "$xcode_device_support")" "iOS DeviceSupport (device symbols)"

# List simulator runtimes if available
if command -v xcrun &>/dev/null; then
  echo ""
  echo -e "  ${DIM}  Installed Simulator Runtimes:${RESET}"
  # `|| true`: grep exits 1 when no runtimes are installed, and pipefail would
  # otherwise turn that into a fatal error.
  while read -r line; do
    echo -e "    ${DIM}•${RESET} $line"
  done < <(xcrun simctl list runtimes 2>/dev/null | grep -E "^iOS|^watchOS|^tvOS|^visionOS" || true)
fi

subheader "Android"
android_sdk="$HOME/Library/Android/sdk"
printf "    %-10s %s\n" "$(get_size "$android_sdk")" "Android SDK"

subheader "Package Manager Caches"
homebrew_cache="$HOME/Library/Caches/Homebrew"
pip_cache="$HOME/Library/Caches/pip"
npm_cache="$HOME/.npm"
cocoapods_cache="$HOME/Library/Caches/CocoaPods"
gradle_cache="$HOME/.gradle"
cargo_cache="$HOME/.cargo"
go_cache="$HOME/go"
go_build_cache="$HOME/Library/Caches/go-build"
fvm_cache="$HOME/fvm"
yarn_cache="$HOME/Library/Caches/Yarn"
pnpm_store="$HOME/Library/pnpm/store"
uv_cache="$HOME/Library/Caches/uv"

printf "    %-10s %s\n" "$(get_size "$homebrew_cache")" "Homebrew"
printf "    %-10s %s\n" "$(get_size "$pip_cache")" "pip (Python)"
printf "    %-10s %s\n" "$(get_size "$uv_cache")" "uv (Python)"
printf "    %-10s %s\n" "$(get_size "$npm_cache")" "npm (Node.js)"
printf "    %-10s %s\n" "$(get_size "$yarn_cache")" "Yarn (Node.js)"
printf "    %-10s %s\n" "$(get_size "$pnpm_store")" "pnpm store (Node.js)"
printf "    %-10s %s\n" "$(get_size "$cocoapods_cache")" "CocoaPods"
printf "    %-10s %s\n" "$(get_size "$gradle_cache")" "Gradle (Android)"
printf "    %-10s %s\n" "$(get_size "$cargo_cache")" "Cargo (Rust)"
printf "    %-10s %s\n" "$(get_size "$go_cache")" "Go modules"
printf "    %-10s %s\n" "$(get_size "$go_build_cache")" "Go build cache"
printf "    %-10s %s\n" "$(get_size "$fvm_cache")" "FVM (Flutter)"

# ── 8. Browser Data ─────────────────────────────────────────────────
header "🌐 BROWSER DATA"

echo ""
chrome_data="$HOME/Library/Application Support/Google/Chrome"
chrome_cache="$HOME/Library/Caches/Google"
brave_data="$HOME/Library/Application Support/BraveSoftware"
brave_cache="$HOME/Library/Caches/BraveSoftware"
firefox_data="$HOME/Library/Application Support/Firefox"
firefox_cache="$HOME/Library/Caches/Firefox"
edge_data="$HOME/Library/Application Support/Microsoft Edge"
edge_cache="$HOME/Library/Caches/Microsoft Edge"
arc_data="$HOME/Library/Application Support/Arc"
# Safari is sandboxed, so its real bulk sits in the container rather than in
# ~/Library/Safari.
safari_data="$HOME/Library/Containers/com.apple.Safari"

printf "    %-10s %s\n" "$(get_size "$chrome_data")" "Chrome — Profile Data"
printf "    %-10s %s\n" "$(get_size "$chrome_cache")" "Chrome — Cache"
printf "    %-10s %s\n" "$(get_size "$safari_data")" "Safari — Container"
printf "    %-10s %s\n" "$(get_size "$firefox_data")" "Firefox — Profile Data"
printf "    %-10s %s\n" "$(get_size "$firefox_cache")" "Firefox — Cache"
printf "    %-10s %s\n" "$(get_size "$brave_data")" "Brave — Profile Data"
printf "    %-10s %s\n" "$(get_size "$brave_cache")" "Brave — Cache"
printf "    %-10s %s\n" "$(get_size "$edge_data")" "Edge — Profile Data"
printf "    %-10s %s\n" "$(get_size "$edge_cache")" "Edge — Cache"
printf "    %-10s %s\n" "$(get_size "$arc_data")" "Arc — Profile Data"

# ── 9. Media & Downloads ────────────────────────────────────────────
header "🎬 MEDIA & DOWNLOADS"

echo ""
printf "    %-10s %s\n" "$(get_size "$HOME/Movies")" "Movies"
printf "    %-10s %s\n" "$(get_size "$HOME/Music")" "Music"
printf "    %-10s %s\n" "$(get_size "$HOME/Pictures")" "Pictures"
printf "    %-10s %s\n" "$(get_size "$HOME/Downloads")" "Downloads"
printf "    %-10s %s\n" "$(get_size "$HOME/Documents")" "Documents"
printf "    %-10s %s\n" "$(get_size "$HOME/Desktop")" "Desktop"

# ── 10. Messaging Apps ──────────────────────────────────────────────
header "💬 MESSAGING APPS"

echo ""
whatsapp_data="$HOME/Library/Group Containers/group.net.whatsapp.WhatsApp.shared"
whatsapp_media="$HOME/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/Message/Media"
discord_data="$HOME/Library/Application Support/discord"
messenger_data="$HOME/Library/Group Containers/group.com.facebook.Messenger"

printf "    %-10s %s\n" "$(get_size "$whatsapp_data")" "WhatsApp (total)"
printf "    %-10s %s\n" "$(get_size "$whatsapp_media")" "  └─ Media (photos/videos)"
printf "    %-10s %s\n" "$(get_size "$discord_data")" "Discord"
printf "    %-10s %s\n" "$(get_size "$messenger_data")" "Messenger"

# ── 11. Games ────────────────────────────────────────────────────────
header "🎮 GAMES"

echo ""
games_dir="$HOME/Games"
crossover_bottles="$HOME/Library/Application Support/CrossOver/Bottles"

# The "~/Games" here is a label being printed, not a path being resolved — the
# real path is $games_dir above.
# shellcheck disable=SC2088
printf "    %-10s %s\n" "$(get_size "$games_dir")" "~/Games"
if [ -d "$games_dir" ]; then
  while IFS=$'\t' read -r kb path; do
    printf "    %-10s   └─ %s\n" "$(human_kb "$kb")" "$(basename "$path")"
  done < <(top_children_kb 100 "$games_dir")
fi

echo ""
printf "    %-10s %s\n" "$(get_size "$crossover_bottles")" "CrossOver Bottles"
if [ -d "$crossover_bottles" ]; then
  while IFS=$'\t' read -r kb path; do
    printf "    %-10s   └─ %s\n" "$(human_kb "$kb")" "$(basename "$path")"
  done < <(top_children_kb 100 "$crossover_bottles")
fi

# ── 12. macOS System Data ────────────────────────────────────────────
header "🍎 macOS SYSTEM DATA"

echo ""
wallpaper_data="$HOME/Library/Application Support/com.apple.wallpaper"
mobile_docs="$HOME/Library/Mobile Documents"
containers="$HOME/Library/Containers"

printf "    %-10s %s\n" "$(get_size "$wallpaper_data")" "Aerial Wallpapers / Screensavers"
printf "    %-10s %s\n" "$(get_size "$mobile_docs")" "iCloud Drive (Mobile Documents)"
printf "    %-10s %s\n" "$(get_size "$containers")" "App Containers (sandboxed app data)"

# ═════════════════════════════════════════════════════════════════════
#  CLEANUP RECOMMENDATIONS
# ═════════════════════════════════════════════════════════════════════

header "🧹 CLEANUP CANDIDATES"

echo ""
echo -e "  ${DIM}Items are tagged by safety level:${RESET}"
echo -e "    ${BG_GREEN}${WHITE} SAFE ${RESET}      — Cache/temp data. Apps rebuild these automatically."
echo -e "    ${BG_BLUE}${WHITE} CAUTION ${RESET}   — Functional data. Deletion may log you out or require re-setup."
echo -e "    ${BG_RED}${WHITE} YOUR CALL ${RESET}  — Personal/app data. Only you know if you still need it."
echo ""
echo -e "  ${DIM}──────────────────────────────────────────────────────────${RESET}"
echo ""

# Collect all cleanup candidates. This script only ever measures and prints —
# nothing here is deleted, moved, or modified.
declare -a CLEAN_LABELS=()
declare -a CLEAN_SAFETY=()
declare -a CLEAN_BYTES=()

add_item() {
  local path="$1" label="$2" safety="$3"
  if [ -e "$path" ]; then
    local kb
    kb=$(get_bytes "$path")
    if [ "$kb" -gt 10240 ]; then  # Only show items > 10MB
      CLEAN_LABELS+=("$label")
      CLEAN_SAFETY+=("$safety")
      CLEAN_BYTES+=("$kb")

      case "$safety" in
        SAFE)      TOTAL_SAFE_KB=$((TOTAL_SAFE_KB + kb)) ;;
        CAUTION)   TOTAL_CAUTION_KB=$((TOTAL_CAUTION_KB + kb)) ;;
        YOUR_CALL) TOTAL_YOURCALL_KB=$((TOTAL_YOURCALL_KB + kb)) ;;
      esac
    fi
  fi
}

# ── Safe items ───────────────────────────────────────────────────────
add_item "$HOME/Library/Developer/Xcode/DerivedData" \
  "Xcode DerivedData (build cache)" "SAFE"

add_item "$HOME/Library/Caches/Homebrew" \
  "Homebrew download cache" "SAFE"

add_item "$HOME/Library/Caches/Google" \
  "Google Chrome cache" "SAFE"

add_item "$HOME/Library/Caches/com.spotify.client" \
  "Spotify offline cache" "SAFE"

add_item "$HOME/Library/Caches/pip" \
  "pip (Python) package cache" "SAFE"

add_item "$HOME/Library/Caches/BraveSoftware" \
  "Brave Browser cache" "SAFE"

add_item "$HOME/Library/Caches/Firefox" \
  "Firefox cache" "SAFE"

add_item "$HOME/Library/Caches/Microsoft Edge" \
  "Microsoft Edge cache" "SAFE"

add_item "$HOME/.npm" \
  "npm (Node.js) package cache" "SAFE"

add_item "$HOME/Library/Caches/CocoaPods" \
  "CocoaPods cache" "SAFE"

add_item "$HOME/Library/Caches/Steam" \
  "Steam leftover cache" "SAFE"

add_item "$HOME/Library/Caches/ms-playwright" \
  "Playwright browser cache" "SAFE"

add_item "$HOME/Library/Caches/com.codeweavers.CrossOver" \
  "CrossOver cache" "SAFE"

add_item "$HOME/Library/Caches/Yarn" \
  "Yarn (Node.js) package cache" "SAFE"

add_item "$HOME/Library/pnpm/store" \
  "pnpm content-addressable store" "SAFE"

add_item "$HOME/Library/Caches/uv" \
  "uv (Python) package cache" "SAFE"

add_item "$HOME/Library/Caches/go-build" \
  "Go build cache" "SAFE"

add_item "$HOME/Library/Caches/JetBrains" \
  "JetBrains IDE caches" "SAFE"

# Just the caches subdirectory, not all of ~/.gradle — that also holds
# gradle.properties and signing config, which are not reproducible.
add_item "$HOME/.gradle/caches" \
  "Gradle build cache" "SAFE"

add_item "$HOME/.cargo/registry" \
  "Cargo (Rust) registry cache" "SAFE"

# Deleting this by hand fights the read-only permissions Go sets on it; the
# supported way is `go clean -modcache`.
add_item "$HOME/go/pkg/mod" \
  "Go module cache" "SAFE"

# ── Caution items ────────────────────────────────────────────────────
add_item "$HOME/Library/Developer/CoreSimulator" \
  "iOS Simulators (all devices)" "CAUTION"

add_item "$HOME/Library/Developer/Xcode/iOS DeviceSupport" \
  "Xcode iOS DeviceSupport symbols" "CAUTION"

add_item "$HOME/Library/Application Support/com.apple.wallpaper" \
  "macOS Aerial Wallpapers" "CAUTION"

add_item "$HOME/Library/Application Support/Notion/Partitions" \
  "Notion offline data" "CAUTION"

add_item "$HOME/Library/Application Support/Claude/vm_bundles" \
  "Claude Desktop VM bundles" "CAUTION"

add_item "$HOME/Library/Application Support/Claude/Cache" \
  "Claude Desktop cache" "CAUTION"

add_item "$HOME/Library/Application Support/Cursor/CachedData" \
  "Cursor IDE cached data" "CAUTION"

add_item "$HOME/Library/Application Support/Code/CachedData" \
  "VS Code cached data" "CAUTION"

add_item "$HOME/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/Message/Media" \
  "WhatsApp cached media" "CAUTION"

# Model weights: deleting costs a multi-gigabyte re-download, not real data loss.
add_item "$HOME/.cache/huggingface" \
  "Hugging Face model cache" "CAUTION"

# Docker Desktop keeps images and volumes inside one big VM disk image. Deleting
# it drops every local image, container, and volume — `docker system prune` is
# the finer-grained tool.
add_item "$HOME/Library/Containers/com.docker.docker/Data/vms" \
  "Docker Desktop VM disk (images/volumes)" "CAUTION"

add_item "$HOME/fvm" \
  "FVM Flutter SDK versions" "CAUTION"

# ── Your Call items ──────────────────────────────────────────────────
add_item "$HOME/Library/Android/sdk" \
  "Android SDK (needed for Android dev)" "YOUR_CALL"

add_item "$HOME/Games" \
  "Games folder" "YOUR_CALL"

add_item "$HOME/Library/Application Support/CrossOver/Bottles" \
  "CrossOver Bottles (Windows apps/games)" "YOUR_CALL"

add_item "$HOME/.ollama/models" \
  "Ollama local LLM weights" "YOUR_CALL"

# Often the single largest folder on a Mac, and the only copy of an iPhone if
# the owner doesn't use iCloud backup — hence YOUR_CALL rather than CAUTION.
add_item "$HOME/Library/Application Support/MobileSync/Backup" \
  "iPhone/iPad local backups" "YOUR_CALL"

# Print all items sorted by size
echo -e "  ${BOLD}#   Size       Item                                          Safety${RESET}"
echo -e "  ${DIM}──────────────────────────────────────────────────────────────────────${RESET}"

# Guard every array expansion below: under bash 3.2 (what macOS ships) `set -u`
# treats "${arr[@]}" on an empty array as an unbound variable and aborts.
if [ "${#CLEAN_BYTES[@]}" -eq 0 ]; then
  echo -e "    ${DIM}Nothing over 10 MB found in the usual cleanup locations.${RESET}"
else
  # Create index array and sort by size (descending)
  indices=()
  for i in "${!CLEAN_BYTES[@]}"; do
    indices+=("$i")
  done

  for ((i = 0; i < ${#indices[@]}; i++)); do
    for ((j = i + 1; j < ${#indices[@]}; j++)); do
      if [ "${CLEAN_BYTES[${indices[$j]}]}" -gt "${CLEAN_BYTES[${indices[$i]}]}" ]; then
        tmp="${indices[$i]}"
        indices[i]="${indices[$j]}"
        indices[j]="$tmp"
      fi
    done
  done

  count=1
  for idx in "${indices[@]}"; do
    label="${CLEAN_LABELS[$idx]}"
    safety="${CLEAN_SAFETY[$idx]}"
    size="$(human_kb "${CLEAN_BYTES[$idx]}")"

    tag=""
    case "$safety" in
      SAFE)      tag="${BG_GREEN}${WHITE} SAFE ${RESET}" ;;
      CAUTION)   tag="${BG_BLUE}${WHITE} CAUTION ${RESET}" ;;
      YOUR_CALL) tag="${BG_RED}${WHITE} YOUR CALL ${RESET}" ;;
    esac

    printf "  ${BOLD}%-3s${RESET} %-10s %-45s %b\n" "$count." "$size" "$label" "$tag"
    count=$((count + 1))
  done
fi

# ── Summary ──────────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${WHITE}  💰 POTENTIAL SAVINGS SUMMARY${RESET}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
echo -e "    ${BG_GREEN}${WHITE} SAFE ${RESET}      items:  ${GREEN}$(format_kb $TOTAL_SAFE_KB)${RESET}  — caches apps rebuild on their own"
echo -e "    ${BG_BLUE}${WHITE} CAUTION ${RESET}   items:  ${YELLOW}$(format_kb $TOTAL_CAUTION_KB)${RESET}  — recoverable, but may require re-login or re-download"
echo -e "    ${BG_RED}${WHITE} YOUR CALL ${RESET}  items:  ${RED}$(format_kb $TOTAL_YOURCALL_KB)${RESET}  — personal/app data, not counted as reclaimable"
echo ""
total_kb=$((TOTAL_SAFE_KB + TOTAL_CAUTION_KB))
echo -e "    ${WHITE}Total reclaimable (SAFE + CAUTION):  $(format_kb $total_kb)${RESET}"
echo ""

# ── Footer ──────────────────────────────────────────────────────────
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
echo -e "  ${DIM}This is a read-only report. It measures disk usage and prints it —${RESET}"
echo -e "  ${DIM}it never deletes, moves, or modifies anything. Review the items${RESET}"
echo -e "  ${DIM}above and remove whatever you choose to, yourself.${RESET}"
echo ""
