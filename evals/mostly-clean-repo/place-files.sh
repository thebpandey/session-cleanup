#!/usr/bin/env bash
# Builds a nearly clean fixture repo ./app: one merged branch and a gitignored .next/types cache. Fully pushed.
set -eu
git init -q --bare origin.git
git init -q -b main app && cd app
git config user.email t@example.com; git config user.name tester
echo "# app" > README.md; printf 'node_modules/\n.next/\n' > .gitignore; git add .; git commit -qm "init"
git remote add origin ../origin.git
git checkout -qb fix/typo; echo "# app." > README.md; git commit -qam "fix typo"; git checkout -q main
git merge -q --no-ff fix/typo -m "merge fix/typo"; git push -q -u origin main
mkdir -p .next/types; echo "export {}" > .next/types/routes.d.ts
