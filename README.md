# reviewer

A bash script to run parallel Claude Code agent reviews on GitHub PRs.

---

## Quick Start

```bash
brew install gh jq claude && gh auth login

git clone git@github.com:Reidmen/reviewer.git ~/reviewer
~/reviewer/reviewer.sh 42
```

Multiple PRs open in parallel tabs automatically:

```bash
~/reviewer/reviewer.sh 42 43 44
```

---

## Workflow

```
  reviewer.sh 42
       │
       ▼
  ┌─────────┐     ┌──────────┐     ┌──────────┐
  │ Fetch PR │────▶│ Worktree │────▶│ Copy env │
  │ metadata │     │ checkout │     │ & config │
  │ & diff   │     │ isolated │     │ files    │
  └─────────┘     └──────────┘     └────┬─────┘
                                        │
                    ┌───────────────────┐│
                    │ Claude Code       │▼
       ┌────────────┤ Agent Team  ┌──────────┐
       │            └─────────────┤ Lead     │
       │                          │ Agent    │
       │                          └────┬─────┘
       │                               │
       │            ┌──────────────────┼──────────────────┐
       │            │                  │                  │
       │       ┌────▼─────┐     ┌─────▼────┐     ┌──────▼─────┐
       │       │ Code     │     │ Security │     │ Logic &    │
       │       │ Quality  │     │ Auditor  │     │ Correctness│
       │       └──────────┘     └──────────┘     └────────────┘
       │
  ┌────▼──────────┐
  │ Architecture  │
  │ Reviewer      │
  └───────────────┘
       │
       ▼
  ┌──────────────────────────────────────────┐
  │ REVIEW.md                                │
  │                                          │
  │  Verdict  ·  Test runs  ·  Findings      │
  │  File-by-file notes  ·  Suggestions      │
  └──────────────────────────────────────────┘
```

Each reviewer runs tests, linters, and type-checkers inside the worktree. The lead agent synthesizes all findings into a structured review.

---

## Setup

```bash
brew install gh jq claude
gh auth login

# Option A: Run directly
git clone git@github.com:Reidmen/reviewer.git ~/reviewer
~/reviewer/reviewer.sh 42

# Option B: Symlink to PATH
ln -s ~/reviewer/reviewer.sh /usr/local/bin/reviewer
reviewer 42
```

Run from inside any git repo with a GitHub remote. The script auto-detects the repo and creates an isolated worktree under `~/.reviewer/`.

---

## Requirements

| Tool | Install | Purpose |
|------|---------|---------|
| `gh` | `brew install gh` + `gh auth login` | GitHub CLI |
| `git` | Pre-installed on macOS | Git 2.15+ (worktrees) |
| `claude` | `brew install claude` | Claude Code CLI |
| `jq` | `brew install jq` | JSON processing |

---

## Usage

```
reviewer.sh <PR_NUMBER...> [OPTIONS]
```

### Options

| Flag | Description | Default |
|------|-------------|---------|
| `-m, --model <model>` | Claude model for lead agent | `opus` |
| `-tm, --teammate-model <model>` | Model for teammate agents | same as `--model` |
| `-b, --max-turns <N>` | Max agentic turns per PR | `50` |
| `-r, --repo <owner/repo>` | Target repository | auto-detected |
| `-o, --output <path>` | Write review to file | -- |
| `-c, --cleanup` | Remove worktree after review | `false` |
| `-t, --no-teams` | Use subagents instead of teams | `false` |
| `-e, --env-files <globs>` | Extra env file patterns | built-in list |
| `--no-env-copy` | Skip env/config copying | `false` |
| `-d, --dir <path>` | Worktree parent directory | `~/.reviewer/` |
| `--tabs <mode>` | Parallel mode: `auto` `iterm` `tmux` `bg` | `auto` |
| `--no-color` | Disable colors | auto-detected |
| `-h, --help` | Show help | -- |

---

## Parallel Reviews

Pass 2+ PR numbers and the terminal is auto-detected:

| Terminal | Behavior | Navigation |
|----------|----------|------------|
| **iTerm2** | Named tab per PR | `Cmd+1-9` / `Cmd+Arrow` |
| **tmux** | Session with named windows | `Ctrl+B n/p` / `Ctrl+B w` |
| **Other** | Background with live status | Logs in `~/.reviewer/` |

Each completed tab provides quick commands: `review`, `pdiff`, `files`, `exit`.

---

## Examples

```bash
reviewer.sh 42                               # single PR review
reviewer.sh 42 43 44                         # parallel tabs
reviewer.sh 42 -m opus -tm sonnet            # opus lead, sonnet teammates
reviewer.sh 42 --max-turns 75 --cleanup      # deeper review, auto-cleanup
reviewer.sh 42 -o review.md                  # non-interactive, save to file
reviewer.sh 42 --repo myorg/myrepo           # different repo
reviewer.sh 42 -e ".env.staging" --no-teams  # custom env, subagent mode
NO_COLOR=1 reviewer.sh 42 -o out.md          # plain output for CI
```

---

## Environment Files

Worktrees only contain tracked files. The script copies common untracked files (`.env`, `.npmrc`, `config/master.key`, ...) so tests and builds work.

```bash
reviewer.sh 42 -e ".env.staging,secrets/local.json"  # add patterns
reviewer.sh 42 --no-env-copy                          # skip entirely
```

<details>
<summary><strong>Default patterns</strong></summary>

`.env*`, `.npmrc`, `.yarnrc`, `.yarnrc.yml`, `.pnp.cjs`, `.python-version`, `.ruby-version`, `.tool-versions`, `config/master.key`, `config/credentials.yml.enc`, `local.properties`, `docker-compose.override.yml`, `.vscode/settings.json`, `.idea/workspace.xml`, `*.auto.tfvars`, `terraform.tfvars`, `Procfile.dev`, plus a 4-level deep scan for per-service `.env` files.

</details>

---

## File Structure

```
.
├── reviewer.sh           # Main script
├── test_reviewer.sh      # Test suite (219 tests)
└── README.md

~/.reviewer/              # Created at runtime (configurable with --dir)
├── pr-42/                # Isolated worktree for PR #42
│   ├── (repo files)
│   └── .pr-review-context/
│       ├── pr.diff
│       ├── pr-info.md
│       ├── REVIEW.md     # Final review output
│       └── env-files-copied.log
└── .lock-pr-42           # Prevents duplicate runs (auto-removed)
```

---

## Testing

```bash
./test_reviewer.sh              # run all 219 tests
./test_reviewer.sh "Teammate"   # filter by section name
```

### Static Analysis

```bash
brew install shellcheck
shellcheck reviewer.sh test_reviewer.sh
```

Both scripts pass ShellCheck with no warnings (`-S warning`). Remaining info-level notes are intentional (e.g. subshell variable scope in test harness, deliberate glob expansion for env file patterns).

---

## Security

- **Autonomous mode** is on by default (`--dangerously-skip-permissions`). Use `--no-skip-permissions` for manual approval.
- **Env files** containing secrets are copied into worktrees. Use `--no-env-copy` for sensitive projects.
- **Worktree isolation** prevents modifications to your working branch, but the agent can execute commands within the worktree.

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `gh` not authenticated | `gh auth login` |
| Stale lockfile | `rm ~/.reviewer/.lock-pr-<N>` |
| Worktree issues | `rm -rf ~/.reviewer/pr-<N> && git worktree prune` |
| Turn limit hit | `reviewer.sh 42 --max-turns 75` |
| Missing env files | Check `env-files-copied.log`, add with `-e` |

---

## Uninstall

```bash
rm -rf ~/.reviewer          # remove worktrees and data
rm -rf /path/to/reviewer    # remove the script
```

---

## License

MIT
