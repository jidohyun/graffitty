#!/bin/sh
# Package a release: run the tests, then build a checksummed tarball.
set -eu
version=${1:?usage: ./release.sh VERSION}
name="bistro-orders-$version"
printf '\033[1m==> Running tests\033[0m\n'
python3 -m unittest 2>&1 | tail -n 3
printf '\033[1m==> Packaging %s\033[0m\n' "$name"
mkdir -p dist
tar -czf "dist/$name.tar.gz" --exclude dist --exclude logs --exclude .git --exclude '__pycache__' \
  -s "#^\.#$name#" .
ls -lh "dist/$name.tar.gz" | awk '{print "    " $5 "  " $9}'
printf '\033[1m==> Checksum\033[0m\n'
(cd dist && shasum -a 256 "$name.tar.gz" | tee "$name.tar.gz.sha256" | sed 's/^/    /')
printf '\033[1;32m==> %s is ready to deploy\033[0m\n' "$name"
