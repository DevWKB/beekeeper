# shellcheck shell=bash
#
# Initialization tests. These run first, against an empty $HOME; the
# successful `bk init` here is what the bookmark and alias tests build on.

INIT_TESTS=(
  test_init_uninitialized_bk_refuses_to_run
  test_init_creates_bookmarks_file_and_completions
  test_init_sets_up_rc_file
  test_init_completions_load_in_shell
  test_init_rerun_is_idempotent
  test_init_declined_leaves_rc_file_alone
  test_init_unsupported_shell_fails
)

# Output of the `bk init` in test_init_creates_bookmarks_file_and_completions,
# inspected by test_init_sets_up_rc_file.
INIT_OUT=""

# Runs the rest of a test in a separate, empty home so it doesn't disturb the
# initialized one. Usage: `with_scratch_home; ...; restore_home`.
with_scratch_home() {
  _saved_home=$TEST_HOME
  TEST_HOME=$(mktemp -d "/tmp/bk-$TEST_SHELL-scratch.XXXXXX")
}
restore_home() {
  rm -rf "$TEST_HOME"
  TEST_HOME=$_saved_home
}

test_init_uninitialized_bk_refuses_to_run() {
  sh_run 'bk list'
  assert_code 1
  assert_err_contains 'bk uninitialized, run `bk init`.'
  assert_no_path "$TEST_HOME/.bk"
}

test_init_creates_bookmarks_file_and_completions() {
  sh_run --stdin $'y\n' 'bk init'
  INIT_OUT=$OUT
  assert_code 0
  assert_out_contains "Installed $(shell_label) completions to $(completion_file)"
  assert_out_contains "Restart your shell to enable completions."
  assert_file "$(csv_file)"
  assert_count "$(csv_file)" 1 'type,label,target,created-data,last-used'
  assert_file "$(completion_file)"
}

test_init_sets_up_rc_file() {
  OUT=$INIT_OUT LAST_CMD="bk init (previous test)"
  if [[ $TEST_SHELL == fish ]]; then
    # Fish autoloads completions, so init has no rc file to update or ask about.
    assert_out_not_contains '[Y/n]'
    assert_no_path "$TEST_HOME/.config/fish/config.fish"
    assert_no_path "$TEST_HOME/.bashrc"
    assert_no_path "$TEST_HOME/.zshrc"
    return
  fi
  local rc
  rc=$(rc_file)
  assert_out_contains "Add completion setup to $rc? [Y/n]"
  assert_out_contains "Added completion setup to $rc"
  assert_count "$rc" 1 '# bk completions start'
  assert_count "$rc" 1 '# bk completions end'
  case $TEST_SHELL in
    bash) assert_count "$rc" 1 'source "$HOME/.bk/completions/bk.bash"' ;;
    zsh)  assert_count "$rc" 1 'fpath=("$HOME/.bk/completions" $fpath)'
          assert_count "$rc" 1 'compdef _bk bk' ;;
  esac
}

test_init_completions_load_in_shell() {
  # The completion function is registered in a new interactive shell...
  case $TEST_SHELL in
    bash) sh_run -i 'complete -p bk'
          assert_out_contains '-F _bk' ;;
    zsh)  sh_run -i 'print -r -- "${_comps[bk]}"'
          assert_out '_bk' ;;
    fish) ;;  # nothing to register: fish autoloads the file on first use
  esac
  # ...and completes bk's subcommands.
  sh_complete bk bookm
  assert_out_has_line '^bookmark$'
  assert_out_has_line '^bookmarks$'
}

test_init_rerun_is_idempotent() {
  sh_run 'bk bookmark keepme=/tmp'
  sh_run --stdin $'y\n' 'bk init'
  assert_code 0
  assert_out_not_contains '[Y/n]'
  local rc
  rc=$(rc_file)
  if [[ -n $rc ]]; then
    assert_out_contains "Completion setup already present in $rc"
    assert_count "$rc" 1 '# bk completions start'
  fi
  # Existing bookmarks survive a re-init.
  sh_run 'bk keepme'
  assert_out '/tmp'
  sh_run 'bk remove keepme'
}

# Not run for fish (see run.sh): it has no rc file, so init has nothing to ask
# about, which test_init_sets_up_rc_file already checks.
test_init_declined_leaves_rc_file_alone() {
  with_scratch_home
  local rc
  rc=$(rc_file)
  # An unrecognised answer re-prompts; "n" declines.
  sh_run --stdin $'maybe\nn\n' 'bk init'
  assert_code 0
  [[ $(grep -o '\[Y/n\]' <<<"$OUT" | wc -l) -eq 2 ]] ||
    fail "expected to be prompted twice (once for 'maybe', once for 'n')"
  assert_out_contains "Left $rc unchanged."
  # The lines to add by hand are printed instead.
  assert_out_contains '# bk completions start'
  assert_no_path "$rc"
  # Everything else is still set up.
  assert_file "$(csv_file)"
  assert_file "$(completion_file)"
  restore_home
}

test_init_unsupported_shell_fails() {
  with_scratch_home
  sh_run 'SHELL=/bin/sh bk init'
  assert_code 1
  assert_err_contains 'unable to determine your shell from $SHELL'
  assert_err_contains 'Supported shells: bash, zsh, and fish.'
  restore_home
}
