#!/usr/bin/env bash
# Keep this fork current with pingdotgg/t3code.
#
#   main  is a pure mirror of upstream main (fast-forward only, never commit here).
#   fork  is the fork's integration branch: upstream main + fork-only changes.
#
# Usage: scripts/fork/sync-upstream.sh [--push] [--rebase]
#   --push    push main and fork to origin after a successful sync
#   --rebase  rebase fork onto main instead of merging main into fork
#
# Exit codes: 0 synced, 2 merge/rebase conflict (worktree left for you to resolve).
set -euo pipefail

UPSTREAM_REPO="${UPSTREAM_REPO:-pingdotgg/t3code}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-main}"
MIRROR_BRANCH="${MIRROR_BRANCH:-main}"
FORK_BRANCH="${FORK_BRANCH:-fork}"

push=0
mode=merge
for arg in "$@"; do
  case "$arg" in
    --push) push=1 ;;
    --rebase) mode=rebase ;;
    *) echo "unknown argument: $arg" >&2; exit 1 ;;
  esac
done

root="$(git rev-parse --show-toplevel)"
cd "$root"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "worktree is dirty; commit or stash first" >&2
  exit 1
fi

if ! git remote get-url upstream >/dev/null 2>&1; then
  git remote add upstream "https://github.com/${UPSTREAM_REPO}.git"
fi

git fetch --quiet upstream "$UPSTREAM_BRANCH"
git fetch --quiet origin "$MIRROR_BRANCH" "$FORK_BRANCH" || true

start_branch="$(git rev-parse --abbrev-ref HEAD)"

# 1. Mirror upstream into main. Refuse anything that is not a fast-forward:
#    main must never carry fork commits.
git checkout --quiet "$MIRROR_BRANCH"
if ! git merge --ff-only --quiet "upstream/${UPSTREAM_BRANCH}"; then
  echo "${MIRROR_BRANCH} has diverged from upstream/${UPSTREAM_BRANCH}; it must stay a mirror." >&2
  echo "Fix: git branch -f ${MIRROR_BRANCH} upstream/${UPSTREAM_BRANCH} (after moving any stray commits to ${FORK_BRANCH})." >&2
  git checkout --quiet "$start_branch"
  exit 1
fi
mirror_sha="$(git rev-parse --short HEAD)"

# 2. Bring upstream into the integration branch.
git checkout --quiet "$FORK_BRANCH"
if [[ "$mode" == rebase ]]; then
  if ! git rebase --quiet "$MIRROR_BRANCH"; then
    echo "rebase conflict; resolve, then: git rebase --continue && git push --force-with-lease origin ${FORK_BRANCH}" >&2
    exit 2
  fi
else
  if ! git merge --no-edit --quiet "$MIRROR_BRANCH" -m "chore(fork): merge upstream ${UPSTREAM_BRANCH} @ ${mirror_sha}"; then
    echo "merge conflict; resolve, then: git commit && git push origin ${FORK_BRANCH}" >&2
    exit 2
  fi
fi

echo "synced: ${MIRROR_BRANCH} -> upstream/${UPSTREAM_BRANCH} @ ${mirror_sha}; ${FORK_BRANCH} ${mode}d"

if [[ "$push" == 1 ]]; then
  git push --quiet origin "${MIRROR_BRANCH}:${MIRROR_BRANCH}"
  if [[ "$mode" == rebase ]]; then
    git push --quiet --force-with-lease origin "${FORK_BRANCH}:${FORK_BRANCH}"
  else
    git push --quiet origin "${FORK_BRANCH}:${FORK_BRANCH}"
  fi
  echo "pushed ${MIRROR_BRANCH} and ${FORK_BRANCH} to origin"
fi

git checkout --quiet "$start_branch"
