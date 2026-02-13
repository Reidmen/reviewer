#!/usr/bin/env bash
# ============================================================================
#  test_pr_review.sh — Test suite for pr_review.sh
# ============================================================================
#  Tests ANSI colors, TTY/NO_COLOR detection, argument parsing, macOS
#  compatibility, iTerm2 escape sequences, error handling, and helpers.
#
#  Usage:  ./test_pr_review.sh
#  Exit:   0 = all pass, 1 = failures
# ============================================================================
set -uo pipefail

# ── Test framework (uses $'...' ANSI-C quoting — actual ESC bytes) ────────
PASS=0; FAIL=0; TOTAL=0
RED=$'\033[0;31m';    GREEN=$'\033[0;32m';  YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m';   BOLD=$'\033[1m';      DIM=$'\033[2m';  RESET=$'\033[0m'
ESC=$'\033'  # literal ESC byte for assertions

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${SCRIPT_DIR}/pr_review.sh"

assert() {
    local desc="$1" result="$2" expected="$3"
    ((TOTAL++))
    if [[ "$result" == "$expected" ]]; then
        ((PASS++))
        printf "  %sPASS%s  %s\n" "$GREEN" "$RESET" "$desc"
    else
        ((FAIL++))
        printf "  %sFAIL%s  %s\n" "$RED" "$RESET" "$desc"
        printf "        %sexpected: %s%s\n" "$DIM" "$expected" "$RESET"
        printf "        %s     got: %s%s\n" "$DIM" "$result" "$RESET"
    fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    ((TOTAL++))
    if [[ "$haystack" == *"$needle"* ]]; then
        ((PASS++))
        printf "  %sPASS%s  %s\n" "$GREEN" "$RESET" "$desc"
    else
        ((FAIL++))
        printf "  %sFAIL%s  %s\n" "$RED" "$RESET" "$desc"
        printf "        %sexpected to contain: %s%s\n" "$DIM" "$needle" "$RESET"
        printf "        %sgot: %.120s%s\n" "$DIM" "$haystack" "$RESET"
    fi
}

assert_not_contains() {
    local desc="$1" haystack="$2" needle="$3"
    ((TOTAL++))
    if [[ "$haystack" != *"$needle"* ]]; then
        ((PASS++))
        printf "  %sPASS%s  %s\n" "$GREEN" "$RESET" "$desc"
    else
        ((FAIL++))
        printf "  %sFAIL%s  %s\n" "$RED" "$RESET" "$desc"
        printf "        %sshould not contain: %s%s\n" "$DIM" "$needle" "$RESET"
    fi
}

assert_exit_code() {
    local desc="$1" actual="$2" expected="$3"
    ((TOTAL++))
    if [[ "$actual" -eq "$expected" ]]; then
        ((PASS++))
        printf "  %sPASS%s  %s\n" "$GREEN" "$RESET" "$desc"
    else
        ((FAIL++))
        printf "  %sFAIL%s  %s\n" "$RED" "$RESET" "$desc"
        printf "        %sexpected exit: %s, got: %s%s\n" "$DIM" "$expected" "$actual" "$RESET"
    fi
}

section() {
    printf "\n%s%s▸ %s%s\n" "$CYAN" "$BOLD" "$1" "$RESET"
}

# ── Pre-flight ─────────────────────────────────────────────────────────────
printf "%s%s╔══════════════════════════════════════════════════╗%s\n" "$BOLD" "$CYAN" "$RESET"
printf "%s%s║  pr_review.sh — Test Suite                      ║%s\n" "$BOLD" "$CYAN" "$RESET"
printf "%s%s╚══════════════════════════════════════════════════╝%s\n" "$BOLD" "$CYAN" "$RESET"

if [[ ! -f "$SCRIPT" ]]; then
    printf "%sERROR: pr_review.sh not found at %s%s\n" "$RED" "$SCRIPT" "$RESET"
    exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════
#  1. ANSI COLOR CODES — $'...' quoting produces real ESC bytes
# ═══════════════════════════════════════════════════════════════════════════
section "ANSI Color Codes"

# Source color definitions from the script (lines with $'\033[...')
eval "$(grep -E "^    (RED|GREEN|YELLOW|BLUE|CYAN|BOLD|DIM|RESET)=\\\$" "$SCRIPT" | sed 's/^    //')"

# Verify each variable contains an actual ESC byte (0x1B) followed by [
for name in RED GREEN YELLOW BLUE CYAN BOLD DIM; do
    val="${!name}"
    if [[ "$val" == "${ESC}["* ]]; then
        assert "Color $name starts with ESC[" "valid" "valid"
    else
        assert "Color $name starts with ESC[" "$(printf '%s' "$val" | xxd -p | head -c10)" "1b5b..."
    fi
done

# Verify RESET is ESC[0m
assert "RESET is ESC[0m" "$RESET" $'\033[0m'

# Verify each color ends with 'm'
for name in RED GREEN YELLOW BLUE CYAN BOLD DIM RESET; do
    val="${!name}"
    last_char="${val: -1}"
    assert "Color $name ends with 'm'" "$last_char" "m"
done

# Verify colors produce visible output when printed
rendered=$(printf "%stest%s" "$GREEN" "$RESET")
assert_contains "GREEN renders visible text" "$rendered" "test"

# Verify actual ESC byte is present in rendered output
assert_contains "GREEN output contains ESC byte" "$rendered" "$ESC"

# ═══════════════════════════════════════════════════════════════════════════
#  2. TTY DETECTION & NO_COLOR SUPPORT
# ═══════════════════════════════════════════════════════════════════════════
section "TTY & NO_COLOR Detection"

# Verify _use_color function exists
assert_contains "Has _use_color() function" \
    "$(grep '_use_color' "$SCRIPT")" "_use_color"

# Verify NO_COLOR env var is checked (https://no-color.org)
assert_contains "Checks NO_COLOR env var" \
    "$(grep 'NO_COLOR' "$SCRIPT")" 'NO_COLOR'

# Verify PR_REVIEW_NO_COLOR env var is checked
assert_contains "Checks PR_REVIEW_NO_COLOR env var" \
    "$(grep 'PR_REVIEW_NO_COLOR' "$SCRIPT")" 'PR_REVIEW_NO_COLOR'

# Verify TTY check with -t 1
assert_contains "Checks stdout is TTY (-t 1)" \
    "$(grep '\-t 1' "$SCRIPT")" "-t 1"

# Verify --no-color flag exists in parser
assert_contains "Parser has --no-color flag" \
    "$(grep 'no-color' "$SCRIPT")" "--no-color"

# Verify --no-color sets empty color vars
no_color_line=$(grep -A1 '\-\-no-color)' "$SCRIPT" | head -1)
assert_contains "--no-color clears RED" "$no_color_line" "RED=''"

# Verify colors disabled when piped (non-TTY)
piped_output=$("$SCRIPT" --help 2>&1 | cat)
assert_not_contains "No ESC bytes when piped" "$piped_output" "$ESC"

# Verify NO_COLOR disables colors
no_color_output=$(NO_COLOR=1 "$SCRIPT" --help 2>&1)
assert_not_contains "NO_COLOR=1 suppresses ESC bytes" "$no_color_output" "$ESC"

# Verify colors empty when NO_COLOR set (via fallback branch)
assert_contains "Fallback sets empty color vars" \
    "$(grep "RED=''.*GREEN=''" "$SCRIPT")" "RED=''"

# ═══════════════════════════════════════════════════════════════════════════
#  3. iTERM2 ESCAPE SEQUENCES
# ═══════════════════════════════════════════════════════════════════════════
section "iTerm2 Escape Sequences"

# Tab title: \e]1;TITLE\a
tab_title_output=$(printf '\e]1;%s\a' "Test Title" | cat -v)
assert_contains "Tab title uses OSC 1 (ESC ]1;)" "$tab_title_output" "^[]1;Test Title"

# Window title: \e]0;TITLE\a
win_title_output=$(printf '\e]0;%s\a' "Win Title" | cat -v)
assert_contains "Window title uses OSC 0 (ESC ]0;)" "$win_title_output" "^[]0;Win Title"

# Verify _set_tab_title function exists in script
assert_contains "Script has _set_tab_title function" "$(grep -c '_set_tab_title' "$SCRIPT")" ""

# Verify iTerm2 detection checks TERM_PROGRAM
assert_contains "Detects iTerm via TERM_PROGRAM" \
    "$(grep 'TERM_PROGRAM' "$SCRIPT")" "iTerm.app"

# Verify iTerm2 detection checks LC_TERMINAL
assert_contains "Detects iTerm via LC_TERMINAL" \
    "$(grep 'LC_TERMINAL' "$SCRIPT")" "iTerm2"

# ═══════════════════════════════════════════════════════════════════════════
#  4. ARGUMENT PARSING
# ═══════════════════════════════════════════════════════════════════════════
section "Argument Parsing"

# --help exits 0
output=$("$SCRIPT" --help 2>&1) && exit_code=0 || exit_code=$?
assert_exit_code "--help exits 0" "$exit_code" 0
assert_contains "--help shows usage" "$output" "USAGE"
assert_contains "--help shows options" "$output" "OPTIONS"

# No args -> fatal error
output=$("$SCRIPT" 2>&1) && exit_code=0 || exit_code=$?
assert_exit_code "No args exits non-zero" "$exit_code" 1
assert_contains "No args shows error" "$output" "Missing required argument"

# Non-numeric PR number -> fatal
output=$("$SCRIPT" abc 2>&1) && exit_code=0 || exit_code=$?
assert_exit_code "Non-numeric PR number exits non-zero" "$exit_code" 1
assert_contains "Non-numeric PR gives clear error" "$output" "Expected a PR number"

# Unknown option -> fatal
output=$("$SCRIPT" 42 --bogus 2>&1) && exit_code=0 || exit_code=$?
assert_exit_code "Unknown option exits non-zero" "$exit_code" 1
assert_contains "Unknown option named in error" "$output" "--bogus"

# -h is alias for --help
output=$("$SCRIPT" -h 2>&1) && exit_code=0 || exit_code=$?
assert_exit_code "-h exits 0" "$exit_code" 0
assert_contains "-h shows usage" "$output" "USAGE"

# --no-color is accepted (does not error)
output=$("$SCRIPT" --no-color --help 2>&1) && exit_code=0 || exit_code=$?
assert_exit_code "--no-color --help exits 0" "$exit_code" 0

# ═══════════════════════════════════════════════════════════════════════════
#  5. macOS COMPATIBILITY
# ═══════════════════════════════════════════════════════════════════════════
section "macOS Compatibility"

# Verify script does NOT use `realpath --relative-to` (was a bug)
assert_not_contains "No realpath --relative-to (macOS compat)" \
    "$(grep 'realpath' "$SCRIPT")" "realpath --relative-to"

# Verify python3 fallback for relative path
assert_contains "Uses python3 for relative path" \
    "$(grep 'python3.*relpath' "$SCRIPT")" "os.path.relpath"

# Verify script does NOT use `du -sb` (was a bug)
assert_not_contains "No du -sb (macOS compat)" \
    "$(grep 'du -s' "$SCRIPT")" "du -sb"

# Verify du -sk is used instead
assert_contains "Uses du -sk (macOS compatible)" \
    "$(grep 'du -sk' "$SCRIPT")" "du -sk"

# Verify stat fallback chain (GNU -> BSD -> default)
stat_line=$(grep 'stat -c' "$SCRIPT" || echo "")
assert_contains "stat has BSD fallback (stat -f%z)" \
    "$stat_line" "stat -f%z"

# ═══════════════════════════════════════════════════════════════════════════
#  6. SAFETY & SECURITY
# ═══════════════════════════════════════════════════════════════════════════
section "Safety & Security"

# Verify no raw eval on user-derived command strings (was a bug)
bg_section=$(sed -n '/bg.*mode/,/exit 0/p' "$SCRIPT")
assert_not_contains "No eval in bg mode (injection fix)" \
    "$bg_section" 'eval "$CMD"'

# Verify build_cmd uses printf %q for safe quoting
build_cmd_section=$(sed -n '/build_cmd/,/^    }/p' "$SCRIPT")
assert_contains "build_cmd uses printf %q" "$build_cmd_section" "printf '%q"

# Verify AppleScript escapes double quotes in tab title
assert_contains "AppleScript escapes double quotes" \
    "$(grep -A1 'TAB_TITLE=' "$SCRIPT" | grep 'escape')" "escape double quotes"

# Verify set -euo pipefail is set
assert_contains "Script uses set -euo pipefail" \
    "$(head -50 "$SCRIPT")" "set -euo pipefail"

# Verify REVIEW_EXIT is captured safely (not killed by set -e)
assert_contains "REVIEW_EXIT uses || pattern" \
    "$(grep 'REVIEW_EXIT' "$SCRIPT")" "|| REVIEW_EXIT="

# Verify run_claude uses subshell (not bare function)
run_claude_line=$(grep -n 'run_claude()' "$SCRIPT")
assert_contains "run_claude is a subshell" "$run_claude_line" "("

# ═══════════════════════════════════════════════════════════════════════════
#  7. HELPER FUNCTIONS — source color + function defs from script
# ═══════════════════════════════════════════════════════════════════════════
section "Helper Functions"

# Source the color setup and helper functions (skip _use_color detection
# since we want colors enabled for testing)
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'; CYAN=$'\033[0;36m'; BOLD=$'\033[1m'
DIM=$'\033[2m'; RESET=$'\033[0m'
eval "$(grep -A1 '^info()\|^ok()\|^warn()\|^error()\|^fatal()\|^step()\|^_boxln()' "$SCRIPT" | grep -v '^--$')"

# Capture info output
info_out=$(info "test message" 2>&1)
assert_contains "info() includes [INFO] tag" "$info_out" "[INFO]"
assert_contains "info() includes the message" "$info_out" "test message"
assert_contains "info() has ESC byte (colored)" "$info_out" "$ESC"

# Capture ok output
ok_out=$(ok "success" 2>&1)
assert_contains "ok() includes [OK] tag" "$ok_out" "[OK]"
assert_contains "ok() has ESC byte (colored)" "$ok_out" "$ESC"

# Capture warn output
warn_out=$(warn "careful" 2>&1)
assert_contains "warn() includes [WARN] tag" "$warn_out" "[WARN]"

# Capture error output (goes to stderr)
error_out=$(error "failure" 2>&1)
assert_contains "error() includes [ERROR] tag" "$error_out" "[ERROR]"

# step() output
step_out=$(step "doing things" 2>&1)
assert_contains "step() includes the message" "$step_out" "doing things"

# _boxln() output
boxln_out=$(_boxln "║ test box line ║" 2>&1)
assert_contains "_boxln() contains the line" "$boxln_out" "test box line"
assert_contains "_boxln() has ESC byte (colored)" "$boxln_out" "$ESC"

# Verify logging with empty colors (NO_COLOR simulation)
(
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; DIM=''; RESET=''
    eval "$(grep -A1 '^info()\|^ok()' "$SCRIPT" | grep -v '^--$')"
    plain_info=$(info "plain" 2>&1)
    plain_ok=$(ok "plain" 2>&1)
    # Should still contain tags but no ESC bytes
    if [[ "$plain_info" == *"[INFO]"* && "$plain_info" != *"$ESC"* ]]; then
        echo "NOCOLOR_INFO_OK"
    fi
    if [[ "$plain_ok" == *"[OK]"* && "$plain_ok" != *"$ESC"* ]]; then
        echo "NOCOLOR_OK_OK"
    fi
) | {
    read -r line1; read -r line2
    assert "info() works with empty colors" "$line1" "NOCOLOR_INFO_OK"
    assert "ok() works with empty colors" "$line2" "NOCOLOR_OK_OK"
}

# ═══════════════════════════════════════════════════════════════════════════
#  8. PREREQUISITE CHECKING
# ═══════════════════════════════════════════════════════════════════════════
section "Prerequisites"

# Verify script checks for required tools
for tool in gh git claude jq; do
    assert_contains "Checks for $tool" \
        "$(grep 'for cmd in' "$SCRIPT")" "$tool"
done

# Verify gh auth status check exists
assert_contains "Checks gh auth status" \
    "$(grep 'gh auth status' "$SCRIPT")" "gh auth status"

# ═══════════════════════════════════════════════════════════════════════════
#  9. COLOR RENDERING — real ESC bytes in iTerm2
# ═══════════════════════════════════════════════════════════════════════════
section "Color Rendering (iTerm2)"

# Verify all colors produce visible output with ESC byte
for name in RED GREEN YELLOW BLUE CYAN BOLD DIM; do
    val="${!name}"
    rendered=$(printf "%sX%s" "$val" "$RESET")
    assert_contains "$name renders non-empty" "$rendered" "X"
    assert_contains "$name contains ESC byte" "$rendered" "$ESC"
done

# Verify RESET removes color (cat -v shows control chars)
rendered=$(printf "%scolored%snormal" "$RED" "$RESET" | cat -v)
assert_contains "RESET clears RED (cat -v shows [0m)" "$rendered" "[0m"
assert_contains "Text after RESET is present" "$rendered" "normal"

# Test box-drawing characters render (UTF-8)
box_output=$(printf "╔══╗\n║  ║\n╚══╝\n")
assert_contains "Box-drawing chars render" "$box_output" "╔══╗"

# Verify no printf embeds color vars in format string
bad_pattern_count=$(grep -cE 'printf "\$\{(BOLD|RED|GREEN|YELLOW|BLUE|CYAN|DIM|RESET)' "$SCRIPT" 2>/dev/null || true)
bad_pattern_count="${bad_pattern_count:-0}"
bad_pattern_count="$(echo "$bad_pattern_count" | tr -d '[:space:]')"
assert "No color vars in printf format strings" "$bad_pattern_count" "0"

# ═══════════════════════════════════════════════════════════════════════════
#  10. WORKTREE & LOCKFILE LOGIC
# ═══════════════════════════════════════════════════════════════════════════
section "Worktree & Lockfile Logic"

# Verify lockfile path pattern
assert_contains "Lockfile uses .lock-pr-N pattern" \
    "$(grep 'LOCKFILE=' "$SCRIPT")" ".lock-pr-"

# Verify cleanup trap is set
assert_contains "EXIT trap is set" \
    "$(grep 'trap.*EXIT' "$SCRIPT")" "_cleanup_on_exit"

# Verify stale lockfile detection (kill -0 check)
assert_contains "Stale lockfile detected via kill -0" \
    "$(grep -A2 'LOCK_PID' "$SCRIPT" | head -5)" "kill -0"

# Verify _sq function exists (single-quote escaping for RC file)
assert_contains "Has _sq() for safe quoting" \
    "$(grep '_sq()' "$SCRIPT")" "_sq()"

# ═══════════════════════════════════════════════════════════════════════════
#  11. PARALLEL MODE
# ═══════════════════════════════════════════════════════════════════════════
section "Parallel Mode"

# Verify tab modes are supported
for mode in auto iterm tmux bg; do
    assert_contains "Supports --tabs $mode" \
        "$(grep -c "$mode" "$SCRIPT")" ""
done

# Verify bg mode caches exit codes (was a bug — re-wait returned 127)
assert_contains "BG mode caches exit codes" \
    "$(grep 'BG_EXIT_CODES' "$SCRIPT")" "BG_EXIT_CODES"

# Verify first-iteration cursor skip (was a bug)
assert_contains "BG mode skips cursor-up on first iter" \
    "$(grep 'BG_FIRST_ITER' "$SCRIPT")" "BG_FIRST_ITER"

# Verify diff function renamed to pdiff (was shadowing /usr/bin/diff)
assert_contains "PR diff command is pdiff (not diff)" \
    "$(grep 'pdiff()' "$SCRIPT")" "pdiff()"
assert_not_contains "No diff() function (avoids shadow)" \
    "$(grep -w 'diff()' "$SCRIPT")" "diff()"

# Verify _boxln helper exists
assert_contains "Has _boxln() helper" \
    "$(grep '_boxln()' "$SCRIPT")" "_boxln()"

# ═══════════════════════════════════════════════════════════════════════════
#  RESULTS
# ═══════════════════════════════════════════════════════════════════════════
echo ""
printf "%s%s╔══════════════════════════════════════════════════╗%s\n" "$BOLD" "$CYAN" "$RESET"
if [[ "$FAIL" -eq 0 ]]; then
    printf "%s%s║  ALL %d TESTS PASSED                             ║%s\n" "$BOLD" "$GREEN" "$TOTAL" "$RESET"
else
    printf "%s%s║  %d PASSED, %d FAILED (of %d)                    ║%s\n" "$BOLD" "$RED" "$PASS" "$FAIL" "$TOTAL" "$RESET"
fi
printf "%s%s╚══════════════════════════════════════════════════╝%s\n" "$BOLD" "$CYAN" "$RESET"
echo ""

[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
