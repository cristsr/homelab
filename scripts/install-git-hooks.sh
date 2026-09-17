#!/bin/sh
#
# Points git at the versioned .githooks/ directory.
#
# core.hooksPath lives in .git/config, which is never cloned, so this has to be
# run once per fresh clone. It is idempotent, safe to re-run.
#
set -eu

cd "$(git rev-parse --show-toplevel)"
git config core.hooksPath .githooks
chmod +x .githooks/*

printf 'OK  core.hooksPath -> .githooks\n'
printf 'OK  hooks: %s\n' "$(ls .githooks | tr '\n' ' ')"
