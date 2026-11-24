#!/usr/bin/env bash
#
# Shell integration tests for bk.
#
# Usage: run.sh [SHELL...]     (default: bash zsh fish)
#
# Each shell gets a run of its own that starts from a clean slate: a new,
# empty $HOME and a cleared environment. Within a run the tests go in order
# (init, then bookmarks, then aliases) and share that $HOME, so the later
# groups build on the `bk init` done by the first.
#
# Set KEEP_HOMES=1 to keep each shell's $HOME afterwards for inspection.

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

source "$here/lib.sh"
source "$here/init.sh"
source "$here/bookmarks.sh"
source "$here/aliases.sh"

shells=("$@")
((${#shells[@]})) || shells=(bash zsh fish)

if ! command -v bk >/dev/null; then
  echo "error: bk is not on the PATH" >&2
  exit 2
fi

PASSED=0 FAILED=0
FAILED_TESTS=()

for TEST_SHELL in "${shells[@]}"; do
  if ! TEST_SHELL_BIN=$(command -v "$TEST_SHELL"); then
    echo "error: shell not found: $TEST_SHELL" >&2
    exit 2
  fi
  case $TEST_SHELL in
    bash|zsh|fish) ;;
    *) echo "error: unsupported shell: $TEST_SHELL (use bash, zsh, or fish)" >&2
       exit 2 ;;
  esac

  # A clean slate for this shell.
  TEST_HOME=$(mktemp -d "/tmp/bk-$TEST_SHELL-home.XXXXXX")

  printf '\n%s== %s (%s)%s  HOME=%s\n' \
    "$_bold" "$TEST_SHELL" "$("$TEST_SHELL_BIN" --version | head -n1)" "$_reset" "$TEST_HOME"

  printf '%s-- init%s\n' "$_bold" "$_reset"
  for t in "${INIT_TESTS[@]}"; do
    # Fish has no rc file, so there's no prompt for init to have declined.
    [[ $TEST_SHELL == fish && $t == test_init_declined_leaves_rc_file_alone ]] && continue
    run_test "$t"
  done

  printf '%s-- bookmarks%s\n' "$_bold" "$_reset"
  for t in "${BOOKMARK_TESTS[@]}"; do run_test "$t"; done

  printf '%s-- aliases%s\n' "$_bold" "$_reset"
  for t in "${ALIAS_TESTS[@]}"; do run_test "$t"; done

  [[ -n ${KEEP_HOMES:-} ]] || rm -rf "$TEST_HOME"
done

printf '\n%s%d passed, %d failed%s\n' \
  "$_bold" "$PASSED" "$FAILED" "$_reset"
if ((FAILED)); then
  printf '\nFailed:\n'
  printf '  %s\n' "${FAILED_TESTS[@]}"
  exit 1
fi
