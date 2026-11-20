#!/usr/bin/env bash
# git-sync.sh  pull|push  —  best-effort auto-sync of this shared workspace with origin/<branch>.
#
# OPTIONAL. Only does anything once you add a git remote (see onboarding.md). Until a remote exists
# it exits 0 quietly, so it is safe to wire before you have a repo.
#
# Typical wiring (any agent harness that supports session hooks):
#   session-start -> git-sync.sh pull   (everyone starts on the latest knowledge)
#   session-stop  -> git-sync.sh push   (each session's changes are shared)
#
# DESIGN GOALS (do not weaken):
#   * NEVER block or hang the session. GIT_TERMINAL_PROMPT=0 -> auth prompts fail fast, not hang.
#   * NEVER force-push and NEVER clobber. Integrate with --rebase --autostash; on a real conflict,
#     stop and warn so a human resolves it — losing a teammate's edit is worse than a failed sync.
#   * Degrade gracefully offline / with no remote / before `git init` (just exit 0 quietly).
#
# Repo root is auto-detected: the AGENT_PROJECT_DIR env var if set (point your harness at the repo
# root), else CLAUDE_PROJECT_DIR for Claude Code, else two levels up from this script.
set -uo pipefail
export GIT_TERMINAL_PROMPT=0          # never hang on a credential prompt in a non-interactive hook

DIR="${AGENT_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}}"
cd "$DIR" 2>/dev/null || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0   # not a repo yet -> nothing to do
git remote get-url origin            >/dev/null 2>&1 || exit 0   # no remote yet -> nothing to do

BRANCH="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || echo main)"
note(){ echo "[git-sync] $*"; }

case "${1:-}" in
  pull)
    if git pull --rebase --autostash origin "$BRANCH" >/dev/null 2>&1; then
      note "up to date with origin/$BRANCH."
    else
      # Markdown/logs auto-keep-both via the union merge driver (.gitattributes), so a surviving
      # conflict is a code/config file that can't be safely auto-merged.
      conflicts="$(git diff --name-only --diff-filter=U 2>/dev/null | paste -sd', ' -)"
      git rebase --abort >/dev/null 2>&1
      if [ -n "$conflicts" ]; then
        note "CONFLICT needing review (code/config): $conflicts"
        note "  Markdown auto-keeps both sides; these don't. NOTHING was deleted — your local"
        note "  commits and origin/$BRANCH are both intact. Resolve keeping both sides, then re-sync."
      else
        note "WARNING: could not pull origin/$BRANCH (offline?). Working tree left as-is; you may not have the latest."
      fi
    fi
    ;;

  push)
    git add -A >/dev/null 2>&1
    if git diff --cached --quiet 2>/dev/null; then
      : # nothing changed this turn — still try to fast-forward below in case teammates pushed
    else
      who="$(git config user.name 2>/dev/null || echo agent)"
      git commit -m "kb: auto-sync ($who) $(date '+%Y-%m-%d %H:%M:%S%z')" >/dev/null 2>&1 \
        && note "committed local changes."
    fi
    # Integrate teammates' work before pushing; never force. Markdown/logs auto-keep-both (union).
    if ! git pull --rebase --autostash origin "$BRANCH" >/dev/null 2>&1; then
      conflicts="$(git diff --name-only --diff-filter=U 2>/dev/null | paste -sd', ' -)"
      git rebase --abort >/dev/null 2>&1
      if [ -n "$conflicts" ]; then
        note "CONFLICT (code/config, needs review): $conflicts — NOT pushing, nothing deleted."
        note "  Resolve keeping both sides, then re-sync. Your commit is safe locally; origin unchanged."
      else
        note "WARNING: offline/rebase failed — NOT pushing. Changes are committed locally; will retry next time."
      fi
      exit 0
    fi
    if git push origin "$BRANCH" >/dev/null 2>&1; then
      note "pushed to origin/$BRANCH."
    else
      note "WARNING: push failed (offline or auth). Changes are committed locally; will push next time."
    fi
    ;;

  *) note "usage: git-sync.sh pull|push" ;;
esac
exit 0
