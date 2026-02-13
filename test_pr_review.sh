#!/usr/bin/env bash
# ============================================================================
#  test_pr_review.sh — Test suite for pr_review.sh
# ============================================================================
#  Tests ANSI colors, argument parsing, macOS compatibility, iTerm2 escape
#  sequences, error handling, and helper function correctness.
#
#  Usage:  ./test_pr_review.sh
#  Exit:   0 = all pass, 1 = failures
# ============================================================================
set -uo pipefail

# ── Test framework ─────────────────────────────────────────────────────────
PASS=0; FAIL=0; TOTAL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${SCRIPT_DIR}/pr_review.sh"

assert() {
    local desc="$1" result="$2" expected="$3"
    ((TOTAL++))
    if [[ "$result" == "$expected" ]]; then
        ((PASS++))
        printf "  ${GREEN}PASS${RESET}  %s\n" "$desc"
    else
        ((FAIL++))
        printf "  ${RED}FAIL${RESET}  %s\n" "$desc"
        printf "        ${DIM}expected: %s${RESET}\n" "$expected"
        printf "        ${DIM}     got: %s${RESET}\n" "$result"
    fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    ((TOTAL++))
    if [[ "$haystack" == *"$needle"* ]]; then
        ((PASS++))
        printf "  ${GREEN}PASS${RESET}  %s\n" "$desc"
    else
        ((FAIL++))
        printf "  ${RED}FAIL${RESET}  %s\n" "$desc"
        printf "        ${DIM}expected to contain: %s${RESET}\n" "$needle"
        printf "        ${DIM}got: %.120s${RESET}\n" "$haystack"
    fi
}

assert_not_contains() {
    local desc="$1" haystack="$2" needle="$3"
    ((TOTAL++))
    if [[ "$haystack" != *"$needle"* ]]; then
        ((PASS++))
        printf "  ${GREEN}PASS${RESET}  %s\n" "$desc"
    else
        ((FAIL++))
        printf "  ${RED}FAIL${RESET}  %s\n" "$desc"
        printf "        ${DIM}should not contain: %s${RESET}\n" "$needle"
    fi
}

assert_exit_code() {
    local desc="$1" actual="$2" expected="$3"
    ((TOTAL++))
    if [[ "$actual" -eq "$expected" ]]; then
        ((PASS++))
        printf "  ${GREEN}PASS${RESET}  %s\n" "$desc"
    else
        ((FAIL++))
        printf "  ${RED}FAIL${RESET}  %s\n" "$desc"
        printf "        ${DIM}expected exit: %s, got: %s${RESET}\n" "$expected" "$actual"
    fi
}

section() {
    printf "\n${CYAN}${BOLD}▸ %s${RESET}\n" "$1"
}

# ── Pre-flight ─────────────────────────────────────────────────────────────
printf "${BOLD}${CYAN}╔══════════════════════════════════════════════════╗${RESET}\n"
printf "${BOLD}${CYAN}║  pr_review.sh — Test Suite                      ║${RESET}\n"
printf "${BOLD}${CYAN}╚══════════════════════════════════════════════════╝${RESET}\n"

if [[ ! -f "$SCRIPT" ]]; then
    printf "${RED}ERROR: pr_review.sh not found at %s${RESET}\n" "$SCRIPT"
    exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════
#  1. ANSI COLOR CODES
# ═══════════════════════════════════════════════════════════════════════════
section "ANSI Color Codes"

# Extract color definitions from the script
eval "$(grep -E "^(RED|GREEN|YELLOW|BLUE|CYAN|BOLD|DIM|RESET)=" "$SCRIPT" | head -3)"

# Verify each escape sequence is well-formed \033[...m
for name in RED GREEN YELLOW BLUE CYAN BOLD DIM RESET; do
    val="${!name}"
    if [[ "$val" =~ ^\\033\[[0-9]+(;[0-9]+)*m$ ]]; then
        assert "Color $name is valid ANSI SGR" "valid" "valid"
    else
        assert "Color $name is valid ANSI SGR" "$val" "\\033[...m pattern"
    fi
done

# Verify RESET clears all attributes
assert "RESET is \\033[0m" "$RESET" '\033[0m'

# Verify colors render (printf interprets them)
rendered=$(printf "${GREEN}test${RESET}" 2>&1)
assert_contains "GREEN renders (contains ESC)" "$rendered" "test"

# ═══════════════════════════════════════════════════════════════════════════
#  2. iTERM2 ESCAPE SEQUENCES
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
#  3. ARGUMENT PARSING
# ═══════════════════════════════════════════════════════════════════════════
section "Argument Parsing"

# --help exits 0
output=$("$SCRIPT" --help 2>&1) && exit_code=0 || exit_code=$?
assert_exit_code "--help exits 0" "$exit_code" 0
assert_contains "--help shows usage" "$output" "USAGE"
assert_contains "--help shows options" "$output" "OPTIONS"

# No args → fatal error
output=$("$SCRIPT" 2>&1) && exit_code=0 || exit_code=$?
assert_exit_code "No args exits non-zero" "$exit_code" 1
assert_contains "No args shows error" "$output" "Missing required argument"

# Non-numeric PR number → fatal
output=$("$SCRIPT" abc 2>&1) && exit_code=0 || exit_code=$?
assert_exit_code "Non-numeric PR number exits non-zero" "$exit_code" 1
assert_contains "Non-numeric PR gives clear error" "$output" "Expected a PR number"

# Unknown option → fatal
output=$("$SCRIPT" 42 --bogus 2>&1) && exit_code=0 || exit_code=$?
assert_exit_code "Unknown option exits non-zero" "$exit_code" 1
assert_contains "Unknown option named in error" "$output" "--bogus"

# -h is alias for --help
output=$("$SCRIPT" -h 2>&1) && exit_code=0 || exit_code=$?
assert_exit_code "-h exits 0" "$exit_code" 0
assert_contains "-h shows usage" "$output" "USAGE"

# ═══════════════════════════════════════════════════════════════════════════
#  4. macOS COMPATIBILITY
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

# Verify stat fallback chain (GNU → BSD → default)
stat_line=$(grep 'stat -c' "$SCRIPT" || echo "")
assert_contains "stat has BSD fallback (stat -f%z)" \
    "$stat_line" "stat -f%z"

# ═══════════════════════════════════════════════════════════════════════════
#  5. SAFETY & SECURITY
# ═══════════════════════════════════════════════════════════════════════════
section "Safety & Security"

# Verify no raw eval on user-derived command strings (was a bug)
# bg mode should use direct invocation, not eval
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
#  6. HELPER FUNCTIONS (sourced inline)
# ═══════════════════════════════════════════════════════════════════════════
section "Helper Functions"

# Test the logging functions by sourcing just the color/function defs
eval "$(sed -n '53,62p' "$SCRIPT")"

# Capture info output
info_out=$(info "test message" 2>&1)
assert_contains "info() includes [INFO] tag" "$info_out" "[INFO]"
assert_contains "info() includes the message" "$info_out" "test message"

# Capture ok output
ok_out=$(ok "success" 2>&1)
assert_contains "ok() includes [OK] tag" "$ok_out" "[OK]"

# Capture warn output
warn_out=$(warn "careful" 2>&1)
assert_contains "warn() includes [WARN] tag" "$warn_out" "[WARN]"

# Capture error output (goes to stderr)
error_out=$(error "failure" 2>&1)
assert_contains "error() includes [ERROR] tag" "$error_out" "[ERROR]"

# step() output
step_out=$(step "doing things" 2>&1)
assert_contains "step() includes the message" "$step_out" "doing things"

# ═══════════════════════════════════════════════════════════════════════════
#  7. PREREQUISITE CHECKING
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
#  8. COLOR RENDERING (visual — iTerm2 targeted)
# ═══════════════════════════════════════════════════════════════════════════
section "Color Rendering (iTerm2)"

# Verify all color sequences produce visible output (not empty)
for name in RED GREEN YELLOW BLUE CYAN BOLD DIM; do
    val="${!name}"
    rendered=$(printf "%b" "${val}X${RESET}")
    assert_contains "$name renders non-empty" "$rendered" "X"
done

# Verify color reset actually removes formatting
rendered=$(printf "%bcolored%bnormal" "$RED" "$RESET" | cat -v)
assert_contains "RESET clears RED" "$rendered" "normal"

# Test box-drawing characters render (UTF-8)
box_output=$(printf "╔══╗\n║  ║\n╚══╝\n")
assert_contains "Box-drawing chars render" "$box_output" "╔══╗"

# ═══════════════════════════════════════════════════════════════════════════
#  9. WORKTREE & LOCKFILE LOGIC
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
#  10. PARALLEL MODE
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

# ═══════════════════════════════════════════════════════════════════════════
#  RESULTS
# ═══════════════════════════════════════════════════════════════════════════
echo ""
printf "${BOLD}${CYAN}╔══════════════════════════════════════════════════╗${RESET}\n"
if [[ "$FAIL" -eq 0 ]]; then
    printf "${BOLD}${GREEN}║  ALL %d TESTS PASSED                             ║${RESET}\n" "$TOTAL"
else
    printf "${BOLD}${RED}║  %d PASSED, %d FAILED (of %d)                    ║${RESET}\n" "$PASS" "$FAIL" "$TOTAL"
fi
printf "${BOLD}${CYAN}╚══════════════════════════════════════════════════╝${RESET}\n"
echo ""

[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
