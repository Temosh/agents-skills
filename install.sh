#!/usr/bin/env bash
# Install (symlink) the skills in ./skills for Claude Code and/or Codex.
#
#   ./install.sh                     interactive: pick agents with arrows + space
#   ./install.sh --claude --codex    non-interactive
#   ./install.sh --all
#   ./install.sh --uninstall [...]   remove links that point into this repo
#
# Safe to re-run: links are refreshed, links to deleted skills are pruned,
# real (non-symlink) folders are never touched.
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
SKILLS="$REPO/skills"

AGENT_NAMES=("Claude Code" "Codex")
AGENT_DIRS=("${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}" "${CODEX_SKILLS_DIR:-$HOME/.agents/skills}")
AGENT_HOMES=("$HOME/.claude" "$HOME/.codex")
selected=(0 0)
mode=install

if [ -t 1 ]; then
  B=$'\033[1m'; D=$'\033[2m'; G=$'\033[32m'; Y=$'\033[33m'; C=$'\033[36m'; R=$'\033[0m'
else
  B=""; D=""; G=""; Y=""; C=""; R=""
fi

usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

interactive=1
for arg in "$@"; do
  case "$arg" in
    --claude) selected[0]=1; interactive=0 ;;
    --codex) selected[1]=1; interactive=0 ;;
    --all) selected=(1 1); interactive=0 ;;
    --uninstall) mode=uninstall ;;
    -h|--help) usage ;;
    *) echo "unknown option: $arg" >&2; usage 1 ;;
  esac
done

# Checkbox menu: up/down (or k/j) move, space toggles, a = all, enter confirms, q quits.
choose_agents() {
  local cursor=0 n=${#AGENT_NAMES[@]} key rest i
  for i in "${!AGENT_HOMES[@]}"; do
    if [ -d "${AGENT_HOMES[$i]}" ]; then selected[$i]=1; fi   # preselect installed agents
  done

  echo "${B}Which agents should get the skills (${mode})?${R}"
  echo "${D}↑/↓ move · space toggle · a all · enter confirm · q quit${R}"
  tput civis 2>/dev/null || true
  trap 'tput cnorm 2>/dev/null || true' EXIT

  draw() {
    for i in "${!AGENT_NAMES[@]}"; do
      local pointer="  " box="[ ]"
      if [ "$i" -eq "$cursor" ]; then pointer="${C}❯${R} "; fi
      if [ "${selected[$i]}" -eq 1 ]; then box="${G}[x]${R}"; fi
      printf '\033[2K%s%s %s %s\n' "$pointer" "$box" "${AGENT_NAMES[$i]}" "${D}${AGENT_DIRS[$i]/#$HOME/~}${R}"
    done
  }

  draw
  while true; do
    IFS= read -rsn1 key
    case "$key" in
      $'\033') read -rsn2 rest
        case "$rest" in
          "[A") cursor=$(( (cursor - 1 + n) % n )) ;;
          "[B") cursor=$(( (cursor + 1) % n )) ;;
        esac ;;
      k) cursor=$(( (cursor - 1 + n) % n )) ;;
      j) cursor=$(( (cursor + 1) % n )) ;;
      " ") selected[$cursor]=$(( 1 - selected[cursor] )) ;;
      a) if [[ " ${selected[*]} " == *" 0 "* ]]; then selected=(1 1); else selected=(0 0); fi ;;
      q) tput cnorm 2>/dev/null || true; echo "cancelled"; exit 1 ;;
      "") break ;;
    esac
    printf '\033[%dA' "$n"
    draw
  done
  tput cnorm 2>/dev/null || true
  echo
}

# Remove links in $1 that point into this repo's skills/ and whose skill no longer exists
# (or all of them, when uninstalling).
prune_links() {
  local target="$1" link dest
  for link in "$target"/*; do
    [ -L "$link" ] || continue
    dest="$(readlink "$link")"
    case "$dest" in "$SKILLS"/*) ;; *) continue ;; esac
    if [ "$mode" = uninstall ] || [ ! -d "$dest" ]; then
      rm "$link"; echo "  ${Y}removed${R} $(basename "$link")"
    fi
  done
}

link_skills() {
  local target="$1" skill name link
  mkdir -p "$target"
  for skill in "$SKILLS"/*/; do
    [ -f "$skill/SKILL.md" ] || continue
    name="$(basename "$skill")"
    link="$target/$name"
    if [ -e "$link" ] && [ ! -L "$link" ]; then
      echo "  ${Y}skipped${R} $name (a real folder already exists there)"
      continue
    fi
    ln -sfn "${skill%/}" "$link"
    echo "  ${G}linked${R}  $name"
  done
}

if [ "$interactive" -eq 1 ]; then
  [ -t 0 ] || { echo "not a terminal: pass --claude, --codex or --all" >&2; exit 1; }
  choose_agents
fi

any=0
for i in "${!AGENT_NAMES[@]}"; do
  [ "${selected[$i]}" -eq 1 ] || continue
  any=1
  echo "${B}${AGENT_NAMES[$i]}${R} ${D}→ ${AGENT_DIRS[$i]/#$HOME/~}${R}"
  if [ -d "${AGENT_DIRS[$i]}" ]; then prune_links "${AGENT_DIRS[$i]}"; fi
  if [ "$mode" = install ]; then link_skills "${AGENT_DIRS[$i]}"; fi
done
[ "$any" -eq 1 ] || { echo "no agent selected, nothing to do"; exit 0; }
echo "${G}done${R}"
