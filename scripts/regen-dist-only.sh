#!/usr/bin/env bash
#
# Regenerate the `dist-only` branch from `main`.
#
# WHY THIS BRANCH EXISTS
#   Consumers install this fork straight from git (`github:fiddle-factory/
#   deepagentsjs#<sha>`), and npm/pnpm cannot install a package that lives in a
#   monorepo subdirectory. `dist-only` is `libs/deepagents/` promoted to the
#   repo root, with `dist/` committed so the install needs no build step.
#
# WHY A SCRIPT
#   The branch's first commit was made by hand and left no recipe, so the next
#   person to update the pin had to reverse-engineer the transform — with a
#   subtly wrong result shipping as a mysterious runtime failure rather than a
#   build error. Measured before writing this: `git rev-parse main:libs/deepagents`
#   and `git rev-parse dist-only^{tree}` are the SAME tree hash, so there is no
#   transform at all. The branch is exactly a subtree split, and this script is
#   that one command plus the checks that prove it.
#
# USAGE
#   scripts/regen-dist-only.sh [--push]
#
#   Without --push it stops after printing the new sha, so you can inspect the
#   tree before anything leaves the machine.

set -euo pipefail

PREFIX="libs/deepagents"
BRANCH="dist-only"
SOURCE_BRANCH="main"

cd "$(git rev-parse --show-toplevel)"

# 1. The source branch must be committed. A dirty tree would bake whatever is
#    in progress into the artifact a consumer's pin resolves to.
if ! git diff --quiet HEAD -- "$PREFIX"; then
  echo "ERROR: uncommitted changes under $PREFIX. Commit them first —" >&2
  echo "       dist-only must be reproducible from a committed source tree." >&2
  exit 1
fi

CURRENT="$(git rev-parse --abbrev-ref HEAD)"
if [ "$CURRENT" != "$SOURCE_BRANCH" ]; then
  echo "ERROR: on '$CURRENT', expected '$SOURCE_BRANCH'." >&2
  exit 1
fi

# 2. `dist/` is COMMITTED on this branch, so a stale build would ship silently.
#    Rebuild and fail if that produced anything uncommitted.
echo "==> building $PREFIX"
(cd "$PREFIX" && npx tsdown >/dev/null)
if ! git diff --quiet HEAD -- "$PREFIX/dist"; then
  echo "ERROR: the build changed $PREFIX/dist, so the committed dist was stale." >&2
  echo "       Commit the rebuilt dist on $SOURCE_BRANCH, then re-run." >&2
  git --no-pager diff --stat HEAD -- "$PREFIX/dist" >&2
  exit 1
fi

# 3. The split itself. Deterministic: same source tree in, same tree hash out.
echo "==> splitting $PREFIX -> $BRANCH"
SPLIT_SHA="$(git subtree split --prefix="$PREFIX" --branch="$BRANCH" --rejoin=false 2>/dev/null \
  || git subtree split --prefix="$PREFIX" --branch="$BRANCH")"

# 4. Prove the result matches the source subtree exactly. If these ever differ,
#    the branch is no longer a plain split and this script is lying about what
#    it produced — stop rather than push something unexplained.
SRC_TREE="$(git rev-parse "$SOURCE_BRANCH:$PREFIX")"
OUT_TREE="$(git rev-parse "$BRANCH^{tree}")"
if [ "$SRC_TREE" != "$OUT_TREE" ]; then
  echo "ERROR: split tree $OUT_TREE != source subtree $SRC_TREE." >&2
  echo "       dist-only is no longer a plain subtree split; investigate before pushing." >&2
  exit 1
fi

echo
echo "dist-only sha : $SPLIT_SHA"
echo "tree verified : $OUT_TREE (identical to $SOURCE_BRANCH:$PREFIX)"
echo
echo "Pin consumers at: github:fiddle-factory/deepagentsjs#${SPLIT_SHA}"

if [ "${1:-}" = "--push" ]; then
  echo "==> pushing $BRANCH"
  git push origin "$BRANCH"
else
  echo "(dry run — re-run with --push to publish)"
fi
