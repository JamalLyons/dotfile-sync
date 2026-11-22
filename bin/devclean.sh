#!/usr/bin/env bash
# devclean: clean common developer junk/caches.
#   devclean.sh              dry run: show what would be freed (default, deletes nothing)
#   devclean.sh --run        actually clean
#   devclean.sh --run --yes  also clean "risky" targets (Trash, all simulators)
#
# ADD A TARGET: add one line in the TARGETS section below.
#   add_path  "label" "path"      empty the contents of path (folder kept)
#   add_glob  "label" "pattern"   like add_path, for every match of a glob (e.g. */target)
#   add_cmd   "label" "command"   run the tool's own cleanup (first word must exist)
#   add_risky "label" "path"      like add_path, but only runs with --yes
#   add_risky_cmd "label" "cmd"   like add_cmd, but only runs with --yes

set -uo pipefail
shopt -s nullglob

RUN=0
YES=0
for arg in "$@"; do
  case "$arg" in
    --run) RUN=1 ;;
    --yes) YES=1 ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

TYPES=()
LABELS=()
TARGETS=()

add_path()      { TYPES+=("path");       LABELS+=("$1"); TARGETS+=("$2"); }
add_glob()      { TYPES+=("glob");       LABELS+=("$1"); TARGETS+=("$2"); }
add_cmd()       { TYPES+=("cmd");        LABELS+=("$1"); TARGETS+=("$2"); }
add_risky()     { TYPES+=("risky");      LABELS+=("$1"); TARGETS+=("$2"); }
add_risky_cmd() { TYPES+=("risky_cmd");  LABELS+=("$1"); TARGETS+=("$2"); }

# ===================== TARGETS (add lines here) =====================
# Xcode
add_path  "Xcode DerivedData"        "$HOME/Library/Developer/Xcode/DerivedData"
add_cmd   "Simulators (unavailable)" "xcrun simctl delete unavailable"
add_risky_cmd "Simulators (ALL)"     "xcrun simctl delete all"

# Package managers / build caches
add_cmd   "Homebrew cache"           "brew cleanup -s"
add_cmd   "npm cache"                "npm cache clean --force"
add_cmd   "pnpm store (unused)"      "pnpm store prune"
add_path  "Gradle caches"            "$HOME/.gradle/caches"
add_path  "Cargo registry cache"     "$HOME/.cargo/registry/cache"
add_path  "Dart analysis server"     "$HOME/.dartServer"

# T3 worktree build output (source checkouts are NOT touched)
add_glob  "T3 ferros target/"        "$HOME/.t3/worktrees/ferros/*/target"
add_glob  "T3 dotfile-sync build/"   "$HOME/.t3/worktrees/dotfile-sync/*/build"
add_glob  "T3 node_modules"          "$HOME/.t3/worktrees/*/*/node_modules"

# App caches (only the cache folders, never app data)
add_path  "Spotify cache"            "$HOME/Library/Caches/com.spotify.client"
add_path  "Brave cache"              "$HOME/Library/Caches/BraveSoftware"
add_path  "t3code updater cache"     "$HOME/Library/Caches/t3code-updater"

# Risky: needs --yes
add_risky "Trash"                    "$HOME/.Trash"

# Examples (uncomment to use):
# add_path "Example cache" "$HOME/.cache/some-tool"
# add_cmd  "Docker prune"  "docker system prune -f"
# ====================================================================

# ---------- engine ----------
bytes_of() { [[ -e "$1" ]] && du -sk "$1" 2>/dev/null | awk '{print $1}' || echo 0; }

human() { awk -v k="$1" 'BEGIN{ split("KB MB GB TB",u); i=1; while(k>=1024 && i<4){k/=1024;i++} printf "%.1f%s", k, u[i] }'; }

is_safe_path() {
  local p="$1"
  [[ -n "$p" && "$p" == "$HOME"/* && "$p" != "$HOME" && "$p" != "/" ]]
}

clean_path() {
  local p="$1"
  is_safe_path "$p" || { echo "    refused: unsafe path $p"; return 1; }
  [[ -d "$p" ]] || { echo "    skip: not found"; return 0; }
  find "$p" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
}

# expand a glob pattern into MATCHES (array)
expand_glob() {
  local pat="$1"
  MATCHES=( $pat )   # unquoted on purpose: glob expansion
}

total_kb=0
mode=$( ((RUN)) && echo RUN || echo DRY-RUN )
echo "devclean $mode$( ((YES)) && echo ' (+risky)')"
echo

for i in "${!TARGETS[@]}"; do
  type="${TYPES[$i]}"; label="${LABELS[$i]}"; target="${TARGETS[$i]}"

  if [[ ( "$type" == "risky" || "$type" == "risky_cmd" ) && $YES -eq 0 ]]; then
    printf '%-28s skipped (risky, needs --yes)\n' "$label"
    continue
  fi

  if [[ "$type" == "cmd" || "$type" == "risky_cmd" ]]; then
    bin="${target%% *}"
    if ! command -v "$bin" >/dev/null 2>&1; then
      printf '%-28s skip: %s not installed\n' "$label" "$bin"
      continue
    fi
    if (( RUN )); then
      printf '%-28s running: %s\n' "$label" "$target"
      bash -c "$target" >/dev/null 2>&1 || echo "    warning: command exited non-zero"
    else
      printf '%-28s would run: %s\n' "$label" "$target"
    fi
    continue
  fi

  if [[ "$type" == "glob" ]]; then
    expand_glob "$target"
    if (( ${#MATCHES[@]} == 0 )); then
      printf '%-28s nothing matched\n' "$label"
      continue
    fi
    kb=0
    for m in "${MATCHES[@]}"; do kb=$((kb + $(bytes_of "$m"))); done
    total_kb=$((total_kb + kb))
    if (( RUN )); then
      printf '%-28s cleaning %d dirs (%s)\n' "$label" "${#MATCHES[@]}" "$(human "$kb")"
      for m in "${MATCHES[@]}"; do clean_path "$m"; done
    else
      printf '%-28s %8s  %d dirs\n' "$label" "$(human "$kb")" "${#MATCHES[@]}"
    fi
    continue
  fi

  # path / risky (path)
  kb=$(bytes_of "$target")
  total_kb=$((total_kb + kb))
  if (( RUN )); then
    printf '%-28s cleaning %s (%s)\n' "$label" "$target" "$(human "$kb")"
    clean_path "$target"
  else
    printf '%-28s %8s  %s\n' "$label" "$(human "$kb")" "$target"
  fi
done

echo
if (( RUN )); then
  echo "done. approx freed: $(human "$total_kb") (path/glob targets only)"
else
  echo "dry run. approx reclaimable: $(human "$total_kb") (path/glob targets only, commands not sized)"
  echo "re-run with --run to clean."
fi
df -h / | tail -1 | awk '{print "disk free now: " $4 " of " $2}'
