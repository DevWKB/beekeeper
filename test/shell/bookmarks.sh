# shellcheck shell=bash
#
# Bookmark tests. Run after the init tests, against the initialized $HOME.
# Bookmarks added here are left in place, so the alias tests also run with
# some bookmarks present.

BOOKMARK_TESTS=(
  test_bookmark_add_and_run
  test_bookmark_run_subcommand
  test_bookmark_cd_into_target_with_spaces
  test_bookmark_tilde_is_expanded
  test_bookmark_path_is_normalised
  test_bookmark_is_saved_to_csv
  test_bookmark_find
  test_bookmark_readd_overwrites_target
  test_bookmark_rename
  test_bookmark_rename_missing_label_fails
  test_bookmark_remove
  test_bookmark_invalid_label_rejected
  test_bookmark_empty_target_rejected
  test_bookmark_listings
  test_bookmark_label_completion
)

test_bookmark_add_and_run() {
  mkdir -p "$TEST_HOME/projects/math"
  sh_run 'bk bookmark math="$HOME/projects/math"'
  assert_code 0
  assert_out 'created bookmark "math"'

  sh_run 'bk math'
  assert_code 0
  assert_out "$TEST_HOME/projects/math"
}

test_bookmark_run_subcommand() {
  sh_run 'bk run math'
  assert_code 0
  assert_out "$TEST_HOME/projects/math"
}

test_bookmark_cd_into_target_with_spaces() {
  mkdir -p "$TEST_HOME/my docs"
  sh_run 'bk bookmark docs="$HOME/my docs"'
  assert_code 0

  sh_run 'cd "$(bk docs)" && pwd'
  assert_code 0
  assert_out "$TEST_HOME/my docs"
}

test_bookmark_tilde_is_expanded() {
  sh_run "bk bookmark proj-root='~/projects'"
  assert_code 0
  sh_run 'bk proj-root'
  assert_out "$TEST_HOME/projects"
}

test_bookmark_path_is_normalised() {
  sh_run "bk bookmark logs='/var/./log//'"
  assert_code 0
  sh_run 'bk logs'
  assert_out '/var/log'
}

test_bookmark_is_saved_to_csv() {
  assert_csv_rows bookmark math 1
  assert_count "$(csv_file)" 1 "bookmark,math,$TEST_HOME/projects/math,"
}

test_bookmark_find() {
  sh_run 'bk find math'
  assert_code 0
  assert_out "bookmark math=\"$TEST_HOME/projects/math\""

  sh_run 'bk find nowhere'
  assert_out_empty
  assert_err_contains 'bookmark not found "nowhere"'
}

test_bookmark_readd_overwrites_target() {
  sh_run 'bk bookmark scratch=/tmp'
  sh_run 'bk bookmark scratch=/var/tmp'
  assert_code 0
  sh_run 'bk scratch'
  assert_out '/var/tmp'
  assert_csv_rows bookmark scratch 1
}

test_bookmark_rename() {
  sh_run 'bk rename scratch tmpdir'
  assert_code 0
  assert_out 'renamed "scratch" to "tmpdir"'

  sh_run 'bk tmpdir'
  assert_out '/var/tmp'

  sh_run 'bk scratch'
  assert_out_empty
  assert_err_contains 'bookmark not found "scratch"'
  assert_csv_rows bookmark scratch 0
}

test_bookmark_rename_missing_label_fails() {
  sh_run 'bk rename nosuch other'
  assert_out_empty
  assert_err_contains 'error: bookmark "nosuch" couldn'"'"'t be found.'
  assert_csv_rows bookmark other 0
}

test_bookmark_remove() {
  sh_run 'bk remove tmpdir'
  assert_code 0
  assert_out 'removed bookmark "tmpdir"'

  sh_run 'bk tmpdir'
  assert_out_empty
  assert_err_contains 'bookmark not found "tmpdir"'
  assert_csv_rows bookmark tmpdir 0
}

test_bookmark_invalid_label_rejected() {
  sh_run 'bk bookmark 9lives=/tmp'
  assert_code 1
  assert_err_contains 'bookmark labels must start with a letter'
  assert_csv_rows bookmark 9lives 0
}

test_bookmark_empty_target_rejected() {
  sh_run 'bk bookmark blank='
  assert_err_contains 'empty target for label "blank"'
  assert_csv_rows bookmark blank 0
}

test_bookmark_listings() {
  # An alias, to check that `bk bookmarks` filters it out.
  sh_run "bk alias listed-alias='true'"

  local math_line="^bookmark +math += \"$TEST_HOME/projects/math\"\$"

  sh_run 'bk bookmarks'
  assert_code 0
  assert_out_has_line "$math_line"
  assert_out_has_line '^bookmark +logs += "/var/log"$'
  assert_out_all_lines '^bookmark '

  sh_run 'bk list'
  assert_code 0
  assert_out_has_line "$math_line"
  assert_out_has_line '^alias +listed-alias += "true"$'

  # With no arguments bk lists what was added in the last 10 days.
  sh_run 'bk'
  assert_code 0
  assert_out_has_line "$math_line"
  assert_out_has_line '^alias +listed-alias += "true"$'

  sh_run 'bk remove listed-alias'
}

test_bookmark_label_completion() {
  sh_complete bk ma
  assert_out_has_line '^math$'
  sh_complete bk run proj
  assert_out_has_line '^proj-root$'
}
