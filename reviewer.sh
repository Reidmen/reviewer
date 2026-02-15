#!/usr/bin/env bash
# ============================================================================
#  reviewer.sh — AI-powered PR code review with Claude Code agent teams
# ============================================================================
#
#  Usage:  reviewer.sh <PR_NUMBER...> [OPTIONS]
#
#  Checks out a PR into an isolated git worktree (~/.reviewer/pr-<N>/),
#  copies untracked env/config files so tests work, then launches Claude Code
#  with 4 specialist reviewers (code quality, security, logic, architecture).
#
#  Requirements:  brew install gh jq claude && gh auth login
#
#  See --help for full options and examples.
# ============================================================================
set -euo pipefail

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# ── Colours & formatting ────────────────────────────────────────────────────
# Detect whether to use color: respect NO_COLOR (https://no-color.org),
# --no-color flag, and non-TTY output (piped/redirected).
_use_color() {
    [[ -n "${NO_COLOR:-}" ]] && return 1
    [[ -n "${PR_REVIEW_NO_COLOR:-}" ]] && return 1
    [[ -t 1 ]] || return 1   # stdout is not a TTY
    [[ -t 2 ]] || return 1   # stderr is not a TTY
    return 0
}

# $'...' ANSI-C quoting: variables contain actual ESC bytes.
# Works with printf %s, echo, and string concatenation — not just printf format.
if _use_color; then
    RED=$'\033[1;31m';    GREEN=$'\033[0;32m';  YELLOW=$'\033[0;33m'
    BLUE=$'\033[0;94m';   CYAN=$'\033[0;36m';   BOLD=$'\033[1m'
    DIM=$'\033[2m';       RESET=$'\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; DIM=''; RESET=''
fi

info()  { printf "  %s●%s  %s\n" "$BLUE" "$RESET" "$*"; }
ok()    { printf "  %s✓%s  %s\n" "$GREEN" "$RESET" "$*"; }
warn()  { printf "  %s⚠%s  %s\n" "$YELLOW" "$RESET" "$*"; }
error() { printf "  %s✖%s  %s\n" "$RED" "$RESET" "$*" >&2; }
fatal() { error "$@"; exit 1; }
step()  { printf "\n  %s%s▸ %s%s\n" "$CYAN" "$BOLD" "$*" "$RESET"; }


# ── Defaults ────────────────────────────────────────────────────────────────
PR_NUMBERS=()
REPO=""
WORKTREE_PARENT=""
MODEL="opus"
TEAMMATE_MODEL=""       # Default: inherit lead model
MAX_TURNS="50"
OUTPUT_FILE=""
CLEANUP=false
USE_TEAMS=true
SKIP_PERMISSIONS=true
COPY_ENV=true
EXTRA_ENV_PATTERNS=""
TAB_MODE="auto"                 # auto | iterm | tmux | bg
_SINGLE_MODE=false              # internal: set when re-invoked per-PR

# Files commonly gitignored but required to build/test.
DEFAULT_ENV_PATTERNS=(
    ".env" ".env.local" ".env.development" ".env.development.local"
    ".env.test" ".env.test.local" ".env.production.local" ".env.docker"
    ".npmrc" ".yarnrc" ".yarnrc.yml" ".pnp.cjs" ".pnp.loader.mjs"
    ".python-version" "pyrightconfig.json"
    ".ruby-version" "config/master.key" "config/credentials.yml.enc"
    "local.properties" ".air.toml"
    "docker-compose.override.yml" ".docker/config.json"
    ".vscode/settings.json" ".vscode/launch.json" ".idea/workspace.xml"
    "*.auto.tfvars" "terraform.tfvars"
    ".tool-versions" "Procfile.dev"
)
ENV_COPY_MAX_SIZE=$((5 * 1024 * 1024))  # 5 MB per file

# ── Parse arguments ─────────────────────────────────────────────────────────
usage() {
    local B="$BOLD" C="$CYAN" D="$DIM" G="$GREEN" R="$RESET"
    printf "\n"
    printf "  %s%s◆ reviewer%s  %s· AI-powered code review with Claude%s\n" "$B" "$C" "$R" "$D" "$R"
    printf "\n"
    printf "  %s%sUSAGE%s\n" "$B" "$C" "$R"
    printf "    reviewer.sh <PR_NUMBER...> [OPTIONS]\n"
    printf "\n"
    printf "    Run from inside any git repo with a GitHub remote. The script auto-detects\n"
    printf "    the repository, fetches the PR, and creates an isolated worktree.\n"
    printf "\n"
    printf "  %s%sEXAMPLES%s\n" "$B" "$C" "$R"
    printf "    %sreviewer.sh 42%s                                %s# review a PR%s\n"                    "$B" "$R" "$D" "$R"
    printf "    %sreviewer.sh 42 43 44%s                          %s# three PRs in parallel tabs%s\n"     "$B" "$R" "$D" "$R"
    printf "    %sreviewer.sh 42 --max-turns 75 --cleanup%s       %s# deeper review, auto-cleanup%s\n"    "$B" "$R" "$D" "$R"
    printf "    %sreviewer.sh 42 -o review.md%s                   %s# save to file (non-interactive)%s\n" "$B" "$R" "$D" "$R"
    printf "    %sreviewer.sh 42 --repo myorg/myrepo%s            %s# review a PR from another repo%s\n"  "$B" "$R" "$D" "$R"
    printf "    %sreviewer.sh 42 -m opus -tm sonnet%s             %s# opus lead, sonnet teammates%s\n"    "$B" "$R" "$D" "$R"
    printf "    %sreviewer.sh 42 -e \".env.staging\" --no-teams%s   %s# custom env, subagent mode%s\n"    "$B" "$R" "$D" "$R"
    printf "    %sNO_COLOR=1 reviewer.sh 42 -o out.md%s           %s# plain output for CI pipelines%s\n"  "$B" "$R" "$D" "$R"
    printf "\n"
    printf "  %s%sOPTIONS%s\n" "$B" "$C" "$R"
    printf "    %sCore%s\n" "$D" "$R"
    printf "      %s-r, --repo%s <owner/repo>  Target repository %s(default: auto-detected)%s\n"        "$B" "$R" "$D" "$R"
    printf "      %s-m, --model%s <model>      Claude model for lead agent %s(default: opus)%s\n"       "$B" "$R" "$D" "$R"
    printf "      %s-tm, --teammate-model%s <model>\n"                                                  "$B" "$R"
    printf "                               Model for teammate agents %s(default: same as --model)%s\n"  "$D" "$R"
    printf "      %s-b, --max-turns%s <N>      Max agentic turns per PR %s(default: 50, range: 30–75)%s\n" "$B" "$R" "$D" "$R"
    printf "      %s-h, --help%s               Show this help\n"                                        "$B" "$R"
    printf "\n"
    printf "    %sOutput%s\n" "$D" "$R"
    printf "      %s-o, --output%s <path>      Write review to file %s(non-interactive, single-PR)%s\n" "$B" "$R" "$D" "$R"
    printf "      %s-c, --cleanup%s            Remove worktree after review completes\n"                "$B" "$R"
    printf "      %s--no-color%s               Disable colors %s(also: NO_COLOR=1, PR_REVIEW_NO_COLOR=1)%s\n" "$B" "$R" "$D" "$R"
    printf "\n"
    printf "    %sAgent%s\n" "$D" "$R"
    printf "      %s-t, --no-teams%s           Use subagents instead of agent teams\n"                  "$B" "$R"
    printf "      %s--no-skip-permissions%s    Require manual approval for each tool use\n"             "$B" "$R"
    printf "\n"
    printf "    %sEnvironment%s\n" "$D" "$R"
    printf "      %s-e, --env-files%s <globs>  Extra file patterns to copy %s(comma-separated)%s\n"     "$B" "$R" "$D" "$R"
    printf "                               Example: -e \".env.staging,config/local.yml\"\n"
    printf "      %s--no-env-copy%s            Skip copying .env and config files into worktree\n"      "$B" "$R"
    printf "\n"
    printf "    %sTerminal%s\n" "$D" "$R"
    printf "      %s-d, --dir%s <path>         Worktree parent directory %s(default: ~/.reviewer/)%s\n" "$B" "$R" "$D" "$R"
    printf "      %s--tabs%s <mode>            Parallel mode: auto | iterm | tmux | bg\n"               "$B" "$R"
    printf "\n"
    printf "  %s%sPARALLEL REVIEWS%s\n" "$B" "$C" "$R"
    printf "    Pass 2+ PR numbers and the terminal is auto-detected:\n"
    printf "\n"
    printf "      %siTerm2%s    Named tabs, navigate with %s⌘+←/→%s or %s⌘+1-9%s\n"                   "$G" "$R" "$B" "$R" "$B" "$R"
    printf "      %stmux%s      Named windows in a session, %sCtrl+B n/p%s or %sCtrl+B w%s\n"          "$G" "$R" "$B" "$R" "$B" "$R"
    printf "      %sOther%s     Background processes with live status dashboard\n"                      "$G" "$R"
    printf "\n"
    printf "    Override: %sreviewer.sh 42 43 --tabs tmux%s\n" "$B" "$R"
    printf "\n"
    printf "    Each completed tab provides quick commands:\n"
    printf "      %sreview%s    Re-display the review      %spdiff%s    View the PR diff\n"             "$B" "$R" "$B" "$R"
    printf "      %sfiles%s     PR metadata & file list    %sexit%s     Close the tab\n"                "$B" "$R" "$B" "$R"
    printf "\n"
    printf "  %s%sENVIRONMENT FILES%s\n" "$B" "$C" "$R"
    printf "    Git worktrees only contain tracked files. The script copies common untracked\n"
    printf "    files (.env, .npmrc, config/master.key, …) so tests and builds work.\n"
    printf "    Add custom patterns: %s-e \".env.staging,secrets/local.json\"%s\n" "$B" "$R"
    printf "    Skip entirely: %s--no-env-copy%s\n" "$B" "$R"
    printf "    Manifest: %s~/.reviewer/pr-<N>/.pr-review-context/env-files-copied.log%s\n" "$D" "$R"
    printf "\n"
    printf "  %s%sOUTPUT%s\n" "$B" "$C" "$R"
    printf "    Reviews are saved to: %s~/.reviewer/pr-<N>/.pr-review-context/REVIEW.md%s\n" "$D" "$R"
    printf "    With %s-o <path>%s, also written to the specified file.\n" "$B" "$R"
    printf "\n"
    printf "  %s%sREQUIREMENTS%s\n" "$B" "$C" "$R"
    printf "    brew install gh jq claude && gh auth login\n"
    printf "\n"
    exit 0
}

_need_arg() { [[ $# -ge 2 && -n "${2:-}" ]] || fatal "$1 requires a value"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)             usage ;;
        -r|--repo)             _need_arg "$@"; REPO="$2"; shift 2 ;;
        -d|--dir)              _need_arg "$@"; WORKTREE_PARENT="$2"; shift 2 ;;
        -e|--env-files)        _need_arg "$@"; EXTRA_ENV_PATTERNS="$2"; shift 2 ;;
        -m|--model)            _need_arg "$@"; MODEL="$2"; shift 2 ;;
        -tm|--teammate-model)  _need_arg "$@"; TEAMMATE_MODEL="$2"; shift 2 ;;
        -b|--max-turns)        _need_arg "$@"; MAX_TURNS="$2"; shift 2 ;;
        -o|--output)           _need_arg "$@"; OUTPUT_FILE="$2"; shift 2 ;;
        -c|--cleanup)          CLEANUP=true; shift ;;
        -t|--no-teams)         USE_TEAMS=false; shift ;;
        --no-skip-permissions) SKIP_PERMISSIONS=false; shift ;;
        --no-env-copy)         COPY_ENV=false; shift ;;
        --no-color)            export NO_COLOR=1; RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; DIM=''; RESET=''; shift ;;
        --tabs)                _need_arg "$@"; TAB_MODE="$2"; shift 2 ;;
        --_single)             _SINGLE_MODE=true; shift ;;
        -*)                    fatal "Unknown option: $1  (use --help)" ;;
        *)
            # Accept any number of positional args as PR numbers
            if [[ "$1" =~ ^[0-9]+$ ]]; then
                PR_NUMBERS+=("$1"); shift
            else
                fatal "Expected a PR number, got: $1"
            fi ;;
    esac
done
[[ -z "$TEAMMATE_MODEL" ]] && TEAMMATE_MODEL="$MODEL"
[[ ${#PR_NUMBERS[@]} -eq 0 ]] && fatal "Missing required argument: PR number(s). Usage: $(basename "$0") <PR_NUMBER...> [OPTIONS]"

# ── Validate model names ──────────────────────────────────────────────────
VALID_MODELS="opus sonnet haiku"
_validate_model() {
    local flag="$1" value="$2"
    # shellcheck disable=SC2076
    if [[ ! " $VALID_MODELS " =~ " $value " ]]; then
        fatal "Invalid model for $flag: '${value}'. Valid models: ${VALID_MODELS}"
    fi
}
_validate_model "--model" "$MODEL"
_validate_model "--teammate-model" "$TEAMMATE_MODEL"

# ── Opening banner (shown once, before any work) ─────────────────────────
if [[ "$_SINGLE_MODE" == false ]]; then
    echo ""
    printf "  %s%s◆ reviewer%s  %s· AI-powered code review with Claude%s\n" "$BOLD" "$CYAN" "$RESET" "$DIM" "$RESET"
fi

# ═══════════════════════════════════════════════════════════════════════════
#  MULTI-PR ORCHESTRATION
# ═══════════════════════════════════════════════════════════════════════════
# When multiple PR numbers are given, open each in a separate tab/window
# and re-invoke this script in single-PR mode inside each one.
# ═══════════════════════════════════════════════════════════════════════════

if [[ ${#PR_NUMBERS[@]} -gt 1 && "$_SINGLE_MODE" == false ]]; then
    step "Parallel review: ${#PR_NUMBERS[@]} PRs → ${PR_NUMBERS[*]}"

    # Build the common flags to pass through to each child invocation
    PASSTHROUGH_ARGS=()
    [[ -n "$REPO" ]]              && PASSTHROUGH_ARGS+=("--repo" "$REPO")
    [[ -n "$WORKTREE_PARENT" ]]   && PASSTHROUGH_ARGS+=("--dir" "$WORKTREE_PARENT")
    [[ -n "$EXTRA_ENV_PATTERNS" ]]&& PASSTHROUGH_ARGS+=("--env-files" "$EXTRA_ENV_PATTERNS")
    [[ "$MODEL" != "opus" ]]    && PASSTHROUGH_ARGS+=("--model" "$MODEL")
    [[ "$TEAMMATE_MODEL" != "$MODEL" ]] && PASSTHROUGH_ARGS+=("--teammate-model" "$TEAMMATE_MODEL")
    [[ "$MAX_TURNS" != "50" ]]     && PASSTHROUGH_ARGS+=("--max-turns" "$MAX_TURNS")
    [[ "$CLEANUP" == true ]]      && PASSTHROUGH_ARGS+=("--cleanup")
    [[ "$USE_TEAMS" == false ]]   && PASSTHROUGH_ARGS+=("--no-teams")
    [[ "$SKIP_PERMISSIONS" == false ]] && PASSTHROUGH_ARGS+=("--no-skip-permissions")
    [[ "$COPY_ENV" == false ]]    && PASSTHROUGH_ARGS+=("--no-env-copy")

    # ── Detect terminal environment ────────────────────────────────────
    detect_tab_mode() {
        if [[ "$TAB_MODE" != "auto" ]]; then
            echo "$TAB_MODE"
            return
        fi
        # Check iTerm2
        if [[ "${TERM_PROGRAM:-}" == "iTerm.app" ]] || [[ "${LC_TERMINAL:-}" == "iTerm2" ]]; then
            echo "iterm"
            return
        fi
        # Check tmux
        if [[ -n "${TMUX:-}" ]] || command -v tmux &>/dev/null; then
            echo "tmux"
            return
        fi
        echo "bg"
    }

    RESOLVED_TAB_MODE=$(detect_tab_mode)
    info "Terminal mode: ${BOLD}${RESOLVED_TAB_MODE}${RESET}"

    # ── Fetch PR titles for tab naming ─────────────────────────────────
    declare -A PR_TITLES
    EFFECTIVE_REPO="$REPO"
    if [[ -z "$EFFECTIVE_REPO" ]]; then
        EFFECTIVE_REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo "")
    fi
    for pr in "${PR_NUMBERS[@]}"; do
        title=$(gh pr view "$pr" ${EFFECTIVE_REPO:+--repo "$EFFECTIVE_REPO"} --json title -q '.title' 2>/dev/null || echo "PR #${pr}")
        # Truncate for tab display
        PR_TITLES[$pr]="${title:0:40}"
        info "PR #${pr}: ${PR_TITLES[$pr]}"
    done

    # ── Build per-PR command string ────────────────────────────────────
    build_cmd() {
        local pr="$1"
        printf '%q %q --_single' "${SCRIPT_PATH}" "${pr}"
        if [[ ${#PASSTHROUGH_ARGS[@]} -gt 0 ]]; then
            printf ' %q' "${PASSTHROUGH_ARGS[@]}"
        fi
        echo
    }

    # ════════════════════════════════════════════════════════════════════
    #  iTerm2: one tab per PR with named titles
    # ════════════════════════════════════════════════════════════════════
    if [[ "$RESOLVED_TAB_MODE" == "iterm" ]]; then
        ok "Opening ${#PR_NUMBERS[@]} iTerm2 tabs"

        for pr in "${PR_NUMBERS[@]}"; do
            TAB_TITLE="PR #${pr} — ${PR_TITLES[$pr]}"
            TAB_TITLE="${TAB_TITLE//\"/\\\"}"  # escape double quotes for AppleScript
            CMD=$(build_cmd "$pr")
            osascript <<APPLESCRIPT
tell application "iTerm2"
    activate
    tell current window
        set newTab to (create tab with default profile)
        tell current session of newTab
            set name to "${TAB_TITLE}"
            write text "printf '\\\\e]1;${TAB_TITLE}\\\\a'; ${CMD}"
        end tell
    end tell
end tell
APPLESCRIPT
            ok "Tab opened: ${TAB_TITLE}"
            sleep 0.3  # small delay to avoid AppleScript race
        done

        echo ""
        printf "  %s%s───────────────────────────────────────────────────────%s\n" "$BOLD" "$CYAN" "$RESET"
        printf "  %s%s  ${#PR_NUMBERS[@]} reviews launched in iTerm2 tabs%s\n" "$BOLD" "$GREEN" "$RESET"
        echo ""
        printf "  %sNavigation:%s\n" "$DIM" "$RESET"
        printf "    %s⌘ + ←/→%s         Switch between tabs\n" "$BOLD" "$RESET"
        printf "    %s⌘ + 1-9%s         Jump to tab by number\n" "$BOLD" "$RESET"
        printf "    %s⌘ + Shift + ]%s   Next tab\n" "$BOLD" "$RESET"
        printf "  %s%s───────────────────────────────────────────────────────%s\n" "$BOLD" "$CYAN" "$RESET"
        echo ""
        for i in "${!PR_NUMBERS[@]}"; do
            printf "    %s%s%d%s  PR #%s%s%s — %s%s\n" "$DIM" "$CYAN" "$((i+1))" "$RESET" "$BOLD" "${PR_NUMBERS[$i]}" "$RESET" "${PR_TITLES[${PR_NUMBERS[$i]}]}" "$RESET"
        done
        exit 0

    # ════════════════════════════════════════════════════════════════════
    #  tmux: named windows in a dedicated session
    # ════════════════════════════════════════════════════════════════════
    elif [[ "$RESOLVED_TAB_MODE" == "tmux" ]]; then
        SESSION_NAME="pr-reviews-$(date +%H%M%S)"
        ok "Creating tmux session: ${SESSION_NAME}"

        # Create session with the first PR
        FIRST_PR="${PR_NUMBERS[0]}"
        FIRST_CMD=$(build_cmd "$FIRST_PR")
        FIRST_TITLE="PR #${FIRST_PR} — ${PR_TITLES[$FIRST_PR]}"

        tmux new-session -d -s "$SESSION_NAME" -n "$FIRST_TITLE"
        tmux send-keys -t "${SESSION_NAME}:0" "$FIRST_CMD" Enter

        # Create windows for remaining PRs
        for i in $(seq 1 $((${#PR_NUMBERS[@]} - 1))); do
            pr="${PR_NUMBERS[$i]}"
            CMD=$(build_cmd "$pr")
            WIN_TITLE="PR #${pr} — ${PR_TITLES[$pr]}"

            tmux new-window -t "$SESSION_NAME" -n "$WIN_TITLE"
            tmux send-keys -t "${SESSION_NAME}:${i}" "$CMD" Enter
        done

        echo ""
        printf "  %s%s───────────────────────────────────────────────────────%s\n" "$BOLD" "$CYAN" "$RESET"
        printf "  %s%s  ${#PR_NUMBERS[@]} reviews in tmux: ${SESSION_NAME}%s\n" "$BOLD" "$GREEN" "$RESET"
        echo ""
        printf "  %sNavigation:%s\n" "$DIM" "$RESET"
        printf "    %sCtrl+B  n%s       Next window\n" "$BOLD" "$RESET"
        printf "    %sCtrl+B  p%s       Previous window\n" "$BOLD" "$RESET"
        printf "    %sCtrl+B  0-9%s     Jump to window by number\n" "$BOLD" "$RESET"
        printf "    %sCtrl+B  w%s       Interactive window picker\n" "$BOLD" "$RESET"
        printf "  %s%s───────────────────────────────────────────────────────%s\n" "$BOLD" "$CYAN" "$RESET"
        echo ""
        for i in "${!PR_NUMBERS[@]}"; do
            printf "    %s%s%d%s  PR #%s%s%s — %s%s\n" "$DIM" "$CYAN" "$i" "$RESET" "$BOLD" "${PR_NUMBERS[$i]}" "$RESET" "${PR_TITLES[${PR_NUMBERS[$i]}]}" "$RESET"
        done
        echo ""

        # Attach to the session if not already inside tmux
        if [[ -z "${TMUX:-}" ]]; then
            info "Attaching to tmux session..."
            exec tmux attach -t "$SESSION_NAME"
        else
            info "Already in tmux. Switch with: tmux switch -t ${SESSION_NAME}"
        fi
        exit 0

    # ════════════════════════════════════════════════════════════════════
    #  Background mode: processes with a status watcher
    # ════════════════════════════════════════════════════════════════════
    elif [[ "$RESOLVED_TAB_MODE" == "bg" ]]; then
        ok "Launching ${#PR_NUMBERS[@]} reviews as background processes"

        LOG_DIR="${WORKTREE_PARENT:-${HOME}/.reviewer}"
        mkdir -p "$LOG_DIR"

        declare -A BG_PIDS
        declare -A BG_EXIT_CODES
        for pr in "${PR_NUMBERS[@]}"; do
            LOG_FILE="${LOG_DIR}/pr-${pr}-review.log"
            "${SCRIPT_PATH}" "${pr}" --_single ${PASSTHROUGH_ARGS[@]+"${PASSTHROUGH_ARGS[@]}"} > "$LOG_FILE" 2>&1 &
            BG_PIDS[$pr]=$!
            info "PR #${pr} → PID ${BG_PIDS[$pr]}  (log: ${LOG_FILE})"
        done

        echo ""
        printf "  %s%s───────────────────────────────────────────────────────%s\n" "$BOLD" "$CYAN" "$RESET"
        printf "  %s%s  ${#PR_NUMBERS[@]} reviews running in background%s\n" "$BOLD" "$GREEN" "$RESET"
        echo ""
        printf "  %sTip: install iTerm2 or tmux for tabbed parallel reviews%s\n" "$DIM" "$RESET"
        printf "  %s%s───────────────────────────────────────────────────────%s\n" "$BOLD" "$CYAN" "$RESET"
        echo ""

        # Live status watcher
        info "Monitoring progress (Ctrl+C to detach — reviews continue)..."
        echo ""
        TRAP_FIRED=false
        trap 'TRAP_FIRED=true' INT

        BG_FIRST_ITER=true
        while true; do
            ALL_DONE=true
            # Move cursor up to overwrite previous status (skip on first iteration)
            if [[ "$BG_FIRST_ITER" == true ]]; then
                BG_FIRST_ITER=false
            else
                printf "\033[${#PR_NUMBERS[@]}A" 2>/dev/null || true
            fi

            for pr in "${PR_NUMBERS[@]}"; do
                pid="${BG_PIDS[$pr]}"
                LOG_FILE="${LOG_DIR}/pr-${pr}-review.log"
                if kill -0 "$pid" 2>/dev/null; then
                    ALL_DONE=false
                    LAST_LINE=$(tail -1 "$LOG_FILE" 2>/dev/null | cut -c1-60 || echo "starting...")
                    printf "  %s⟳%s PR #%-6s PID %-7s %s\033[K\n" "$YELLOW" "$RESET" "$pr" "$pid" "$LAST_LINE"
                else
                    if [[ -z "${BG_EXIT_CODES[$pr]+x}" ]]; then
                        wait "$pid" 2>/dev/null && BG_EXIT_CODES[$pr]=0 || BG_EXIT_CODES[$pr]=$?
                    fi
                    EXIT_CODE="${BG_EXIT_CODES[$pr]}"
                    if [[ "$EXIT_CODE" -eq 0 ]]; then
                        printf "  %s✓%s PR #%-6s %sdone%s\033[K\n" "$GREEN" "$RESET" "$pr" "$GREEN" "$RESET"
                    else
                        printf "  %s✗%s PR #%-6s %sexit %s%s  (see %s)\033[K\n" "$RED" "$RESET" "$pr" "$RED" "$EXIT_CODE" "$RESET" "$LOG_FILE"
                    fi
                fi
            done

            [[ "$ALL_DONE" == true || "$TRAP_FIRED" == true ]] && break
            sleep 2
        done

        echo ""
        if [[ "$TRAP_FIRED" == true ]]; then
            info "Detached. Reviews continue in background."
            info "Check logs in: ${LOG_DIR}/pr-*-review.log"
        else
            ok "All reviews complete."
        fi
        exit 0
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
#  SINGLE-PR REVIEW MODE
# ═══════════════════════════════════════════════════════════════════════════
# Either invoked directly with one PR number, or re-invoked by the multi-PR
# orchestrator above via --_single.
# ═══════════════════════════════════════════════════════════════════════════

PR_NUMBER="${PR_NUMBERS[0]}"

# Set the iTerm2 / tmux tab title for identification
_set_tab_title() {
    local title="$1"
    # iTerm2 tab title
    printf '\e]1;%s\a' "$title" 2>/dev/null || true
    # tmux window name
    if [[ -n "${TMUX:-}" ]]; then
        tmux rename-window "$title" 2>/dev/null || true
    fi
    # Generic terminal title (xterm-compatible)
    printf '\e]0;%s\a' "$title" 2>/dev/null || true
}

# Send a macOS notification (system-level + iTerm2 banner + tmux message)
_notify() {
    local title="$1" body="$2" subtitle="${3:-}" sound="${4:-Glass}"
    # macOS system notification via AppleScript (argv avoids injection)
    osascript - "$title" "$body" "$subtitle" "$sound" <<'APPLESCRIPT' 2>/dev/null || true
on run argv
    set opts to {title:(item 1 of argv), sound name:(item 4 of argv)}
    if (item 3 of argv) is not "" then set opts to opts & {subtitle:(item 3 of argv)}
    display notification (item 2 of argv) with properties opts
end run
APPLESCRIPT
    # iTerm2 proprietary notification (banner when app not focused)
    if [[ "${TERM_PROGRAM:-}" == "iTerm.app" || "${LC_TERMINAL:-}" == "iTerm2" ]]; then
        printf '\e]9;%s\a' "$body" 2>/dev/null || true
    fi
    # tmux message bar
    if [[ -n "${TMUX:-}" ]]; then
        tmux display-message "${title}: ${body}" 2>/dev/null || true
    fi
}

_set_tab_title "PR #${PR_NUMBER} — loading..."

# ── Validate tooling ───────────────────────────────────────────────────────
step "Checking prerequisites"
for cmd in gh git claude jq; do
    command -v "$cmd" &>/dev/null || fatal "'$cmd' is not installed or not on PATH."
done
ok "gh, git, claude, jq — all found"
gh auth status &>/dev/null || fatal "GitHub CLI is not authenticated. Run: gh auth login"
ok "GitHub CLI authenticated"

# ── Resolve repository ─────────────────────────────────────────────────────
step "Resolving repository"
if [[ -z "$REPO" ]]; then
    git rev-parse --git-dir &>/dev/null || fatal "Not inside a git repo and --repo not specified."
    REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null) \
        || fatal "Could not detect repo. Pass --repo owner/repo explicitly."
fi
ok "Repository: ${BOLD}$REPO${RESET}"

# ── Fetch PR metadata ──────────────────────────────────────────────────────
step "Fetching PR #${PR_NUMBER} metadata"
PR_JSON=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json \
    title,headRefName,baseRefName,body,url,additions,deletions,changedFiles,author,labels,state \
    2>/dev/null) || fatal "Could not fetch PR #${PR_NUMBER}. Does it exist in ${REPO}?"

PR_TITLE=$(echo "$PR_JSON"  | jq -r '.title')
PR_HEAD=$(echo "$PR_JSON"   | jq -r '.headRefName')
PR_BASE=$(echo "$PR_JSON"   | jq -r '.baseRefName')
PR_BODY=$(echo "$PR_JSON"   | jq -r '.body // "No description provided."')
PR_URL=$(echo "$PR_JSON"    | jq -r '.url')
PR_ADDS=$(echo "$PR_JSON"   | jq -r '.additions')
PR_DELS=$(echo "$PR_JSON"   | jq -r '.deletions')
PR_FILES=$(echo "$PR_JSON"  | jq -r '.changedFiles')
PR_AUTHOR=$(echo "$PR_JSON" | jq -r '.author.login')
PR_STATE=$(echo "$PR_JSON"  | jq -r '.state')

# Update tab title with the actual PR title
_set_tab_title "PR #${PR_NUMBER} — ${PR_TITLE:0:35}"

ok "${BOLD}${PR_TITLE}${RESET} by @${PR_AUTHOR}"
info "${PR_HEAD} → ${PR_BASE}  ·  +${PR_ADDS} -${PR_DELS}  ·  ${PR_FILES} file(s)  ·  ${PR_STATE}"
[[ "$PR_STATE" == "MERGED" ]] && warn "This PR has already been merged."

# ── Fetch the diff ──────────────────────────────────────────────────────────
step "Fetching PR diff"
PR_DIFF=$(gh pr diff "$PR_NUMBER" --repo "$REPO" 2>/dev/null) \
    || fatal "Could not fetch diff for PR #${PR_NUMBER}."
PR_FILE_LIST=$(gh pr diff "$PR_NUMBER" --repo "$REPO" --name-only 2>/dev/null) \
    || PR_FILE_LIST="(could not retrieve file list)"
DIFF_LINES=$(echo "$PR_DIFF" | wc -l)
ok "Diff fetched: ${DIFF_LINES} lines"

# ── Resolve git root ───────────────────────────────────────────────────────
step "Setting up git worktree"
if git rev-parse --git-dir &>/dev/null 2>&1; then
    GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || git rev-parse --git-dir)
else
    info "Not inside a git repo. Cloning $REPO..."
    CLONE_DIR="/tmp/reviewer-repos/$(echo "$REPO" | tr '/' '-')"
    if [[ ! -d "$CLONE_DIR" ]]; then
        gh repo clone "$REPO" "$CLONE_DIR" -- --bare 2>/dev/null \
            || gh repo clone "$REPO" "$CLONE_DIR" 2>/dev/null \
            || fatal "Failed to clone $REPO"
    fi
    GIT_ROOT="$CLONE_DIR"
fi

# ── Worktree parent: ~/.reviewer/ ────────────────────────────────────────
if [[ -z "$WORKTREE_PARENT" ]]; then
    WORKTREE_PARENT="${HOME}/.reviewer"
fi
WORKTREE_PARENT=$(cd "$(dirname "$WORKTREE_PARENT")" 2>/dev/null \
    && echo "$(pwd)/$(basename "$WORKTREE_PARENT")" || echo "$WORKTREE_PARENT")

WORKTREE_DIR="${WORKTREE_PARENT}/pr-${PR_NUMBER}"
WORKTREE_BRANCH="pr-review/${PR_NUMBER}"
LOCKFILE="${WORKTREE_PARENT}/.lock-pr-${PR_NUMBER}"

info "Worktree target: $WORKTREE_DIR"

# ── Ensure worktree dir is git-ignored (only when placed inside the repo) ──
WT_RELPATH=$(python3 -c "import os.path; print(os.path.relpath('$WORKTREE_PARENT', '$GIT_ROOT'))" 2>/dev/null || echo "")

if [[ -n "$WT_RELPATH" && "$WT_RELPATH" != ..* ]]; then
    IGNORE_ENTRY="/${WT_RELPATH}/"
    if git -C "$GIT_ROOT" check-ignore -q "${WT_RELPATH}/test" 2>/dev/null; then
        : # already git-ignored
    else
        GIT_EXCLUDE="${GIT_ROOT}/.git/info/exclude"
        if [[ -f "$GIT_EXCLUDE" ]]; then
            if ! grep -qF "$IGNORE_ENTRY" "$GIT_EXCLUDE" 2>/dev/null; then
                printf '\n# PR review worktrees (auto-added by reviewer.sh)\n%s\n' "$IGNORE_ENTRY" >> "$GIT_EXCLUDE"
                printf "       %sAdded worktree to git exclude%s\n" "$DIM" "$RESET"
            fi
        else
            mkdir -p "$(dirname "$GIT_EXCLUDE")"
            printf '# PR review worktrees (auto-added by reviewer.sh)\n%s\n' "$IGNORE_ENTRY" > "$GIT_EXCLUDE"
            printf "       %sAdded worktree to git exclude%s\n" "$DIM" "$RESET"
        fi
        GITIGNORE_FILE="${GIT_ROOT}/.gitignore"
        if [[ -f "$GITIGNORE_FILE" ]]; then
            if ! grep -qF "$IGNORE_ENTRY" "$GITIGNORE_FILE" 2>/dev/null; then
                [[ -s "$GITIGNORE_FILE" && "$(tail -c1 "$GITIGNORE_FILE")" != "" ]] && echo "" >> "$GITIGNORE_FILE"
                printf '\n# PR review worktrees (auto-added by reviewer.sh)\n%s\n' "$IGNORE_ENTRY" >> "$GITIGNORE_FILE"
                info "Also added to .gitignore (commit at your convenience)"
            fi
        fi
    fi
fi

# ── Lockfile — prevent two instances on the same PR ────────────────────────
mkdir -p "$WORKTREE_PARENT"
if [[ -f "$LOCKFILE" ]]; then
    LOCK_PID=$(cat "$LOCKFILE" 2>/dev/null)
    if kill -0 "$LOCK_PID" 2>/dev/null; then
        fatal "Another review of PR #${PR_NUMBER} is already running (PID ${LOCK_PID}). Remove $LOCKFILE if this is stale."
    else
        warn "Stale lockfile found (PID ${LOCK_PID} not running). Removing."
        rm -f "$LOCKFILE"
    fi
fi
echo $$ > "$LOCKFILE"
_cleanup_on_exit() {
    local exit_code=$?
    rm -f "$LOCKFILE"
    # If exiting with an error AND the worktree exists, clean it up.
    # Successful exits handle cleanup explicitly in the post-review section.
    if [[ $exit_code -ne 0 && -d "${WORKTREE_DIR:-}" ]]; then
        warn "Script failed (exit $exit_code) — removing incomplete worktree"
        git -C "$GIT_ROOT" worktree remove "$WORKTREE_DIR" --force 2>/dev/null || rm -rf "$WORKTREE_DIR" 2>/dev/null || true
        git -C "$GIT_ROOT" branch -D "$WORKTREE_BRANCH" 2>/dev/null || true
    fi
}
trap '_cleanup_on_exit' EXIT

# ── Clean stale worktree ───────────────────────────────────────────────────
if [[ -d "$WORKTREE_DIR" ]]; then
    warn "Worktree already exists at $WORKTREE_DIR — removing stale worktree"
    git -C "$GIT_ROOT" worktree remove "$WORKTREE_DIR" --force 2>/dev/null || true
    rm -rf "$WORKTREE_DIR" 2>/dev/null || true
fi

# ── Safe branch cleanup ───────────────────────────────────────────────────
if git -C "$GIT_ROOT" show-ref --verify --quiet "refs/heads/${WORKTREE_BRANCH}" 2>/dev/null; then
    EXISTING_WT=$(git -C "$GIT_ROOT" worktree list --porcelain 2>/dev/null \
        | awk -v b="$WORKTREE_BRANCH" '/^worktree /{wt=$2} /^branch refs\/heads\//{if($2=="refs/heads/"b) print wt}')
    if [[ "$EXISTING_WT" == "$WORKTREE_DIR" ]]; then
        git -C "$GIT_ROOT" branch -D "$WORKTREE_BRANCH" 2>/dev/null || true
    elif [[ -n "$EXISTING_WT" ]]; then
        fatal "Branch '${WORKTREE_BRANCH}' is checked out in another worktree: ${EXISTING_WT}. Remove it manually before re-running."
    else
        warn "Branch '${WORKTREE_BRANCH}' already exists (orphan). Replacing it."
        git -C "$GIT_ROOT" branch -D "$WORKTREE_BRANCH" 2>/dev/null || true
    fi
fi

# ── Fetch PR head & create worktree ───────────────────────────────────────
info "Fetching PR head from remote..."
git -C "$GIT_ROOT" fetch origin "pull/${PR_NUMBER}/head:${WORKTREE_BRANCH}" 2>/dev/null \
    || fatal "Failed to fetch PR #${PR_NUMBER} head. Ensure origin remote is correct."

git -C "$GIT_ROOT" worktree add "$WORKTREE_DIR" "$WORKTREE_BRANCH" 2>/dev/null \
    || fatal "Failed to create worktree at $WORKTREE_DIR"

ok "Worktree ready: ${DIM}$WORKTREE_DIR${RESET}"

# ═══════════════════════════════════════════════════════════════════════════
#  ENVIRONMENT / CONFIG FILE COPYING
# ═══════════════════════════════════════════════════════════════════════════
REVIEW_CONTEXT_DIR="${WORKTREE_DIR}/.pr-review-context"
mkdir -p "$REVIEW_CONTEXT_DIR"

if [[ "$COPY_ENV" == true ]]; then
    step "Copying environment & config files into worktree"

    ALL_PATTERNS=("${DEFAULT_ENV_PATTERNS[@]}")
    if [[ -n "$EXTRA_ENV_PATTERNS" ]]; then
        IFS=',' read -ra EXTRA_ARR <<< "$EXTRA_ENV_PATTERNS"
        for p in "${EXTRA_ARR[@]}"; do
            ALL_PATTERNS+=("$(echo "$p" | xargs)")
        done
    fi

    ENV_COPIED=0
    ENV_SKIPPED=0
    ENV_COPY_LOG="${REVIEW_CONTEXT_DIR}/env-files-copied.log"
    : > "$ENV_COPY_LOG"

    _try_copy() {
        local src_path="$1" log_tag="${2:-}"
        local rel_path="${src_path#${GIT_ROOT}/}"
        [[ "$src_path" == "${WORKTREE_PARENT}"/* ]] && return 0
        git -C "$GIT_ROOT" ls-files --error-unmatch "$rel_path" &>/dev/null && return 0
        local dst_path="${WORKTREE_DIR}/${rel_path}"
        [[ -e "$dst_path" ]] && return 0
        if [[ -d "$src_path" ]]; then
            local dir_size
            dir_size=$(du -sk "$src_path" 2>/dev/null | awk '{print $1 * 1024}')
            if [[ "${dir_size:-0}" -gt $((50 * 1024 * 1024)) ]]; then
                warn "Skipped dir ${rel_path}/ (too large)"
                ((ENV_SKIPPED++)) || true; return 0
            fi
            mkdir -p "$(dirname "$dst_path")"
            cp -a "$src_path" "$dst_path"
            echo "[DIR]  ${rel_path}/${log_tag:+  ($log_tag)}" >> "$ENV_COPY_LOG"
            ((ENV_COPIED++)) || true
        elif [[ -f "$src_path" ]]; then
            local file_size
            file_size=$(stat -c%s "$src_path" 2>/dev/null || stat -f%z "$src_path" 2>/dev/null || echo 0)
            if [[ "$file_size" -gt "$ENV_COPY_MAX_SIZE" ]]; then
                warn "Skipped ${rel_path} (too large)"
                ((ENV_SKIPPED++)) || true; return 0
            fi
            mkdir -p "$(dirname "$dst_path")"
            cp -a "$src_path" "$dst_path"
            echo "[FILE] ${rel_path}${log_tag:+  ($log_tag)}" >> "$ENV_COPY_LOG"
            ((ENV_COPIED++)) || true
        fi
    }

    # Pass 1: pattern list
    for pattern in "${ALL_PATTERNS[@]}"; do
        shopt -s nullglob; matches=( "$GIT_ROOT"/$pattern ); shopt -u nullglob
        for src_path in ${matches[@]+"${matches[@]}"}; do _try_copy "$src_path" "pattern"; done
    done
    # Pass 2: root .env*
    shopt -s nullglob dotglob
    for src_path in "$GIT_ROOT"/.env*; do _try_copy "$src_path" "root .env* sweep"; done
    shopt -u nullglob dotglob
    # Pass 3: deep .env*
    while IFS= read -r -d '' src_path; do
        _try_copy "$src_path" "deep .env* sweep"
    done < <(find "$GIT_ROOT" -maxdepth 4 -name '.env*' -type f \
        -not -path "${WORKTREE_PARENT}/*" -not -path '*/.git/*' \
        -not -path '*/node_modules/*' -not -path '*/.venv/*' -not -path '*/venv/*' \
        -print0 2>/dev/null)

    if [[ "$ENV_COPIED" -gt 0 ]]; then
        ok "${ENV_COPIED} env/config file(s) copied into worktree"
        info "Manifest: ${ENV_COPY_LOG}"
        while IFS= read -r line; do
            printf "       %s%s%s\n" "$DIM" "$line" "$RESET"
        done < "$ENV_COPY_LOG"
    else
        info "No untracked env/config files found to copy"
    fi
    [[ "$ENV_SKIPPED" -gt 0 ]] && warn "${ENV_SKIPPED} file(s)/dir(s) skipped (too large)"
else
    info "Env/config copying disabled (--no-env-copy)"
fi

# ── Write diff & PR context ───────────────────────────────────────────────
echo "$PR_DIFF" > "${REVIEW_CONTEXT_DIR}/pr.diff"
cat > "${REVIEW_CONTEXT_DIR}/pr-info.md" <<PREOF
# PR #${PR_NUMBER}: ${PR_TITLE}

- **Author:** ${PR_AUTHOR}
- **Branch:** \`${PR_HEAD}\` → \`${PR_BASE}\`
- **URL:** ${PR_URL}
- **Changes:** +${PR_ADDS} -${PR_DELS} across ${PR_FILES} file(s)
- **State:** ${PR_STATE}

## Description

${PR_BODY}

## Changed Files

\`\`\`
${PR_FILE_LIST}
\`\`\`
PREOF
ok "PR context written to ${REVIEW_CONTEXT_DIR}/"

# ── Build Claude prompt (no user-visible step — just string templating) ──
read -r -d '' REVIEW_PROMPT <<'PROMPT_TEMPLATE' || true
You are leading a thorough code review of PR #__PR_NUM__: "__PR_TITLE__" by @__PR_AUTHOR__.

## PR Context

- **Branch:** `__PR_HEAD__` → `__PR_BASE__`
- **URL:** __PR_URL__
- **Scope:** +__PR_ADDS__ -__PR_DELS__ across __PR_FILES__ file(s)

### PR Description
__PR_BODY__

### Changed Files
```
__PR_FILE_LIST__
```

## Your Task

Perform a comprehensive, professional PR review. Create an agent team with the following specialized teammates:

1. **code-quality-reviewer** — Analyze code quality, readability, naming conventions, DRY principles, SOLID principles, design patterns, and overall code structure.

2. **security-reviewer** — Audit for security vulnerabilities: injection risks, auth issues, data exposure, insecure defaults, missing input validation, secrets in code, OWASP Top 10.

3. **logic-and-correctness-reviewer** — Verify correctness of business logic, edge cases, error handling, race conditions, null/undefined handling, type safety, and test coverage.

4. **architecture-reviewer** — Evaluate architectural decisions, API design, backward compatibility, performance implications, scalability, dependency management.

## Environment

This worktree has all env/config files from the main repo. You CAN and SHOULD:
- Run the test suite, linters, and type-checkers
- Attempt to build the project
- Verify the changes don't break anything

Manifest at `.pr-review-context/env-files-copied.log`. Diff at `.pr-review-context/pr.diff`.

## Instructions for the Team

Each teammate should:
1. Read the full diff and PR info from `.pr-review-context/`
2. Explore the actual source code for full context
3. **Run relevant tests and linters** — all env files are available
4. Provide specific, actionable feedback with exact file paths and line numbers
5. Categorize findings as: 🔴 BLOCKER, 🟡 SUGGESTION, 🟢 PRAISE, or ℹ️ NOTE

## Final Deliverable

Synthesize into `.pr-review-context/REVIEW.md`:

1. **Executive Summary** — APPROVE / REQUEST CHANGES / COMMENT
2. **Test Results** — test suite, linters, type-checkers output
3. **Critical Issues** (blockers)
4. **Suggestions** (improvements)
5. **Positive Observations** (praise)
6. **Detailed Findings** — by category
7. **File-by-File Notes** — keyed to file paths and line ranges

Be constructive, specific, and professional.
PROMPT_TEMPLATE

REVIEW_PROMPT="${REVIEW_PROMPT//__PR_NUM__/$PR_NUMBER}"
REVIEW_PROMPT="${REVIEW_PROMPT//__PR_TITLE__/$PR_TITLE}"
REVIEW_PROMPT="${REVIEW_PROMPT//__PR_AUTHOR__/$PR_AUTHOR}"
REVIEW_PROMPT="${REVIEW_PROMPT//__PR_HEAD__/$PR_HEAD}"
REVIEW_PROMPT="${REVIEW_PROMPT//__PR_BASE__/$PR_BASE}"
REVIEW_PROMPT="${REVIEW_PROMPT//__PR_URL__/$PR_URL}"
REVIEW_PROMPT="${REVIEW_PROMPT//__PR_ADDS__/$PR_ADDS}"
REVIEW_PROMPT="${REVIEW_PROMPT//__PR_DELS__/$PR_DELS}"
REVIEW_PROMPT="${REVIEW_PROMPT//__PR_FILES__/$PR_FILES}"
REVIEW_PROMPT="${REVIEW_PROMPT//__PR_BODY__/$PR_BODY}"
REVIEW_PROMPT="${REVIEW_PROMPT//__PR_FILE_LIST__/$PR_FILE_LIST}"

# ── Build Claude CLI arguments ─────────────────────────────────────────────
CLAUDE_ARGS=("--model" "$MODEL" "--max-turns" "$MAX_TURNS")

[[ "$SKIP_PERMISSIONS" == true ]] && CLAUDE_ARGS+=("--dangerously-skip-permissions")
[[ -n "$OUTPUT_FILE" ]] && CLAUDE_ARGS+=("-p")

CLAUDE_ENV=()
AGENT_MODE="agent teams"
if [[ "$USE_TEAMS" == true ]]; then
    CLAUDE_ENV+=("CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1")
    REVIEW_PROMPT+="

## Teammate Model

IMPORTANT: When creating each teammate agent, you MUST specify the model \"${TEAMMATE_MODEL}\" for all teammates. Use the model parameter to set each teammate to \"${TEAMMATE_MODEL}\". Do not use any other model."
else
    AGENT_MODE="subagents"
    # Quoted heredoc prevents accidental expansion of $ in prompt strings.
    # TEAMMATE_MODEL is substituted explicitly below.
    read -r -d '' AGENTS_JSON <<'AGENTS' || true
{
  "code-quality-reviewer": {
    "description": "Analyzes code quality, readability, naming, DRY/SOLID, design patterns, code smells.",
    "prompt": "You are a senior code quality reviewer. Analyze the PR diff and source files. Focus on readability, naming, DRY/SOLID, design patterns, complexity. Run linters if available. Use 🔴/🟡/🟢/ℹ️. Diff at .pr-review-context/pr.diff.",
    "tools": ["Read", "Grep", "Glob", "Bash"], "model": "__TEAMMATE_MODEL__"
  },
  "security-reviewer": {
    "description": "Audits for security vulnerabilities, injection, auth, data exposure, OWASP Top 10.",
    "prompt": "You are a security reviewer. Audit for: injection, auth issues, data exposure, insecure defaults, missing validation, hardcoded secrets, OWASP Top 10. Use 🔴/🟡/🟢/ℹ️. Diff at .pr-review-context/pr.diff.",
    "tools": ["Read", "Grep", "Glob", "Bash"], "model": "__TEAMMATE_MODEL__"
  },
  "logic-reviewer": {
    "description": "Verifies business logic, edge cases, error handling, race conditions, tests.",
    "prompt": "You are a logic reviewer. Verify business logic, edge cases, error handling, race conditions, null safety, test coverage. Run the test suite. Use 🔴/🟡/🟢/ℹ️. Diff at .pr-review-context/pr.diff.",
    "tools": ["Read", "Grep", "Glob", "Bash"], "model": "__TEAMMATE_MODEL__"
  },
  "architecture-reviewer": {
    "description": "Evaluates architecture, API design, backward compat, performance, scalability.",
    "prompt": "You are an architecture reviewer. Evaluate architectural decisions, API design, backward compat, performance, scalability, dependency management. Use 🔴/🟡/🟢/ℹ️. Diff at .pr-review-context/pr.diff.",
    "tools": ["Read", "Grep", "Glob", "Bash"], "model": "__TEAMMATE_MODEL__"
  }
}
AGENTS
    AGENTS_JSON="${AGENTS_JSON//__TEAMMATE_MODEL__/$TEAMMATE_MODEL}"
    CLAUDE_ARGS+=("--agents" "$AGENTS_JSON")
fi

# ── Build the launch summary line ─────────────────────────────────────────
if [[ "$TEAMMATE_MODEL" != "$MODEL" ]]; then
    REVIEW_CONFIG_LINE="4 reviewers · ${MODEL} (teammates: ${TEAMMATE_MODEL}) · ${MAX_TURNS} turns · ${AGENT_MODE}"
else
    REVIEW_CONFIG_LINE="4 reviewers · ${MODEL} · ${MAX_TURNS} turns · ${AGENT_MODE}"
fi
[[ "$SKIP_PERMISSIONS" == true ]] && REVIEW_CONFIG_LINE="${REVIEW_CONFIG_LINE} · autonomous"
[[ -n "$OUTPUT_FILE" ]] && REVIEW_CONFIG_LINE="${REVIEW_CONFIG_LINE} · output → ${OUTPUT_FILE}"

# ── Execute ────────────────────────────────────────────────────────────────
echo ""
printf "  %s%s───────────────────────────────────────────────────────%s\n" "$BOLD" "$CYAN" "$RESET"
echo ""
printf "  %s%sPR #%s%s  %s%s\n" "$BOLD" "$CYAN" "$PR_NUMBER" "$RESET" "$BOLD$(echo "$PR_TITLE" | cut -c1-50)" "$RESET"
printf "  %s@%s  ·  %s → %s  ·  %s+%s%s %s-%s%s  ·  %s file(s)%s\n" \
    "$DIM" "$PR_AUTHOR" "$PR_HEAD" "$PR_BASE" \
    "$GREEN" "$PR_ADDS" "$RESET$DIM" "$RED" "$PR_DELS" "$RESET$DIM" \
    "$PR_FILES" "$RESET"
echo ""
printf "  %s%s%s  %s%s%s  %s%s%s" \
    "$CYAN" "${MODEL}$( [[ "$TEAMMATE_MODEL" != "$MODEL" ]] && printf " → %s" "$TEAMMATE_MODEL" )" "$RESET" \
    "$BLUE" "${MAX_TURNS} turns" "$RESET" \
    "$GREEN" "$AGENT_MODE" "$RESET"
[[ "$SKIP_PERMISSIONS" == true ]] && printf "  %s%sautonomous%s" "$YELLOW" "$BOLD" "$RESET"
[[ -n "$OUTPUT_FILE" ]] && printf "  %s→ %s%s" "$DIM" "$OUTPUT_FILE" "$RESET"
echo ""
echo ""
printf "  %s%s───────────────────────────────────────────────────────%s\n" "$BOLD" "$CYAN" "$RESET"
echo ""

_set_tab_title "PR #${PR_NUMBER} ⟳ reviewing..."

run_claude() (
    # Subshell so cd doesn't affect the parent script
    cd "$WORKTREE_DIR"
    if [[ ${#CLAUDE_ENV[@]} -gt 0 ]]; then
        env "${CLAUDE_ENV[@]}" claude "${CLAUDE_ARGS[@]}" "$REVIEW_PROMPT"
    else
        claude "${CLAUDE_ARGS[@]}" "$REVIEW_PROMPT"
    fi
)

if [[ -n "$OUTPUT_FILE" ]]; then
    info "Claude is reviewing the PR (non-interactive)..."
    CLAUDE_START=$SECONDS
    run_claude > "$OUTPUT_FILE" 2>&1 &
    CLAUDE_PID=$!
    while kill -0 "$CLAUDE_PID" 2>/dev/null; do
        ELAPSED=$(( SECONDS - CLAUDE_START ))
        printf "\r%s[INFO]%s  Reviewing... %dm %02ds elapsed" "$BLUE" "$RESET" "$((ELAPSED/60))" "$((ELAPSED%60))"
        sleep 5
    done
    wait "$CLAUDE_PID" && REVIEW_EXIT=0 || REVIEW_EXIT=$?
    printf "\r\033[K"  # clear timer line
else
    run_claude && REVIEW_EXIT=0 || REVIEW_EXIT=$?
fi

# ── Post-review ────────────────────────────────────────────────────────────
echo ""
REVIEW_FILE="${REVIEW_CONTEXT_DIR}/REVIEW.md"

if [[ $REVIEW_EXIT -eq 0 ]]; then
    _notify "reviewer" "PR #${PR_NUMBER} review complete" "${PR_TITLE:0:50}" "Glass"
    _set_tab_title "PR #${PR_NUMBER} ✓ ${PR_TITLE:0:30}"
    ok "Review completed successfully"
    [[ -n "$OUTPUT_FILE" && -f "$REVIEW_FILE" && ! -s "$OUTPUT_FILE" ]] && cp "$REVIEW_FILE" "$OUTPUT_FILE"
else
    _notify "reviewer" "PR #${PR_NUMBER} review failed (exit $REVIEW_EXIT)" "${PR_TITLE:0:50}" "Basso"
    _set_tab_title "PR #${PR_NUMBER} ✗ failed"
    warn "Claude exited with code $REVIEW_EXIT"
fi

# ── Display review: clear screen so tabbing to this tab shows the review ──
_show_review() {
    local cols
    cols=$(tput cols 2>/dev/null || echo 70)
    local sep
    sep=$(printf '═%.0s' $(seq 1 "$cols"))

    clear 2>/dev/null || printf '\033[2J\033[H'

    printf "%s%s%s%s\n" "$BOLD" "$CYAN" "$sep" "$RESET"
    if [[ $REVIEW_EXIT -eq 0 ]]; then
        printf "%s%s  ✓ REVIEW: PR #%s — %s%s\n" "$BOLD" "$GREEN" "$PR_NUMBER" "$(echo "$PR_TITLE" | cut -c1-$((cols - 28)))" "$RESET"
    else
        printf "%s%s  ✗ REVIEW: PR #%s — %s  (Claude exit %s)%s\n" "$BOLD" "$RED" "$PR_NUMBER" "$(echo "$PR_TITLE" | cut -c1-$((cols - 40)))" "$REVIEW_EXIT" "$RESET"
    fi
    printf "%s  @%-16s  %s → %s%s\n" "$DIM" "$PR_AUTHOR" "$PR_HEAD" "$PR_BASE" "$RESET"
    printf "%s  %s%s\n" "$DIM" "$PR_URL" "$RESET"
    printf "%s%s%s%s\n" "$BOLD" "$CYAN" "$sep" "$RESET"
    echo ""

    if [[ -f "$REVIEW_FILE" ]]; then
        cat "$REVIEW_FILE"
        echo ""
        printf "%s%s%s%s\n" "$BOLD" "$CYAN" "$sep" "$RESET"
    else
        warn "REVIEW.md not found — Claude may not have completed the review."
        echo ""
        if [[ -n "$OUTPUT_FILE" && -f "$OUTPUT_FILE" ]]; then
            info "Raw output available at: $OUTPUT_FILE"
        fi
    fi
}

# Show the review immediately (clear screen so this is what you see when tabbing here)
if [[ -t 1 ]]; then
    # Interactive terminal — show via less so you can scroll through
    _show_review | less -RXF 2>/dev/null || _show_review
else
    _show_review
fi

# ── Cleanup ────────────────────────────────────────────────────────────────
# On success + --cleanup: remove worktree as requested.
# On failure: always remove the worktree — it's a broken artifact.
_remove_worktree() {
    if [[ -d "$WORKTREE_DIR" ]]; then
        git -C "$GIT_ROOT" worktree remove "$WORKTREE_DIR" --force 2>/dev/null || rm -rf "$WORKTREE_DIR" 2>/dev/null || true
    fi
    git -C "$GIT_ROOT" branch -D "$WORKTREE_BRANCH" 2>/dev/null || true
}

if [[ $REVIEW_EXIT -ne 0 ]]; then
    # ── Failed review: clean up automatically ──────────────────────────
    step "Cleaning up failed review"
    _remove_worktree
    warn "Worktree and branch removed (review failed with exit code $REVIEW_EXIT)"
    info "Re-run to try again: $0 $PR_NUMBER"
    echo ""
    exit $REVIEW_EXIT

elif [[ "$CLEANUP" == true ]]; then
    _remove_worktree
    printf "%sWorktree and branch cleaned up.%s\n" "$DIM" "$RESET"
fi

# ── Drop into a useful shell (parallel tabs only) ─────────────────────────
# When launched by the multi-PR orchestrator (--_single), the tab would
# close after the script exits. Instead, drop into a shell with shortcuts
# so tabbing back here always has something useful.
if [[ "$_SINGLE_MODE" == true && -d "$WORKTREE_DIR" && "$CLEANUP" == false ]]; then
    # Write a tiny rcfile that gives the user quick commands
    _sq() { printf '%s' "$1" | sed "s/'/'\\\\''/g"; }
    SHELL_RC=$(mktemp /tmp/reviewer-rc-XXXXXX)
    cat > "$SHELL_RC" <<RCEOF
# Load user's normal shell config
[[ -f ~/.bashrc ]] && source ~/.bashrc 2>/dev/null

# PR review environment
cd '$(_sq "$WORKTREE_DIR")'
export PR_NUMBER='$(_sq "$PR_NUMBER")'
export PR_TITLE='$(_sq "$PR_TITLE")'
export REVIEW_FILE='$(_sq "$REVIEW_FILE")'
export WORKTREE_DIR='$(_sq "$WORKTREE_DIR")'

# Custom prompt showing which PR review this tab is
PS1='\[\033[0;32m\][PR #$PR_NUMBER]\[\033[0m\] \w \$ '

# Quick commands
review() {
    clear
    local cols=\$(tput cols 2>/dev/null || echo 70)
    local sep=\$(printf '═%.0s' \$(seq 1 "\$cols"))
    printf '\033[1;36m%s\033[0m\n' "\$sep"
    printf '\033[1;32m  ✓ REVIEW: PR #%s\033[0m\033[1m — %s\033[0m\n' '$PR_NUMBER' '$(echo "$PR_TITLE" | cut -c1-50)'
    printf '\033[2m  $PR_URL\033[0m\n'
    printf '\033[1;36m%s\033[0m\n\n' "\$sep"
    if [[ -f "\$REVIEW_FILE" ]]; then
        less -RXF "\$REVIEW_FILE"
    else
        echo "REVIEW.md not found"
    fi
}

pdiff() {
    if [[ -f '.pr-review-context/pr.diff' ]]; then
        less -RXF '.pr-review-context/pr.diff'
    else
        echo "No diff file found"
    fi
}

files() {
    if [[ -f '.pr-review-context/pr-info.md' ]]; then
        cat '.pr-review-context/pr-info.md'
    else
        echo "No PR info found"
    fi
}

# Welcome banner (compact — review already shown above)
echo ""
printf '  \033[1;36m───────────────────────────────────────────────\033[0m\n'
printf '  \033[1;36m◆\033[0m \033[1mPR #$PR_NUMBER\033[0m worktree\n'
echo ""
printf '    \033[1;36mreview\033[0m   show the review again\n'
printf '    \033[1;36mpdiff\033[0m    view the PR diff\n'
printf '    \033[1;36mfiles\033[0m    PR metadata & file list\n'
printf '    \033[1;36mexit\033[0m     close this tab\n'
echo ""
printf '  \033[1;36m───────────────────────────────────────────────\033[0m\n'
echo ""
RCEOF
    exec bash --rcfile "$SHELL_RC"
fi

exit $REVIEW_EXIT
