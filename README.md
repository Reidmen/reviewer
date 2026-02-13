<div align="center">

# pr-review.sh

**Automated PR code review powered by Claude Code agent teams**

Git worktrees for full isolation. Four specialist reviewers. Parallel reviews in iTerm2, tmux, or background processes.

[![Shell](https://img.shields.io/badge/shell-bash%205.0%2B-blue)](#requirements)
[![Tests](https://img.shields.io/badge/tests-160%20passing-brightgreen)](#testing)
[![macOS](https://img.shields.io/badge/platform-macOS-lightgrey)](#requirements)
[![License](https://img.shields.io/badge/license-MIT-green)](#license)

</div>

---

## Table of Contents

- [Why](#why)
- [Quick Start](#quick-start)
- [Requirements](#requirements)
- [Usage](#usage)
- [Parallel Reviews](#parallel-reviews)
- [How It Works](#how-it-works)
- [Examples](#examples)
- [Environment Files](#environment-files)
- [Testing](#testing)
- [Troubleshooting](#troubleshooting)
- [Security](#security)
- [Uninstall](#uninstall)
- [Contributing](#contributing)
- [License](#license)

---

## Why

Manual code reviews are slow, inconsistent, and drain senior engineers. This script launches a **team of four AI specialists** -- code quality, security, logic/correctness, and architecture -- against any GitHub PR. Each reviewer works from a fully isolated git worktree with access to the real test suite, linters, and build tools. Reviews are thorough, structured, and delivered in minutes.

---

## Quick Start

```bash
# 1. Clone
git clone git@github.com:Reidmen/reviewer.git && cd reviewer

# 2. Install dependencies (macOS)
brew install gh jq
gh auth login
npm i -g @anthropic-ai/claude-code

# 3. Review a PR
./pr_review.sh 42
```

That's it. The script handles worktree creation, environment setup, and agent orchestration automatically.

> **Tip:** Pass multiple PR numbers to review them in parallel -- each opens in its own terminal tab.
>
> ```bash
> ./pr_review.sh 42 43 44
> ```

---

## Requirements

| Tool | Install | Purpose |
|------|---------|---------|
| `gh` | `brew install gh` then `gh auth login` | GitHub CLI |
| `git` | Pre-installed on macOS | Git 2.15+ for worktree support |
| `claude` | `npm i -g @anthropic-ai/claude-code` | Claude Code CLI |
| `jq` | `brew install jq` | JSON processing |

> **Note:** This tool uses the Claude API through Claude Code. You need an active Anthropic API key or a Claude Code subscription. Each PR review typically uses 30--75 agentic turns depending on the `--max-turns` setting.

---

## Usage

```
./pr_review.sh <PR_NUMBER...> [OPTIONS]
```

### Core Options

| Flag | Description | Default |
|------|-------------|---------|
| `-r, --repo <owner/repo>` | Target GitHub repository | Auto-detected |
| `-d, --dir <path>` | Parent directory for worktrees | `~/.pr_reviewer/` |
| `-m, --model <model>` | Claude model for the lead agent | `opus` |
| `-b, --max-turns <N>` | Max agentic turns per PR | `50` |
| `-h, --help` | Show help | -- |

### Output Options

| Flag | Description | Default |
|------|-------------|---------|
| `-o, --output <path>` | Write review to file (single-PR, non-interactive) | -- |
| `-c, --cleanup` | Remove worktree after review | `false` |
| `--no-color` | Disable colored output | Auto-detected |

### Agent Options

| Flag | Description | Default |
|------|-------------|---------|
| `-t, --no-teams` | Use subagents instead of agent teams | `false` |
| `--no-skip-permissions` | Require manual approval for each tool use | `false` |

### Environment Options

| Flag | Description | Default |
|------|-------------|---------|
| `-e, --env-files <globs>` | Extra file patterns to copy (comma-separated) | Built-in list |
| `--no-env-copy` | Skip copying env/config files | `false` |

### Terminal Options

| Flag | Description | Default |
|------|-------------|---------|
| `--tabs <mode>` | Tab mode: `auto`, `iterm`, `tmux`, `bg` | `auto` |

<details>
<summary><strong>Color behavior</strong></summary>

Colors are automatically enabled when both stdout and stderr are TTYs. They are disabled when:

- Output is piped or redirected
- `NO_COLOR=1` is set (per [no-color.org](https://no-color.org))
- `PR_REVIEW_NO_COLOR=1` is set
- `--no-color` flag is passed

</details>

---

## Parallel Reviews

Pass two or more PR numbers and the script auto-detects your terminal:

| Terminal | What happens | Navigation |
|----------|-------------|------------|
| **iTerm2** | One named tab per PR | `Cmd+1-9` or `Cmd+Arrow` |
| **tmux** | Session with named windows | `Ctrl+B n/p` or `Ctrl+B w` |
| **Other** | Background processes with live status | Logs in `~/.pr_reviewer/` |

Override with `--tabs`:

```bash
./pr_review.sh 42 43 --tabs tmux    # Force tmux
./pr_review.sh 42 43 --tabs bg      # Force background
```

When a review finishes, the tab clears and shows the completed review. Each tab provides quick commands:

| Command | Action |
|---------|--------|
| `review` | Re-display the review |
| `pdiff` | View the PR diff |
| `files` | Show PR metadata and changed files |
| `exit` | Close the tab |

---

## How It Works

```
  PR #42
    |
    v
 +------------------+     +---------------------+     +---------------------+
 | Fetch PR metadata | --> | Create git worktree | --> | Copy env/config     |
 | and diff via gh   |     | ~/.pr_reviewer/     |     | files into worktree |
 +------------------+     +---------------------+     +---------------------+
                                                              |
                                                              v
                                            +----------------------------------+
                                            |     Claude Code Agent Team       |
                                            |                                  |
                                            |  +------------+ +-------------+  |
                                            |  | Code       | | Security    |  |
                                            |  | Quality    | | Reviewer    |  |
                                            |  +------------+ +-------------+  |
                                            |  +------------+ +-------------+  |
                                            |  | Logic &    | | Architec-   |  |
                                            |  | Correctness| | ture        |  |
                                            |  +------------+ +-------------+  |
                                            +----------------------------------+
                                                              |
                                                              v
                                                      +---------------+
                                                      |  REVIEW.md    |
                                                      |  - Verdict    |
                                                      |  - Test runs  |
                                                      |  - Findings   |
                                                      +---------------+
```

**Step by step:**

1. **Fetches PR metadata and diff** via `gh`
2. **Creates an isolated git worktree** at `~/.pr_reviewer/pr-<N>/`
3. **Copies env/config files** (`.env`, `.npmrc`, etc.) so tests can run
4. **Launches Claude Code** with a 4-specialist agent team that reads code, runs tests, and produces findings
5. **Generates `REVIEW.md`** with an executive summary, test results, categorized findings, and a file-by-file breakdown

---

## Examples

```bash
# Standard review
./pr_review.sh 42

# Three PRs in parallel tabs
./pr_review.sh 42 43 44

# More thorough review with auto-cleanup
./pr_review.sh 42 --max-turns 75 --cleanup

# Non-interactive, save output to file
./pr_review.sh 42 -o review-42.md

# Different repo, extra env files, subagents mode
./pr_review.sh 42 --repo myorg/myrepo -e ".env.staging" --no-teams

# Plain output for CI pipelines
NO_COLOR=1 ./pr_review.sh 42 -o review.md
```

---

## Environment Files

Git worktrees only contain tracked files. The script automatically copies common untracked files from the main repo so that tests, linters, and builds work inside the worktree.

<details>
<summary><strong>Default file patterns copied</strong></summary>

- `.env`, `.env.local`, `.env.test`, `.env.development`, `.env.development.local`, `.env.test.local`, `.env.production.local`, `.env.docker`
- `.npmrc`, `.yarnrc`, `.yarnrc.yml`, `.pnp.cjs`, `.pnp.loader.mjs`
- `.python-version`, `pyrightconfig.json`
- `.ruby-version`, `.tool-versions`
- `config/master.key`, `config/credentials.yml.enc`
- `local.properties`, `.air.toml`
- `docker-compose.override.yml`, `.docker/config.json`
- `.vscode/settings.json`, `.vscode/launch.json`, `.idea/workspace.xml`
- `*.auto.tfvars`, `terraform.tfvars`
- `Procfile.dev`
- Deep scan (4 directory levels) for per-service `.env` files

</details>

**Add custom patterns:**

```bash
./pr_review.sh 42 -e ".env.staging,secrets/local.json"
```

**Skip entirely:**

```bash
./pr_review.sh 42 --no-env-copy
```

---

## Testing

```bash
./test_pr_review.sh
```

Runs **160 tests** covering:

- ANSI color validation and rendering
- TTY and `NO_COLOR` detection
- iTerm2 escape sequences
- Argument parsing and edge cases
- macOS compatibility
- Safety checks and lockfile handling
- Helper functions
- Worktree creation and cleanup logic
- Parallel mode orchestration

---

## Troubleshooting

<details>
<summary><strong>"gh" is not authenticated</strong></summary>

```
FATAL: GitHub CLI is not authenticated. Run: gh auth login
```

Run `gh auth login` and follow the prompts to authenticate with your GitHub account.

</details>

<details>
<summary><strong>Stale lockfile blocking a review</strong></summary>

```
FATAL: Another review of PR #42 is already running (PID 12345).
```

If the previous review crashed, the lockfile may be stale. Remove it manually:

```bash
rm ~/.pr_reviewer/.lock-pr-42
```

The script detects stale lockfiles automatically when the referenced PID is no longer running, but in rare cases manual removal may be needed.

</details>

<details>
<summary><strong>Worktree already exists</strong></summary>

The script automatically removes stale worktrees before creating new ones. If you encounter persistent issues:

```bash
# Remove a specific worktree
rm -rf ~/.pr_reviewer/pr-42
git worktree prune

# Remove all review worktrees
rm -rf ~/.pr_reviewer
```

</details>

<details>
<summary><strong>Claude times out or hits turn limit</strong></summary>

Increase the turn budget:

```bash
./pr_review.sh 42 --max-turns 75
```

The default of 50 turns works for most PRs. Large PRs (500+ lines changed) may benefit from 75--100 turns.

</details>

<details>
<summary><strong>Tests fail in the worktree</strong></summary>

The worktree may be missing untracked configuration files. Check which files were copied:

```bash
cat ~/.pr_reviewer/pr-42/.pr-review-context/env-files-copied.log
```

Add missing patterns with `-e`:

```bash
./pr_review.sh 42 -e ".env.custom,config/local.yml"
```

</details>

---

## Security

This tool has security implications you should be aware of:

- **`--dangerously-skip-permissions`** is enabled by default, giving Claude autonomous access to run commands in the worktree. Use `--no-skip-permissions` to require manual approval for each tool invocation.
- **Environment files** (`.env`, `config/master.key`, etc.) are copied into worktrees. These may contain secrets. Worktrees are created under `~/.pr_reviewer/` with standard file permissions.
- **Worktree isolation** means the review cannot modify your working branch, but the agent can execute arbitrary commands within the worktree directory.

> **Recommendation:** Review the [default env patterns](#environment-files) and use `--no-env-copy` if your project contains highly sensitive credentials.

---

## File Structure

```
.
├── pr_review.sh          # Main script (~1100 lines)
├── test_pr_review.sh     # Test suite (160 tests)
├── README.md             # This file
└── ~/.pr_reviewer/       # Created at runtime
    ├── pr-42/            # Worktree for PR #42
    │   └── .pr-review-context/
    │       ├── pr.diff           # Full PR diff
    │       ├── pr-info.md        # PR metadata and description
    │       ├── REVIEW.md         # Final review output
    │       └── env-files-copied.log  # Manifest of copied files
    └── .lock-pr-42       # Lockfile (auto-removed)
```

---

## Uninstall

```bash
# Remove review worktrees and data
rm -rf ~/.pr_reviewer

# Remove the script
rm -rf /path/to/reviewer

# (Optional) Remove Claude Code CLI
npm uninstall -g @anthropic-ai/claude-code
```

---

## Contributing

Contributions are welcome. Please:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/my-change`)
3. Run the test suite (`./test_pr_review.sh`) and ensure all 160 tests pass
4. Submit a pull request

For bugs and feature requests, open an [issue](https://github.com/Reidmen/reviewer/issues).

---

## License

MIT License. See [LICENSE](LICENSE) for details.
