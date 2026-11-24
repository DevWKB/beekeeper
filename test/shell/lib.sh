# shellcheck shell=bash
#
# Helpers shared by the test groups. Sourced by run.sh.
#
# The driver sets, for the shell currently under test:
#   TEST_SHELL      bash | zsh | fish
#   TEST_SHELL_BIN  absolute path to that shell
#   TEST_HOME       the (initially empty) home directory for this shell's run

# * Running commands in the shell under test

# sh_run [-i] [--stdin TEXT] COMMAND
#
# Runs COMMAND with `$TEST_SHELL_BIN -c` from $TEST_HOME, in a cleared
# environment where HOME=$TEST_HOME and SHELL=$TEST_SHELL_BIN. COMMAND is
# written in the syntax of the shell under test; most tests use syntax that
# bash, zsh, and fish all accept.
#
#   -i            run the shell interactively (loads its rc file)
#   --stdin TEXT  feed TEXT on stdin (default: empty stdin, i.e. immediate EOF)
#
# Sets OUT (stdout), ERR (stderr), and CODE (exit status).
sh_run() {
  local interactive=() input=""
  while (($#)); do
    case $1 in
      -i)      interactive=(-i); shift ;;
      --stdin) input=$2; shift 2 ;;
      *)       break ;;
    esac
  done
  LAST_CMD=$1

  local errf
  errf=$(mktemp)
  OUT=$(cd "$TEST_HOME" &&
        printf '%s' "$input" |
        env -i \
          HOME="$TEST_HOME" \
          SHELL="$TEST_SHELL_BIN" \
          PATH="/usr/local/bin:/usr/bin:/bin" \
          LANG=C.UTF-8 \
          TERM=dumb \
          USER="$(id -un)" \
          "$TEST_SHELL_BIN" "${interactive[@]}" -c "$1" 2>"$errf")
  CODE=$?
  ERR=$(<"$errf")
  rm -f "$errf"
}

# sh_complete WORD...
#
# Asks the shell under test to complete the command line `WORD...` and sets
# OUT to the candidates, one per line.
#   bash: calls the installed `_bk` completion function.
#   fish: uses `complete -C`, which loads the installed completion file.
#   zsh:  zsh can't run its completion system outside a terminal, so this
#         queries the protocol the installed `_bk` uses (`bk --bash-completion-*`).
sh_complete() {
  local words=("$@") cword=$(($# - 1))
  case $TEST_SHELL in
    bash)
      sh_run -i "COMP_WORDS=(${words[*]}); COMP_CWORD=$cword; _bk; printf '%s\n' \"\${COMPREPLY[@]}\""
      ;;
    fish)
      sh_run "complete -C '${words[*]}'"
      OUT=$(cut -f1 <<<"$OUT")   # drop the tab-separated descriptions
      ;;
    zsh)
      local cmd="bk --bash-completion-index $cword" w
      for w in "${words[@]}"; do cmd+=" --bash-completion-word $w"; done
      sh_run "$cmd"
      ;;
  esac
}

# * Per-shell facts about where bk puts things

# The rc file `bk init` updates (empty for fish, which has none).
rc_file() {
  case $TEST_SHELL in
    bash) echo "$TEST_HOME/.bashrc" ;;
    zsh)  echo "$TEST_HOME/.zshrc" ;;
    fish) echo "" ;;
  esac
}

# The startup file the shell reads when run interactively; tests append to it.
startup_file() {
  case $TEST_SHELL in
    bash) echo "$TEST_HOME/.bashrc" ;;
    zsh)  echo "$TEST_HOME/.zshrc" ;;
    fish) echo "$TEST_HOME/.config/fish/config.fish" ;;
  esac
}

# Where `bk init` writes the completion script.
completion_file() {
  case $TEST_SHELL in
    bash) echo "$TEST_HOME/.bk/completions/bk.bash" ;;
    zsh)  echo "$TEST_HOME/.bk/completions/_bk" ;;
    fish) echo "$TEST_HOME/.config/fish/completions/bk.fish" ;;
  esac
}

# The name bk uses for the shell in its messages.
shell_label() {
  case $TEST_SHELL in
    bash) echo Bash ;;
    zsh)  echo Zsh ;;
    fish) echo Fish ;;
  esac
}

csv_file() { echo "$TEST_HOME/.bk/bookmarks.csv"; }

# * Assertions
#
# Assertions never abort a test; each failure is recorded and the test is
# reported as failed once it finishes.

_failures=()

fail() {
  _failures+=("$1
      command: ${LAST_CMD:-<none>}
      exit:    ${CODE:-<none>}
      stdout:  $(_indent "${OUT:-}")
      stderr:  $(_indent "${ERR:-}")")
}

_indent() { sed '2,$s/^/               /' <<<"$1"; }

assert_code() {
  [[ $CODE == "$1" ]] || fail "expected exit code $1, got $CODE"
}

assert_out() {
  [[ $OUT == "$1" ]] || fail "expected stdout to be exactly: $1"
}

assert_out_empty() {
  [[ -z $OUT ]] || fail "expected empty stdout"
}

assert_out_contains() {
  [[ $OUT == *"$1"* ]] || fail "expected stdout to contain: $1"
}

assert_out_not_contains() {
  [[ $OUT != *"$1"* ]] || fail "expected stdout not to contain: $1"
}

# assert_out_has_line REGEX — some line of stdout matches the (ERE) regex.
assert_out_has_line() {
  grep -Eq -- "$1" <<<"$OUT" || fail "expected a stdout line matching: $1"
}

# assert_out_all_lines REGEX — every non-empty line of stdout matches.
assert_out_all_lines() {
  local bad
  bad=$(grep -v '^$' <<<"$OUT" | grep -Ev -- "$1")
  [[ -z $bad ]] || fail "expected every stdout line to match $1, but these don't: $bad"
}

assert_err_contains() {
  [[ $ERR == *"$1"* ]] || fail "expected stderr to contain: $1"
}

assert_file() {
  [[ -f $1 ]] || fail "expected file to exist: $1"
}

assert_no_path() {
  [[ ! -e $1 ]] || fail "expected path not to exist: $1"
}

# assert_count FILE N FIXED_STRING — FILE has exactly N lines containing it.
assert_count() {
  local n=0
  [[ -f $1 ]] && n=$(grep -cF -- "$3" "$1")
  [[ $n == "$2" ]] || fail "expected $2 line(s) containing '$3' in $1, found $n"
}

# assert_csv_rows TYPE LABEL N — the bookmarks CSV has N rows for TYPE,LABEL.
assert_csv_rows() {
  local n=0
  [[ -f $(csv_file) ]] && n=$(grep -c -- "^$1,$2," "$(csv_file)")
  [[ $n == "$3" ]] || fail "expected $3 CSV row(s) for $1 '$2', found $n"
}

# * Test runner

if [[ -t 1 ]]; then
  _green=$'\e[32m' _red=$'\e[31m' _bold=$'\e[1m' _reset=$'\e[0m'
else
  _green="" _red="" _bold="" _reset=""
fi

# run_test FUNCTION — runs one test and updates PASSED/FAILED.
run_test() {
  local name=${1#test_}
  name=${name//_/ }
  _failures=()
  LAST_CMD="" OUT="" ERR="" CODE=""

  "$1"

  if ((${#_failures[@]} == 0)); then
    printf '  %sok%s    %s\n' "$_green" "$_reset" "$name"
    ((PASSED++))
  else
    printf '  %sFAIL%s  %s\n' "$_red" "$_reset" "$name"
    local f
    for f in "${_failures[@]}"; do printf '      - %s\n' "$f"; done
    ((FAILED++))
    FAILED_TESTS+=("$TEST_SHELL: $name")
  fi
}
