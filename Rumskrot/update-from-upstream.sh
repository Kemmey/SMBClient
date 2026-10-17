#!/bin/bash
# Rebuild Dansk Rumskrot's SMBClient patch series on top of an upstream
# revision, or regenerate the patch files from the branch you are on.
#
#   Rumskrot/update-from-upstream.sh [options] [<upstream-ref>]
#       Fetch kishikawakatsumi/SMBClient, create rumskrot/<label> at
#       <upstream-ref> (a tag or commit; default: upstream/main), commit this
#       tooling on it, apply Rumskrot/patches/*.patch with `git am --3way`,
#       build, test, and print the revision for Navigator to pin.
#
#   Rumskrot/update-from-upstream.sh --continue
#       After resolving a conflict that stopped `git am` (or dropping a patch
#       upstream has merged with `git am --skip`): finish applying, build,
#       test, print the pin.
#
#   Rumskrot/update-from-upstream.sh --export
#       Regenerate Rumskrot/patches/ from the commits on the current branch
#       (everything after the recorded base except "Rumskrot tooling:"
#       commits). Run it after editing, adding or dropping a patch, then
#       commit the result as "Rumskrot tooling: regenerate patches".
#
# Options:
#   --latest-tag     use upstream's newest version tag instead of upstream/main
#   --branch <name>  build into <name> instead of rumskrot/<label>
#   --integration    also run upstream's Samba-backed suites (needs
#                    `docker-compose up` from upstream's README)
#   -h, --help       this text
#
# The branch for a given upstream base is built once and never rewritten:
# a new upstream base gets a new branch name, so every revision Navigator
# has ever pinned stays reachable without a force-push. Re-running against
# a base that already has a branch only checks it out, builds and tests it.

set -euo pipefail

UPSTREAM_URL="https://github.com/kishikawakatsumi/SMBClient.git"
OFFLINE_TESTS="ResponseFuzzTests|MalformedServerTests|CryptoTests"
TOOLING_PREFIX="Rumskrot tooling:"

repo_root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$repo_root"

usage() { sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; }
die() { printf 'update-from-upstream: %s\n' "$*" >&2; exit 1; }
say() { printf '==> %s\n' "$*"; }

require_clean_tree() {
  git diff --quiet && git diff --cached --quiet \
    || die "the working tree has uncommitted changes; commit or remove them first"
}

recorded_base() {
  [[ -f Rumskrot/UPSTREAM ]] || die "Rumskrot/UPSTREAM is missing; is this a rumskrot/* branch?"
  sed -n 's/^commit //p' Rumskrot/UPSTREAM
}

build_and_test() {
  local integration=$1
  say "swift build"
  swift build
  if [[ "$integration" == 1 ]]; then
    say "swift test (all suites, Samba container required)"
    swift test
  else
    say "swift test --filter '$OFFLINE_TESTS'"
    swift test --filter "$OFFLINE_TESTS"
  fi
}

print_pin() {
  local branch revision
  branch=$(git rev-parse --abbrev-ref HEAD)
  revision=$(git rev-parse HEAD)
  cat <<EOF

Branch:   $branch
Revision: $revision

Publish it (never force; the branch is new for each upstream base):
  git push origin $branch

Then pin it in RumskrotNavigator's Packages/NavigatorSMB/Package.swift:
  .package(url: "https://github.com/Kemmey/SMBClient.git", revision: "$revision")
and run: xcodebuild -resolvePackageDependencies (see Rumskrot/README.md).
EOF
}

export_patches() {
  local base commits n=0
  base=$(recorded_base)
  git cat-file -e "$base^{commit}" 2>/dev/null || die "recorded base $base is not in this clone; git fetch upstream"
  require_clean_tree

  commits=()
  while IFS= read -r commit; do
    subject=$(git log -1 --format=%s "$commit")
    [[ "$subject" == "$TOOLING_PREFIX"* ]] && continue
    if git diff-tree --no-commit-id --name-only -r "$commit" | grep -q '^Rumskrot/'; then
      die "patch commit $(git log -1 --format='%h %s' "$commit") touches Rumskrot/; keep tooling out of patches"
    fi
    commits+=("$commit")
  done < <(git rev-list --reverse "$base..HEAD")

  [[ ${#commits[@]} -gt 0 ]] || die "no patch commits between $base and HEAD"

  rm -f Rumskrot/patches/*.patch
  mkdir -p Rumskrot/patches
  for commit in "${commits[@]}"; do
    n=$((n + 1))
    git format-patch -1 --quiet --zero-commit --no-signature --start-number "$n" \
      -o Rumskrot/patches "$commit"
  done

  say "wrote $n patches to Rumskrot/patches/"
  if git status --porcelain -- Rumskrot/patches | grep -q .; then
    echo "They changed. Commit them:"
    echo "  git add Rumskrot/patches && git commit -m '$TOOLING_PREFIX regenerate patches'"
  else
    echo "They are identical to the committed series."
  fi
}

continue_series() {
  local integration=$1
  if [[ -d "$(git rev-parse --git-path rebase-apply)" ]]; then
    say "git am --continue"
    git am --continue || die "git am could not continue; resolve the conflict (or git am --skip a patch upstream already merged) and run --continue again"
  fi
  require_clean_tree
  build_and_test "$integration"
  print_pin
}

rebuild_series() {
  local ref=$1 branch=$2 integration=$3 latest_tag=$4
  local base label tooling patches

  require_clean_tree
  [[ -d "$(git rev-parse --git-path rebase-apply)" ]] \
    && die "a git am is in progress; finish it with --continue or abort it with git am --abort"

  if ! git remote get-url upstream >/dev/null 2>&1; then
    say "adding remote upstream -> $UPSTREAM_URL"
    git remote add upstream "$UPSTREAM_URL"
  fi
  say "git fetch upstream --tags"
  git fetch --quiet upstream --tags

  if [[ "$latest_tag" == 1 ]]; then
    ref=$(git tag --list --sort=-version:refname | head -n 1)
    [[ -n "$ref" ]] || die "upstream has no tags"
  fi
  ref=${ref:-upstream/main}
  base=$(git rev-parse --verify --quiet "$ref^{commit}") || die "unknown upstream ref: $ref"

  if git show-ref --verify --quiet "refs/tags/$ref"; then
    label=$ref
  else
    label="main-$(git rev-parse --short=7 "$base")"
  fi
  branch=${branch:-rumskrot/$label}

  if git show-ref --verify --quiet "refs/heads/$branch"; then
    existing=$(git show "$branch:Rumskrot/UPSTREAM" 2>/dev/null | sed -n 's/^commit //p')
    [[ "$existing" == "$base" ]] \
      || die "$branch exists but is built on ${existing:-an unknown base}, not $base; choose another --branch"
    say "$branch already carries the series on $ref; checking it"
    git checkout --quiet "$branch"
    build_and_test "$integration"
    print_pin
    return
  fi

  # The tooling (this script, the README and the patches) leaves the
  # working tree when upstream is checked out, so keep a copy.
  tooling=$(git rev-parse --git-path rumskrot-tooling)
  rm -rf "$tooling"
  cp -R Rumskrot "$tooling"

  say "creating $branch at $ref ($base)"
  git checkout --quiet -b "$branch" "$base"
  rm -rf Rumskrot
  cp -R "$tooling" Rumskrot
  rm -rf "$tooling"
  printf 'commit %s\nref %s\nurl %s\n' "$base" "$ref" "$UPSTREAM_URL" > Rumskrot/UPSTREAM
  git add Rumskrot
  git commit --quiet -m "$TOOLING_PREFIX patch series and update script on upstream $ref"

  patches=(Rumskrot/patches/*.patch)
  [[ -e "${patches[0]}" ]] || die "no patches in Rumskrot/patches"
  say "applying ${#patches[@]} patches"
  if ! git am --quiet --3way "${patches[@]}"; then
    failing=$(git am --show-current-patch=raw 2>/dev/null | sed -n 's/^Subject: //p' | head -n 1 || true)
    cat >&2 <<EOF

update-from-upstream: a patch no longer applies to $ref.
  Stopped at: ${failing:-see git am --show-current-patch}

Either
  - resolve the conflict, git add the files, then:
        Rumskrot/update-from-upstream.sh --continue
  - or, if upstream has merged this change, drop the patch:
        git am --skip && Rumskrot/update-from-upstream.sh --continue
    and afterwards run --export so the series no longer carries it.
  - or give up on this base:
        git am --abort && git checkout - && git branch -D $branch
EOF
    exit 1
  fi

  build_and_test "$integration"
  print_pin
}

mode=rebuild
ref=""
branch=""
integration=0
latest_tag=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --export) mode=export ;;
    --continue) mode=continue ;;
    --integration) integration=1 ;;
    --latest-tag) latest_tag=1 ;;
    --branch) shift; branch=${1:?--branch needs a name} ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1 (see --help)" ;;
    *) [[ -z "$ref" ]] || die "only one upstream ref"; ref=$1 ;;
  esac
  shift
done

case "$mode" in
  export) export_patches ;;
  continue) continue_series "$integration" ;;
  rebuild) rebuild_series "$ref" "$branch" "$integration" "$latest_tag" ;;
esac
