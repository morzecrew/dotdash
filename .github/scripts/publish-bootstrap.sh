#!/usr/bin/env bash
# Publish scripts/bootstrap.sh at the gh-pages root, beside mike's version
# directories, as https://morzecrew.github.io/dotdash/bootstrap.sh. A version
# directory is the wrong home: the script prepares a server, whatever docs
# version a reader is on. mike leaves other files at the root alone, so the
# workflow that owns the root runs this after each deploy: docs-release for the
# newest release, docs-dev until there is one.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
work=$(mktemp -d)
trap 'git worktree remove --force "$work" >/dev/null 2>&1 || true' EXIT

git fetch -q --no-tags origin gh-pages
git worktree add -q --detach "$work" origin/gh-pages
install -m 0755 scripts/bootstrap.sh "$work/bootstrap.sh"
cd "$work"

# Staged first: `git diff` says nothing about an untracked file, so on the
# first run it would report "unchanged" and publish nothing.
git add bootstrap.sh
if git diff --cached --quiet; then
	echo "bootstrap.sh at the site root is already these bytes"
	exit 0
fi
git commit -qm "🔧 chore(docs): publish bootstrap.sh at the site root"
git push -q origin HEAD:gh-pages
echo "published bootstrap.sh at the site root"
