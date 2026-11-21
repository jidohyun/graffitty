#!/bin/sh
# Build a small, real repository before any of the interactive shells start.
set -eu
demo=$1
fixture=$2
mkdir -p "$demo/src" "$demo/docs"
cd "$demo"
git init -q -b main
git config user.name 'Demo'
git config user.email 'demo@example.invalid'
git config commit.gpgsign false
git config core.hooksPath /dev/null
printf '# Workspace demo\n' > README.md
git add README.md
git commit -qm 'Create workspace'
cp "$fixture/main.py" src/main.py
git add src/main.py
git commit -qm 'Add source watcher'
printf '\nWatch Python source files.\n' >> README.md
printf 'Workspace plan\n\nKeep related work together.\nNotes, images, and a terminal.\n' > docs/notes.txt
for media in layout.png layout.pdf video.webm; do
  cp "$fixture/$media" "docs/$media"
done
git add README.md docs
git commit -qm 'Document the workflow'
printf '\nReady for the next change.\n' >> README.md
