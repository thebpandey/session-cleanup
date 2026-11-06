#!/usr/bin/env bash
# Builds a fixture repo ./app (with bare remote ./origin.git) full of session leftovers. No lanes state.
set -eu
git init -q --bare origin.git
git init -q -b main app && cd app
git config user.email t@example.com; git config user.name tester
echo "# app" > README.md; printf 'node_modules/\n.next/\n' > .gitignore; git add .; git commit -qm "init"
git remote add origin ../origin.git; git push -q -u origin main
git checkout -qb feat/merged; echo b > b.txt; git add b.txt; git commit -qm "add b"; git checkout -q main
git merge -q --no-ff feat/merged -m "merge feat/merged"
git checkout -qb feat/parser; echo "draft" > parser.js; git add parser.js; git commit -qm "wip: draft parser"; git checkout -q main
git worktree add -q .claude/worktrees/ui -b wt/ui; echo "unsaved" > .claude/worktrees/ui/notes.md
git worktree add -q ../gone-wt -b wt/gone; rm -rf ../gone-wt
echo "tweak" >> README.md; git stash push -q -m "half-done readme tweak"
echo "conflict" > README.md.rej; echo "debug output" > debug.log
echo "API_KEY=fake-not-real" > .env.local
