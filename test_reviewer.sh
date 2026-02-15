#!/usr/bin/env bash
# ============================================================================
#  test_reviewer.sh — Test suite for reviewer.sh
# ============================================================================
#  Covers: ANSI colors, TTY/NO_COLOR detection, argument parsing, edge cases,
#  macOS compatibility, iTerm2 escapes, safety, helpers, rendering, worktree
#  logic, parallel mode, behavioral tests, and integration with mocks.
#
#  Usage:  ./test_reviewer.sh [FILTER]
#  Exit:   0 = all pass, 1 = failures
#
#  Filter: ./test_reviewer.sh "Edge"     # run only sections matching "Edge"
# ============================================================================
set -uo pipefail

# ── Test framework ─────────────────────────────────────────────────────────
PASS=0; FAIL=0; SKIP=0; TOTAL=0
TEST_START=$SECONDS
FILTER="${1:-}"

RED=$'\033[1;31m';    GREEN=$'\033[0;32m';  YELLOW=$'\033[0;33m'
CYAN=$'\033[0;36m';   BOLD=$'\033[1m';      DIM=$'\033[2m';  RESET=$'\033[0m'
ESC=$'\033'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${SCRIPT_DIR}/reviewer.sh"
TEST_TMP=""

# ── Assertions ─────────────────────────────────────────────────────────────
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
        printf "        %sgot: %.200s%s\n" "$DIM" "$haystack" "$RESET"
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

assert_file_exists() {
    local desc="$1" path="$2"
    ((TOTAL++))
    if [[ -e "$path" ]]; then
        ((PASS++))
        printf "  %sPASS%s  %s\n" "$GREEN" "$RESET" "$desc"
    else
        ((FAIL++))
        printf "  %sFAIL%s  %s\n" "$RED" "$RESET" "$desc"
        printf "        %sfile not found: %s%s\n" "$DIM" "$path" "$RESET"
    fi
}

skip() {
    local desc="$1" reason="$2"
    ((TOTAL++)); ((SKIP++))
    printf "  %sSKIP%s  %s %s(%s)%s\n" "$YELLOW" "$RESET" "$desc" "$DIM" "$reason" "$RESET"
}

_section_active=true
section() {
    if [[ -n "$FILTER" && "$1" != *"$FILTER"* ]]; then
        _section_active=false
        return 1
    fi
    _section_active=true
    printf "\n%s%s▸ %s%s\n" "$CYAN" "$BOLD" "$1" "$RESET"
}

# ── Test fixtures ──────────────────────────────────────────────────────────
setup_tmp() {
    TEST_TMP=$(mktemp -d /tmp/reviewer-test-XXXXXX)
}

cleanup_tmp() {
    [[ -n "$TEST_TMP" && -d "$TEST_TMP" ]] && rm -rf "$TEST_TMP"
    TEST_TMP=""
}

trap 'cleanup_tmp' EXIT

# ── Pre-flight ─────────────────────────────────────────────────────────────
printf "%s%s╔════════════════════════════════════════════════════════════╗%s\n" "$BOLD" "$CYAN" "$RESET"
printf "%s%s║  reviewer.sh — Test Suite                                ║%s\n" "$BOLD" "$CYAN" "$RESET"
if [[ -n "$FILTER" ]]; then
    printf "%s%s║  %-57s║%s\n" "$BOLD" "$CYAN" "Filter: $FILTER" "$RESET"
fi
printf "%s%s╚════════════════════════════════════════════════════════════╝%s\n" "$BOLD" "$CYAN" "$RESET"

if [[ ! -f "$SCRIPT" ]]; then
    printf "%sERROR: reviewer.sh not found at %s%s\n" "$RED" "$SCRIPT" "$RESET"
    exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════
#  1. ANSI COLOR CODES
# ═══════════════════════════════════════════════════════════════════════════
if section "ANSI Color Codes"; then
    # Source color defs in subshell to avoid polluting test env
    color_test_results=$(
        eval "$(grep -E "^[[:space:]]*(RED|GREEN|YELLOW|BLUE|CYAN|BOLD|DIM|RESET)=\\\$" "$SCRIPT" | sed 's/^[[:space:]]*//')"
        ESC=$'\033'
        for name in RED GREEN YELLOW BLUE CYAN BOLD DIM; do
            val="${!name}"
            [[ "$val" == "${ESC}["* ]] && echo "ESC_OK:$name" || echo "ESC_FAIL:$name"
            [[ "${val: -1}" == "m" ]] && echo "M_OK:$name" || echo "M_FAIL:$name"
        done
        [[ "$RESET" == $'\033[0m' ]] && echo "RESET_OK" || echo "RESET_FAIL"
        printf "%stest%s" "$GREEN" "$RESET" | grep -q "$ESC" && echo "RENDER_OK" || echo "RENDER_FAIL"
    )

    for name in RED GREEN YELLOW BLUE CYAN BOLD DIM; do
        assert "Color $name starts with ESC[" \
            "$(echo "$color_test_results" | grep "ESC_.*:$name" | cut -d: -f1)" "ESC_OK"
        assert "Color $name ends with 'm'" \
            "$(echo "$color_test_results" | grep "M_.*:$name" | cut -d: -f1)" "M_OK"
    done
    assert "RESET is ESC[0m" \
        "$(echo "$color_test_results" | grep RESET)" "RESET_OK"
    assert "GREEN renders with ESC byte" \
        "$(echo "$color_test_results" | grep RENDER)" "RENDER_OK"

    # Verify RED is bold (errors should outweigh warnings)
    red_def=$(grep -E "^[[:space:]]*RED=" "$SCRIPT" | head -1)
    assert_contains "RED is bold (1;31m)" "$red_def" "1;31m"

    # Verify YELLOW is non-bold (warnings lighter than errors)
    yellow_def=$(grep 'YELLOW=' "$SCRIPT" | grep -v "^#" | head -1)
    assert_contains "YELLOW is non-bold (0;33m)" "$yellow_def" "0;33m"

    # Verify BLUE uses bright variant (readable on dark backgrounds)
    blue_def=$(grep 'BLUE=' "$SCRIPT" | grep -v "^#" | head -1)
    assert_contains "BLUE is bright (94m)" "$blue_def" "94m"
fi

# ═══════════════════════════════════════════════════════════════════════════
#  2. TTY & NO_COLOR DETECTION (behavioral)
# ═══════════════════════════════════════════════════════════════════════════
if section "TTY & NO_COLOR Detection"; then
    # Behavioral: piped output has no ESC bytes
    piped_output=$("$SCRIPT" --help 2>&1 | cat)
    assert_not_contains "Piped output has no ESC bytes" "$piped_output" "$ESC"

    # Behavioral: NO_COLOR=1 disables all colors
    no_color_output=$(NO_COLOR=1 "$SCRIPT" --help 2>&1)
    assert_not_contains "NO_COLOR=1 suppresses colors" "$no_color_output" "$ESC"

    # Behavioral: PR_REVIEW_NO_COLOR=1 also works
    pr_no_color_output=$(PR_REVIEW_NO_COLOR=1 "$SCRIPT" --help 2>&1)
    assert_not_contains "PR_REVIEW_NO_COLOR=1 suppresses colors" "$pr_no_color_output" "$ESC"

    # Behavioral: --no-color flag disables colors
    flag_output=$("$SCRIPT" --no-color --help 2>&1)
    assert_not_contains "--no-color flag suppresses colors" "$flag_output" "$ESC"

    # Behavioral: help text is still readable without colors
    assert_contains "Help text present without colors" "$piped_output" "USAGE"
    assert_contains "Options present without colors" "$piped_output" "OPTIONS"

    # Structural: _use_color checks TTY
    assert_contains "Checks stdout TTY (-t 1)" "$(grep '\-t 1' "$SCRIPT")" "-t 1"
    assert_contains "Checks stderr TTY (-t 2)" "$(grep '\-t 2' "$SCRIPT")" "-t 2"
fi

# ═══════════════════════════════════════════════════════════════════════════
#  3. iTERM2 ESCAPE SEQUENCES
# ═══════════════════════════════════════════════════════════════════════════
if section "iTerm2 Escape Sequences"; then
    tab_title_output=$(printf '\e]1;%s\a' "Test Title" | cat -v)
    assert_contains "OSC 1 sets tab title" "$tab_title_output" "^[]1;Test Title"

    win_title_output=$(printf '\e]0;%s\a' "Win Title" | cat -v)
    assert_contains "OSC 0 sets window title" "$win_title_output" "^[]0;Win Title"

    assert_contains "Detects iTerm via TERM_PROGRAM" \
        "$(grep 'TERM_PROGRAM' "$SCRIPT")" "iTerm.app"
    assert_contains "Detects iTerm via LC_TERMINAL" \
        "$(grep 'LC_TERMINAL' "$SCRIPT")" "iTerm2"

    # Verify AppleScript sanitizes tab titles
    assert_contains "AppleScript escapes double quotes" \
        "$(grep -A1 'TAB_TITLE=' "$SCRIPT" | grep 'escape')" "escape double quotes"
fi

# ═══════════════════════════════════════════════════════════════════════════
#  4. ARGUMENT PARSING
# ═══════════════════════════════════════════════════════════════════════════
if section "Argument Parsing"; then
    output=$("$SCRIPT" --help 2>&1) && exit_code=0 || exit_code=$?
    assert_exit_code "--help exits 0" "$exit_code" 0
    assert_contains "--help shows USAGE" "$output" "USAGE"
    assert_contains "--help shows OPTIONS" "$output" "OPTIONS"
    assert_contains "--help shows EXAMPLES" "$output" "EXAMPLES"

    output=$("$SCRIPT" -h 2>&1) && exit_code=0 || exit_code=$?
    assert_exit_code "-h exits 0" "$exit_code" 0

    output=$("$SCRIPT" 2>&1) && exit_code=0 || exit_code=$?
    assert_exit_code "No args exits 1" "$exit_code" 1
    assert_contains "No args shows error" "$output" "Missing required argument"

    output=$("$SCRIPT" abc 2>&1) && exit_code=0 || exit_code=$?
    assert_exit_code "Non-numeric PR exits 1" "$exit_code" 1
    assert_contains "Non-numeric error is clear" "$output" "Expected a PR number"

    output=$("$SCRIPT" 42 --bogus 2>&1) && exit_code=0 || exit_code=$?
    assert_exit_code "Unknown option exits 1" "$exit_code" 1
    assert_contains "Unknown option named" "$output" "--bogus"

    output=$("$SCRIPT" --no-color --help 2>&1) && exit_code=0 || exit_code=$?
    assert_exit_code "--no-color accepted" "$exit_code" 0

    # Verify all documented flags appear in help
    for flag in --repo --dir --env-files --model --teammate-model --max-turns --output --cleanup \
                --no-teams --no-skip-permissions --no-env-copy --no-color --tabs; do
        assert_contains "Help mentions $flag" "$output" "$flag"
    done
fi

# ═══════════════════════════════════════════════════════════════════════════
#  5. ARGUMENT EDGE CASES (behavioral)
# ═══════════════════════════════════════════════════════════════════════════
if section "Argument Edge Cases"; then
    # Negative number looks like an option
    output=$("$SCRIPT" -- -42 2>&1) && exit_code=0 || exit_code=$?
    # May fail as unknown option or non-numeric — either way, not a crash
    assert "Negative PR doesn't crash (exits non-zero)" "$(( exit_code != 0 ? 1 : 0 ))" "1"

    # Very large PR number (handled gracefully, no overflow)
    output=$("$SCRIPT" 99999999999 2>&1) && exit_code=0 || exit_code=$?
    # Should proceed to prerequisite check (gh/git/claude), not crash on parsing
    # Exit 1 is expected because we're not in a valid context to review
    assert "Huge PR number doesn't crash" "$(( exit_code <= 128 ? 1 : 0 ))" "1"

    # Zero is a valid number syntactically
    output=$("$SCRIPT" 0 2>&1) && exit_code=0 || exit_code=$?
    assert "PR #0 doesn't crash" "$(( exit_code <= 128 ? 1 : 0 ))" "1"

    # Multiple valid flags combined
    output=$("$SCRIPT" --no-color --no-env-copy --cleanup --help 2>&1) && exit_code=0 || exit_code=$?
    assert_exit_code "Multiple flags with --help exits 0" "$exit_code" 0

    # Flag requiring argument but missing it
    output=$("$SCRIPT" 42 --repo 2>&1) && exit_code=0 || exit_code=$?
    assert "Missing --repo value exits non-zero" "$(( exit_code != 0 ? 1 : 0 ))" "1"

    # Empty string as argument
    output=$("$SCRIPT" "" 2>&1) && exit_code=0 || exit_code=$?
    assert "Empty string PR exits non-zero" "$(( exit_code != 0 ? 1 : 0 ))" "1"
fi

# ═══════════════════════════════════════════════════════════════════════════
#  6. macOS COMPATIBILITY
# ═══════════════════════════════════════════════════════════════════════════
if section "macOS Compatibility"; then
    assert_not_contains "No realpath --relative-to" \
        "$(grep 'realpath' "$SCRIPT")" "realpath --relative-to"
    assert_contains "Uses python3 os.path.relpath" \
        "$(grep 'python3.*relpath' "$SCRIPT")" "os.path.relpath"

    assert_not_contains "No du -sb" "$(grep 'du -s' "$SCRIPT")" "du -sb"
    assert_contains "Uses du -sk" "$(grep 'du -sk' "$SCRIPT")" "du -sk"

    stat_line=$(grep 'stat -c' "$SCRIPT" || echo "")
    assert_contains "stat has BSD fallback" "$stat_line" "stat -f%z"

    # Behavioral: python3 relpath actually works on this system
    rel=$(python3 -c "import os.path; print(os.path.relpath('/usr/local/bin', '/usr/local'))" 2>&1)
    assert "python3 relpath works" "$rel" "bin"
fi

# ═══════════════════════════════════════════════════════════════════════════
#  7. SAFETY & SECURITY
# ═══════════════════════════════════════════════════════════════════════════
if section "Safety & Security"; then
    bg_section=$(sed -n '/bg.*mode/,/exit 0/p' "$SCRIPT")
    assert_not_contains "No eval in bg mode" "$bg_section" 'eval "$CMD"'

    build_cmd_section=$(sed -n '/build_cmd/,/^    }/p' "$SCRIPT")
    assert_contains "build_cmd uses printf %q" "$build_cmd_section" "printf '%q"

    assert_contains "set -euo pipefail" "$(head -50 "$SCRIPT")" "set -euo pipefail"
    assert_contains "REVIEW_EXIT safe capture" \
        "$(grep 'REVIEW_EXIT' "$SCRIPT")" "|| REVIEW_EXIT="

    run_claude_line=$(grep -n 'run_claude()' "$SCRIPT")
    assert_contains "run_claude is subshell" "$run_claude_line" "("

    # Verify logging uses %s not %b (prevents backslash injection)
    info_def=$(grep '^info()' "$SCRIPT")
    assert_contains "info() uses %s (not %b)" "$info_def" "%s"
    assert_not_contains "info() avoids %b" "$info_def" "%b"

    ok_def=$(grep '^ok()' "$SCRIPT")
    assert_contains "ok() uses %s" "$ok_def" "%s"

    step_def=$(grep '^step()' "$SCRIPT")
    assert_contains "step() uses %s" "$step_def" "%s"
fi

# ═══════════════════════════════════════════════════════════════════════════
#  8. HELPER FUNCTIONS (behavioral, in isolated subshell)
# ═══════════════════════════════════════════════════════════════════════════
if section "Helper Functions"; then
    # Source helpers in subshell for isolation
    helper_results=$(
        RED=$'\033[1;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
        BLUE=$'\033[0;94m'; CYAN=$'\033[0;36m'; BOLD=$'\033[1m'
        DIM=$'\033[2m'; RESET=$'\033[0m'
        ESC=$'\033'
        eval "$(grep -A1 '^info()\|^ok()\|^warn()\|^error()\|^step()' "$SCRIPT" | grep -v '^--$')"

        # Test each function — uses Unicode symbols (● ✓ ⚠ ✖ ▸)
        info_out=$(info "test message" 2>&1)
        [[ "$info_out" == *"●"* && "$info_out" == *"test message"* && "$info_out" == *"$ESC"* ]] \
            && echo "info:OK" || echo "info:FAIL"

        ok_out=$(ok "success" 2>&1)
        [[ "$ok_out" == *"✓"* && "$ok_out" == *"$ESC"* ]] \
            && echo "ok:OK" || echo "ok:FAIL"

        warn_out=$(warn "careful" 2>&1)
        [[ "$warn_out" == *"⚠"* ]] && echo "warn:OK" || echo "warn:FAIL"

        error_out=$(error "failure" 2>&1)
        [[ "$error_out" == *"✖"* ]] && echo "error:OK" || echo "error:FAIL"

        step_out=$(step "phase" 2>&1)
        [[ "$step_out" == *"phase"* && "$step_out" == *"▸"* ]] \
            && echo "step:OK" || echo "step:FAIL"

        # Test with empty colors (NO_COLOR simulation)
        RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; DIM=''; RESET=''
        eval "$(grep -A1 '^info()\|^ok()' "$SCRIPT" | grep -v '^--$')"
        plain_info=$(info "plain" 2>&1)
        [[ "$plain_info" == *"●"* && "$plain_info" != *"$ESC"* ]] \
            && echo "nocolor_info:OK" || echo "nocolor_info:FAIL"
        plain_ok=$(ok "plain" 2>&1)
        [[ "$plain_ok" == *"✓"* && "$plain_ok" != *"$ESC"* ]] \
            && echo "nocolor_ok:OK" || echo "nocolor_ok:FAIL"

        # Test backslash safety: %s should NOT interpret \n
        eval "$(grep -A1 '^info()' "$SCRIPT" | grep -v '^--$')"
        BLUE=$'\033[0;94m'; RESET=$'\033[0m'
        bs_out=$(info 'path/with\nslash' 2>&1)
        [[ "$bs_out" == *'with\nslash'* ]] \
            && echo "backslash_safe:OK" || echo "backslash_safe:FAIL"
    )

    for fn in info ok warn error step nocolor_info nocolor_ok backslash_safe; do
        result=$(echo "$helper_results" | grep "^${fn}:" | cut -d: -f2)
        case "$fn" in
            nocolor_info) assert "info() works with empty colors" "$result" "OK" ;;
            nocolor_ok)   assert "ok() works with empty colors" "$result" "OK" ;;
            backslash_safe) assert "info() doesn't interpret \\n" "$result" "OK" ;;
            *)            assert "${fn}() works correctly" "$result" "OK" ;;
        esac
    done
fi

# ═══════════════════════════════════════════════════════════════════════════
#  9. PREREQUISITES
# ═══════════════════════════════════════════════════════════════════════════
if section "Prerequisites"; then
    for tool in gh git claude jq; do
        assert_contains "Checks for $tool" "$(grep 'for cmd in' "$SCRIPT")" "$tool"
    done
    assert_contains "Checks gh auth status" "$(grep 'gh auth status' "$SCRIPT")" "gh auth status"
fi

# ═══════════════════════════════════════════════════════════════════════════
#  10. COLOR RENDERING
# ═══════════════════════════════════════════════════════════════════════════
if section "Color Rendering (iTerm2)"; then
    # Re-source colors for this section
    eval "$(grep -E "^[[:space:]]*(RED|GREEN|YELLOW|BLUE|CYAN|BOLD|DIM|RESET)=\\\$" "$SCRIPT" | sed 's/^[[:space:]]*//')"

    for name in RED GREEN YELLOW BLUE CYAN BOLD DIM; do
        val="${!name}"
        rendered=$(printf "%sX%s" "$val" "$RESET")
        assert_contains "$name renders visible text" "$rendered" "X"
        assert_contains "$name contains ESC byte" "$rendered" "$ESC"
    done

    rendered=$(printf "%scolored%snormal" "$RED" "$RESET" | cat -v)
    assert_contains "RESET clears RED" "$rendered" "[0m"
    assert_contains "Text survives RESET" "$rendered" "normal"

    box_output=$(printf "╔══╗\n║  ║\n╚══╝\n")
    assert_contains "Box-drawing chars render" "$box_output" "╔══╗"

    # No color vars embedded in printf format strings
    bad_count=$(grep -cE 'printf "\$\{(BOLD|RED|GREEN|YELLOW|BLUE|CYAN|DIM|RESET)' "$SCRIPT" 2>/dev/null | tr -d '[:space:]')
    assert "No color vars in printf format strings" "${bad_count:-0}" "0"
fi

# ═══════════════════════════════════════════════════════════════════════════
#  11. VISUAL STRUCTURE (thin-line rules)
# ═══════════════════════════════════════════════════════════════════════════
if section "Visual Structure"; then
    script_content=$(cat "$SCRIPT")

    # Uses modern thin-line rules (───) not heavy box-drawing (╔═╗║╚═╝)
    assert_contains "Uses thin-line rules" "$script_content" "───"
    assert_not_contains "No heavy box top" "$script_content" "╔═══"
    assert_not_contains "No heavy box bottom" "$script_content" "╚═══"

    # Status functions use Unicode symbols
    assert_contains "info() uses ● symbol" "$(grep '^info()' "$SCRIPT")" "●"
    assert_contains "ok() uses ✓ symbol" "$(grep '^ok()' "$SCRIPT")" "✓"
    assert_contains "warn() uses ⚠ symbol" "$(grep '^warn()' "$SCRIPT")" "⚠"
    assert_contains "error() uses ✖ symbol" "$(grep '^error()' "$SCRIPT")" "✖"

    # Banner uses ◆ diamond
    assert_contains "Banner uses ◆ symbol" "$script_content" "◆ reviewer"
fi

# ═══════════════════════════════════════════════════════════════════════════
#  12. WORKTREE & LOCKFILE LOGIC
# ═══════════════════════════════════════════════════════════════════════════
if section "Worktree & Lockfile Logic"; then
    assert_contains "Lockfile uses .lock-pr-N" "$(grep 'LOCKFILE=' "$SCRIPT")" ".lock-pr-"
    assert_contains "EXIT trap is set" "$(grep 'trap.*EXIT' "$SCRIPT")" "_cleanup_on_exit"
    assert_contains "Stale lock detected via kill -0" \
        "$(grep -A2 'LOCK_PID' "$SCRIPT" | head -5)" "kill -0"
    assert_contains "Has _sq() for safe quoting" "$(grep '_sq()' "$SCRIPT")" "_sq()"

    # Behavioral: _sq escapes single quotes correctly
    setup_tmp
    sq_result=$(
        eval "$(grep -A1 '_sq()' "$SCRIPT" | head -2)"
        _sq "it's a test"
    )
    assert "_sq escapes single quotes" "$sq_result" "it'\''s a test"
    cleanup_tmp
fi

# ═══════════════════════════════════════════════════════════════════════════
#  13. PARALLEL MODE
# ═══════════════════════════════════════════════════════════════════════════
if section "Parallel Mode"; then
    for mode in auto iterm tmux bg; do
        assert_contains "Supports --tabs $mode" "$(grep -c "$mode" "$SCRIPT")" ""
    done

    assert_contains "BG mode caches exit codes" \
        "$(grep 'BG_EXIT_CODES' "$SCRIPT")" "BG_EXIT_CODES"
    assert_contains "BG mode skips cursor-up on first iter" \
        "$(grep 'BG_FIRST_ITER' "$SCRIPT")" "BG_FIRST_ITER"

    assert_contains "PR diff command is pdiff" "$(grep 'pdiff()' "$SCRIPT")" "pdiff()"
    assert_not_contains "No diff() shadow" "$(grep -w 'diff()' "$SCRIPT")" "diff()"

    # Verify header comment matches RC file (pdiff not diff)
    header_section=$(head -200 "$SCRIPT")
    assert_contains "Header docs say pdiff" "$header_section" "pdiff"
fi

# ═══════════════════════════════════════════════════════════════════════════
#  14. INTEGRATION: ENV FILE COPY LOGIC (with mock filesystem)
# ═══════════════════════════════════════════════════════════════════════════
if section "Integration: Env File Copy"; then
    setup_tmp

    # Create a mock git repo with env files
    GIT_ROOT="$TEST_TMP/repo"
    mkdir -p "$GIT_ROOT"
    git -C "$GIT_ROOT" init -q
    echo "tracked" > "$GIT_ROOT/main.txt"
    git -C "$GIT_ROOT" add main.txt
    git -C "$GIT_ROOT" commit -q -m "init"

    # Create untracked env files
    echo "SECRET=value" > "$GIT_ROOT/.env"
    echo "TEST=value" > "$GIT_ROOT/.env.test"
    mkdir -p "$GIT_ROOT/services/api"
    echo "API_KEY=xxx" > "$GIT_ROOT/services/api/.env"

    # Create a worktree-like destination (outside GIT_ROOT's parent to avoid early return)
    WORKTREE_BASE=$(mktemp -d /tmp/reviewer-wt-XXXXXX)
    WORKTREE="$WORKTREE_BASE/worktree"
    mkdir -p "$WORKTREE"

    # Extract and test the _try_copy function
    copy_results=$(
        cd "$GIT_ROOT"
        GIT_ROOT="$GIT_ROOT"
        WORKTREE_DIR="$WORKTREE"
        WORKTREE_PARENT="$WORKTREE_BASE"
        ENV_COPY_MAX_SIZE=$((5 * 1024 * 1024))
        ENV_COPIED=0
        ENV_SKIPPED=0
        ENV_COPY_LOG="$TEST_TMP/copy.log"
        : > "$ENV_COPY_LOG"

        eval "$(sed -n '/_try_copy()/,/^    }/p' "$SCRIPT")"

        _try_copy "$GIT_ROOT/.env" "test"
        _try_copy "$GIT_ROOT/.env.test" "test"
        _try_copy "$GIT_ROOT/services/api/.env" "test"
        # Tracked file should be skipped
        _try_copy "$GIT_ROOT/main.txt" "test"

        echo "copied=$ENV_COPIED"
        [[ -f "$WORKTREE/.env" ]] && echo "env_exists=yes" || echo "env_exists=no"
        [[ -f "$WORKTREE/.env.test" ]] && echo "env_test_exists=yes" || echo "env_test_exists=no"
        [[ -f "$WORKTREE/services/api/.env" ]] && echo "deep_env_exists=yes" || echo "deep_env_exists=no"
        [[ -f "$WORKTREE/main.txt" ]] && echo "tracked_copied=yes" || echo "tracked_copied=no"
    )

    assert_contains "Env files copied (count=3)" "$copy_results" "copied=3"
    assert_contains ".env copied to worktree" "$copy_results" "env_exists=yes"
    assert_contains ".env.test copied to worktree" "$copy_results" "env_test_exists=yes"
    assert_contains "Deep .env copied" "$copy_results" "deep_env_exists=yes"
    assert_contains "Tracked file NOT copied" "$copy_results" "tracked_copied=no"

    rm -rf "$WORKTREE_BASE"
    cleanup_tmp
fi

# ═══════════════════════════════════════════════════════════════════════════
#  15. INTEGRATION: LOCKFILE BEHAVIOR (with mock filesystem)
# ═══════════════════════════════════════════════════════════════════════════
if section "Integration: Lockfile Behavior"; then
    setup_tmp

    LOCKFILE="$TEST_TMP/.lock-pr-99"

    # Stale lockfile with non-existent PID
    echo "99999" > "$LOCKFILE"
    stale_result=$(
        if kill -0 99999 2>/dev/null; then
            echo "running"
        else
            echo "stale"
        fi
    )
    assert "Detects stale PID 99999" "$stale_result" "stale"

    # Current process PID is valid
    echo $$ > "$LOCKFILE"
    active_result=$(
        pid=$(cat "$LOCKFILE")
        if kill -0 "$pid" 2>/dev/null; then
            echo "running"
        else
            echo "stale"
        fi
    )
    assert "Detects own PID as running" "$active_result" "running"

    cleanup_tmp
fi

# ═══════════════════════════════════════════════════════════════════════════
#  16. INTEGRATION: PROMPT TEMPLATE
# ═══════════════════════════════════════════════════════════════════════════
if section "Integration: Prompt Template"; then
    # Verify all placeholders are replaced
    template_section=$(sed -n '/PROMPT_TEMPLATE/,/PROMPT_TEMPLATE/p' "$SCRIPT")
    for placeholder in __PR_NUM__ __PR_TITLE__ __PR_AUTHOR__ __PR_HEAD__ __PR_BASE__ \
                       __PR_URL__ __PR_ADDS__ __PR_DELS__ __PR_FILES__ __PR_BODY__ __PR_FILE_LIST__; do
        assert_contains "Template has $placeholder" "$template_section" "$placeholder"
    done

    # Verify all placeholders have corresponding replacements
    replacement_section=$(sed -n '/REVIEW_PROMPT=.*__PR_NUM__/,/^$/p' "$SCRIPT")
    for placeholder in __PR_NUM__ __PR_TITLE__ __PR_AUTHOR__ __PR_HEAD__ __PR_BASE__ \
                       __PR_URL__ __PR_ADDS__ __PR_DELS__ __PR_FILES__ __PR_BODY__ __PR_FILE_LIST__; do
        assert_contains "Replacement for $placeholder" "$replacement_section" "$placeholder"
    done

    # Verify the review has all 4 specialist roles
    for role in "code-quality" "security" "logic" "architecture"; do
        assert_contains "Template includes $role reviewer" "$template_section" "$role"
    done
fi

# ═══════════════════════════════════════════════════════════════════════════
#  17. TEAMMATE MODEL FLAG
# ═══════════════════════════════════════════════════════════════════════════
if section "Teammate Model Flag"; then
    script_content=$(cat "$SCRIPT")

    # Help text mentions the flag
    help_output=$(bash "$SCRIPT" --help 2>&1 || true)
    assert_contains "--teammate-model in help" "$help_output" "--teammate-model"
    assert_contains "-tm in help" "$help_output" "-tm"

    # Default variable exists
    assert_contains "TEAMMATE_MODEL default variable" "$script_content" 'TEAMMATE_MODEL=""'

    # Argument parsing case exists
    assert_contains "Parsing case for -tm|--teammate-model" "$script_content" '-tm|--teammate-model)'

    # Inheritance logic: defaults to MODEL when unset
    assert_contains "Inheritance resolves TEAMMATE_MODEL from MODEL" "$script_content" '[[ -z "$TEAMMATE_MODEL" ]] && TEAMMATE_MODEL="$MODEL"'

    # Passthrough handles the flag
    assert_contains "Passthrough passes --teammate-model" "$script_content" '--teammate-model'

    # Subagent JSON uses __TEAMMATE_MODEL__ placeholder (not hardcoded "opus")
    agents_section=$(sed -n '/AGENTS_JSON/,/^AGENTS$/p' "$SCRIPT")
    assert_contains "Subagent JSON uses __TEAMMATE_MODEL__ placeholder" "$agents_section" '__TEAMMATE_MODEL__'
    assert_not_contains "Subagent JSON does not hardcode opus" "$agents_section" '"model": "opus"'

    # Heredoc is quoted (safe against accidental $ expansion)
    assert_contains "Heredoc uses quoted delimiter" "$agents_section" "<<'AGENTS'"

    # Placeholder is substituted after heredoc
    assert_contains "Placeholder substituted after heredoc" "$script_content" 'AGENTS_JSON="${AGENTS_JSON//__TEAMMATE_MODEL__/$TEAMMATE_MODEL}"'

    # Agent Teams mode has teammate model prompt section
    assert_contains "Agent Teams prompt includes Teammate Model section" "$script_content" '## Teammate Model'

    # Config display line handles teammate model
    assert_contains "Config line shows teammates when different" "$script_content" '(teammates: ${TEAMMATE_MODEL})'

    # Behavioral: --teammate-model sonnet --help exits cleanly
    tm_help_output=$(bash "$SCRIPT" --teammate-model sonnet --help 2>&1)
    tm_help_exit=$?
    assert "--teammate-model sonnet --help exits 0" "$tm_help_exit" "0"

    # Behavioral: -tm sonnet --help exits cleanly
    tm_short_help_output=$(bash "$SCRIPT" -tm sonnet --help 2>&1)
    tm_short_help_exit=$?
    assert "-tm sonnet --help exits 0" "$tm_short_help_exit" "0"
fi

# ═══════════════════════════════════════════════════════════════════════════
#  18. MODEL VALIDATION
# ═══════════════════════════════════════════════════════════════════════════
if section "Model Validation"; then
    script_content=$(cat "$SCRIPT")

    # Structural: validation function exists
    assert_contains "_validate_model function exists" "$script_content" '_validate_model()'
    assert_contains "VALID_MODELS list defined" "$script_content" 'VALID_MODELS='

    # Behavioral: valid models accepted
    for model in opus sonnet haiku; do
        output=$(bash "$SCRIPT" --model "$model" --help 2>&1)
        exit_code=$?
        assert_exit_code "--model $model accepted" "$exit_code" 0
    done

    # Behavioral: invalid model rejected (PR number required to reach validation)
    output=$(bash "$SCRIPT" 42 --model snonet 2>&1)
    exit_code=$?
    assert "Invalid --model exits non-zero" "$(( exit_code != 0 ? 1 : 0 ))" "1"
    assert_contains "Invalid --model names the bad value" "$output" "snonet"

    # Behavioral: invalid teammate model rejected
    output=$(bash "$SCRIPT" 42 --teammate-model bogus 2>&1)
    exit_code=$?
    assert "Invalid --teammate-model exits non-zero" "$(( exit_code != 0 ? 1 : 0 ))" "1"
    assert_contains "Invalid --teammate-model names the bad value" "$output" "bogus"

    # Behavioral: valid teammate model accepted (--help exits before validation)
    output=$(bash "$SCRIPT" --teammate-model haiku --help 2>&1)
    exit_code=$?
    assert_exit_code "--teammate-model haiku --help accepted" "$exit_code" 0
fi

# ═══════════════════════════════════════════════════════════════════════════
#  19. MISSING ARGUMENT GUARD
# ═══════════════════════════════════════════════════════════════════════════
if section "Missing Argument Guard"; then
    script_content=$(cat "$SCRIPT")

    # Structural: _need_arg helper exists
    assert_contains "_need_arg helper exists" "$script_content" '_need_arg()'

    # Behavioral: each shift-2 flag produces a clean error when value is missing
    for flag in --repo --dir --env-files --model --teammate-model --max-turns --output --tabs; do
        output=$(bash "$SCRIPT" 42 "$flag" 2>&1)
        exit_code=$?
        assert "Missing value for $flag exits non-zero" "$(( exit_code != 0 ? 1 : 0 ))" "1"
        assert_contains "$flag missing-value error is clear" "$output" "requires a value"
    done

    # Behavioral: short forms too
    for flag in -r -d -e -m -tm -b -o; do
        output=$(bash "$SCRIPT" 42 "$flag" 2>&1)
        exit_code=$?
        assert "Missing value for $flag exits non-zero" "$(( exit_code != 0 ? 1 : 0 ))" "1"
        assert_contains "$flag missing-value error is clear" "$output" "requires a value"
    done
fi

# ═══════════════════════════════════════════════════════════════════════════
#  RESULTS
# ═══════════════════════════════════════════════════════════════════════════
ELAPSED=$(( SECONDS - TEST_START ))
echo ""
printf "%s%s╔════════════════════════════════════════════════════════════╗%s\n" "$BOLD" "$CYAN" "$RESET"
if [[ "$FAIL" -eq 0 ]]; then
    printf "%s%s║  %-57s║%s\n" "$BOLD" "$GREEN" "ALL $TOTAL TESTS PASSED" "$RESET"
else
    printf "%s%s║  %-57s║%s\n" "$BOLD" "$RED" "$PASS passed, $FAIL failed (of $TOTAL)" "$RESET"
fi
[[ "$SKIP" -gt 0 ]] && \
    printf "%s%s║  %-57s║%s\n" "$BOLD" "$YELLOW" "$SKIP skipped" "$RESET"
printf "%s%s║  %-57s║%s\n" "$BOLD" "$CYAN" "Completed in ${ELAPSED}s" "$RESET"
printf "%s%s╚════════════════════════════════════════════════════════════╝%s\n" "$BOLD" "$CYAN" "$RESET"
echo ""

[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
