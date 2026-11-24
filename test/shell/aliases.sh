# shellcheck shell=bash
#
# Alias tests. Run after the bookmark tests, against the same $HOME.
#
# bk runs an alias as `$SHELL -i -c '<target> "$@"' bk ARGS...` (under fish,
# `fish -i -c '<target> $argv' ARGS...`), so these check that targets run in
# the user's own shell, see its rc file and environment, and get their
# arguments intact.

ALIAS_TESTS=(
  test_alias_add_and_run
  test_alias_run_subcommand
  test_alias_passes_arguments
  test_alias_preserves_argument_quoting
  test_alias_with_pipeline_target
  test_alias_reads_stdin
  test_alias_exit_code_propagates
  test_alias_inherits_environment
  test_alias_runs_in_users_shell
  test_alias_sees_rc_file_functions
  test_alias_is_saved_to_csv
  test_alias_find
  test_alias_listing
  test_alias_rename
  test_alias_remove
)

test_alias_add_and_run() {
  sh_run "bk alias hello='echo hello world'"
  assert_code 0
  assert_out 'created alias "hello"'

  sh_run 'bk hello'
  assert_code 0
  assert_out 'hello world'
}

test_alias_run_subcommand() {
  sh_run 'bk run hello'
  assert_code 0
  assert_out 'hello world'
}

test_alias_passes_arguments() {
  sh_run "bk alias say='echo said:'"
  sh_run 'bk say one two'
  assert_code 0
  assert_out 'said: one two'
}

test_alias_preserves_argument_quoting() {
  # Repeated spaces survive and the glob isn't expanded.
  sh_run "bk say 'two  spaces' '*'"
  assert_code 0
  assert_out 'said: two  spaces *'
}

test_alias_with_pipeline_target() {
  sh_run "bk alias upper='echo abc | tr a-z A-Z'"
  sh_run 'bk upper'
  assert_code 0
  assert_out 'ABC'
}

test_alias_reads_stdin() {
  sh_run "bk alias shout='tr a-z A-Z'"
  sh_run 'echo quiet | bk shout'
  assert_code 0
  assert_out 'QUIET'
}

test_alias_exit_code_propagates() {
  sh_run "bk alias fail-three='sh -c \"exit 3\"'"
  sh_run 'bk fail-three'
  assert_code 3
}

test_alias_inherits_environment() {
  sh_run "bk alias showvar='echo \"\$BK_TEST_VAR\"'"
  sh_run 'BK_TEST_VAR=from-env bk showvar'
  assert_code 0
  assert_out 'from-env'
}

test_alias_runs_in_users_shell() {
  local var
  case $TEST_SHELL in
    bash) var=BASH_VERSION ;;
    zsh)  var=ZSH_VERSION ;;
    fish) var=FISH_VERSION ;;
  esac
  sh_run "echo \"\$$var\""
  local expected=$OUT

  sh_run "bk alias shell-version='echo \"\$$var\"'"
  sh_run 'bk shell-version'
  assert_code 0
  [[ -n $expected ]] || fail "\$$var is empty in $TEST_SHELL itself"
  assert_out "$expected"
}

test_alias_sees_rc_file_functions() {
  local startup
  startup=$(startup_file)
  mkdir -p "$(dirname "$startup")"
  case $TEST_SHELL in
    bash|zsh) printf '\nbk_rc_greet() { echo "hi from rc"; }\n' >>"$startup" ;;
    fish)     printf '\nfunction bk_rc_greet; echo "hi from rc"; end\n' >>"$startup" ;;
  esac

  sh_run "bk alias rc-greet='bk_rc_greet'"
  sh_run 'bk rc-greet'
  assert_code 0
  assert_out 'hi from rc'
}

test_alias_is_saved_to_csv() {
  assert_csv_rows alias hello 1
  # Alias targets are stored verbatim (no path handling).
  assert_count "$(csv_file)" 1 'alias,upper,echo abc | tr a-z A-Z,'
}

test_alias_find() {
  sh_run 'bk find hello'
  assert_code 0
  assert_out 'alias hello="echo hello world"'
}

test_alias_listing() {
  sh_run 'bk aliases'
  assert_code 0
  assert_out_has_line '^alias +hello += "echo hello world"$'
  assert_out_has_line '^alias +say += "echo said:"$'
  # Bookmarks from the bookmark tests are filtered out.
  assert_out_all_lines '^alias '
}

test_alias_rename() {
  sh_run 'bk rename say speak'
  assert_code 0
  assert_out 'renamed "say" to "speak"'

  sh_run 'bk speak renamed'
  assert_code 0
  assert_out 'said: renamed'

  sh_run 'bk say'
  assert_out_empty
  assert_err_contains 'bookmark not found "say"'
}

test_alias_remove() {
  sh_run 'bk remove hello'
  assert_code 0
  assert_out 'removed bookmark "hello"'

  sh_run 'bk hello'
  assert_out_empty
  assert_err_contains 'bookmark not found "hello"'
  assert_csv_rows alias hello 0
}
