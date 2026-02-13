# pr-review.sh

Automated PR code review using Claude Code agent teams. Uses git worktrees for full isolation, supports parallel reviews via iTerm2 tabs, tmux windows, or background processes.

## Requirements

| Tool | Install | Purpose |
|------|---------|---------|
| `gh` | `brew install gh` then `gh auth login` | GitHub CLI |
| `git` | (pre-installed on macOS) | Git 2.15+ for worktree support |
| `claude` | `npm i -g @anthropic-ai/claude-code` | Claude Code CLI |
| `jq` | `brew install jq` | JSON processing |

## Quick Start

```bash
# Clone and make executable
chmod +x pr_review.sh

# Review a single PR
./pr_review.sh 42

# Review multiple PRs in parallel (auto-detects iTerm2/tmux)
./pr_review.sh 42 43 44

# Review a PR from a different repo
./pr_review.sh 42 --repo owner/repo
```

## Usage

```
./pr_review.sh <PR_NUMBER...> [OPTIONS]
```

### Options

| Flag | Description | Default |
|------|-------------|---------|
| `-r, --repo <owner/repo>` | Target GitHub repository | auto-detected |
| `-d, --dir <path>` | Parent directory for worktrees | `~/.pr_reviewer/` |
| `-e, --env-files <globs>` | Extra file patterns to copy (comma-separated) | built-in list |
| `-m, --model <model>` | Claude model for the lead agent | `opus` |
| `-b, --max-turns <N>` | Max agentic turns per PR | `50` |
| `-o, --output <path>` | Write review to file (single-PR, non-interactive) | — |
| `-c, --cleanup` | Remove worktree after review | `false` |
| `-t, --no-teams` | Use subagents instead of agent teams | `false` |
| `--no-skip-permissions` | Require manual approval for each tool use | `false` |
| `--no-env-copy` | Skip copying env/config files | `false` |
| `--no-color` | Disable colored output | auto-detected |
| `--tabs <mode>` | Tab mode: `auto`, `iterm`, `tmux`, `bg` | `auto` |
| `-h, --help` | Show help | — |

### Color Behavior

Colors are automatically enabled when both stdout and stderr are TTYs. They are disabled when:

- Output is piped or redirected
- `NO_COLOR=1` is set (per [no-color.org](https://no-color.org))
- `PR_REVIEW_NO_COLOR=1` is set
- `--no-color` flag is passed

## Parallel Reviews

Pass 2+ PR numbers and the script auto-detects your terminal:

| Terminal | What happens | Navigation |
|----------|-------------|------------|
| **iTerm2** | One named tab per PR | `Cmd+1-9` or `Cmd+Arrow` |
| **tmux** | Session with named windows | `Ctrl+B n/p` or `Ctrl+B w` |
| **Other** | Background processes with live status | Logs in `~/.pr_reviewer/` |

Override with `--tabs`:

```bash
./pr_review.sh 42 43 --tabs tmux    # force tmux
./pr_review.sh 42 43 --tabs bg      # force background
```

When a review finishes, the tab clears and shows the completed review. Each tab provides quick commands:

| Command | Action |
|---------|--------|
| `review` | Re-display the review |
| `pdiff` | View the PR diff |
| `files` | Show PR metadata and changed files |
| `exit` | Close the tab |

## How It Works

1. **Fetches PR metadata and diff** via `gh`
2. **Creates an isolated git worktree** at `~/.pr_reviewer/pr-<N>/`
3. **Copies env/config files** (`.env`, `.npmrc`, etc.) into the worktree so tests can run
4. **Launches Claude Code** with a 4-specialist agent team:
   - Code quality reviewer
   - Security reviewer
   - Logic and correctness reviewer
   - Architecture reviewer
5. **Produces `REVIEW.md`** in `.pr-review-context/` with findings, test results, and a verdict

## Environment Files

Git worktrees only contain tracked files. The script automatically copies common untracked files from the main repo:

- `.env`, `.env.local`, `.env.test`, `.env.development`, ...
- `.npmrc`, `.yarnrc`, `.python-version`, `.ruby-version`
- `config/master.key`, `config/credentials.yml.enc`
- `.vscode/settings.json`, `docker-compose.override.yml`
- Deep scan (4 levels) for per-service `.env` files

Add custom patterns: `-e ".env.staging,secrets/local.json"`

Skip entirely: `--no-env-copy`

## Examples

```bash
# Standard review
./pr_review.sh 42

# Three PRs in parallel tabs
./pr_review.sh 42 43 44

# More thorough review, auto-cleanup
./pr_review.sh 42 --max-turns 75 --cleanup

# Non-interactive, save output to file
./pr_review.sh 42 -o review-42.md

# Different repo, extra env files, subagents mode
./pr_review.sh 42 --repo myorg/myrepo -e ".env.staging" --no-teams

# Plain output (no colors, for CI)
NO_COLOR=1 ./pr_review.sh 42 -o review.md
```

## Testing

```bash
./test_pr_review.sh
```

Runs 101 tests covering: ANSI color validation, TTY/NO_COLOR detection, iTerm2 escape sequences, argument parsing, macOS compatibility, safety checks, helper functions, color rendering, worktree logic, and parallel mode.

## File Structure

```
.
├── pr_review.sh          # Main script
├── test_pr_review.sh     # Test suite
├── README.md             # This file
└── ~/.pr_reviewer/       # Created at runtime
    ├── pr-42/            # Worktree for PR #42
    │   └── .pr-review-context/
    │       ├── pr.diff
    │       ├── pr-info.md
    │       ├── REVIEW.md
    │       └── env-files-copied.log
    └── .lock-pr-42       # Lockfile (auto-removed)
```
