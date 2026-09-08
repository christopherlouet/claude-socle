# Claude Code Team Guide

> Set up Claude Code and the foundation for a development team

## Why a shared configuration

Working as a team without a common configuration produces three concrete problems: each developer invents their own conventions, onboarding a new member takes weeks instead of a few hours, and quality audits give inconsistent results from one workstation to another.

A shared configuration via the foundation solves these three problems in a single move:

| Benefit | Without foundation | With foundation |
|---------|-------------------|-----------------|
| Code conventions | Each dev decides | `.claude/rules/` rules committed |
| Onboarding | 1 to 2 weeks | Less than 2 hours |
| Code quality | Variable | Uniform audit score |
| Workflow | Improvised | Explore → Specify → Plan → TDD → Audit → Commit |
| Secrets | Risk of accidental commit | Blocking gitleaks hook |

---

## 1. Shared CLAUDE.md

### Project-level CLAUDE.md (committed in git)

The `CLAUDE.md` file at the root of the project is the entry point for any Claude Code session. It is loaded automatically and applies to all team members.

This file should contain:

- The team's **mandatory workflow** (Explore → Specify → Plan → TDD → Audit → Commit)
- Project-specific **code conventions** (naming, structure, stack)
- **References** to internal documentation
- **`@imports`** to modular files to avoid overloading the context

Example of a project CLAUDE.md:

```markdown
# Project my-api

> Node.js/TypeScript REST API with PostgreSQL

@.claude/docs/reference/best-practices.md
@.claude/docs/reference/project-structures.md

## Mandatory Workflow

Explore → Specify → Plan → TDD → Audit → Commit

1. EXPLORE: /work:work-explore before any modification
2. SPECIFY: P1 User Stories (MVP) with Given/When/Then criteria
3. PLAN: Architecture and file list before coding
4. TDD: Tests BEFORE the code, Red-Green-Refactor cycle
5. AUDIT: /qa:qa-loop "score 90" before any commit
6. COMMIT: Conventional Commits, reference issues

## Conventions

- TypeScript strict, no `any`, interfaces for complex objects
- camelCase (vars), PascalCase (classes), kebab-case (files)
- Test coverage 80%+
- Branches: feature/xxx, fix/xxx

## Stack

Node.js 20, TypeScript 5, Express, Prisma, PostgreSQL 16
```

### Personal CLAUDE.md (~/.claude/CLAUDE.md)

Each developer can have their own CLAUDE.md in `~/.claude/` for personal preferences. This file is not committed to git and only applies to their machine.

Examples of personal preferences:

```markdown
# Personal preferences

- Preferred response language: English
- Preferred model: claude-opus-5 for complex tasks
- Response format: concise, no repetition
- My shortcuts: /w = work, /q = qa
```

### What goes where

| Element | Project CLAUDE.md | Personal CLAUDE.md | `.claude/rules/` | Memory |
|---------|------------------|--------------------|-----------------|--------|
| Team code conventions | Yes | No | Yes (per language) | No |
| Mandatory workflow | Yes | No | `workflow.md` | No |
| Documentation references | Yes | No | No | No |
| Response preferences | No | Yes | No | Yes |
| Preferred model | No | Yes | No | Yes |
| Architecture decisions | No | No | No | Yes (auto) |
| TypeScript rules | `@import` link | No | `typescript.md` | No |

---

## 2. Team configuration

### `.claude/settings.json` (committed) vs `.claude/settings.local.json` (gitignore)

The `.claude/settings.json` file is committed to git. It contains the team's shared configuration: permissions, hooks, common environment variables.

The `.claude/settings.local.json` file is in `.gitignore`. Each developer can override personal settings there without impacting the rest of the team.

| Setting | `settings.json` (shared) | `settings.local.json` (personal) |
|---------|-------------------------|----------------------------------|
| Permissions (allow/deny) | Yes - team security rules | No |
| Format/lint/tests hooks | Yes | Override possible |
| Common env variables | Yes (`INSIDE_CLAUDE_CODE`) | Yes (tokens, local paths) |
| `includeCoAuthoredBy` | Yes (false recommended) | No |
| Default model | No | Yes |

### Shared hooks

The foundation provides pre-configured hooks in `settings.json` that apply to the whole team:

```
PostToolUse: Auto-format (prettier, ruff, gofmt, dart format)
              TypeScript type-check after modification
              ESLint check after modification
PreToolUse: Tests before git commit (blocking)
              Local CI before git push (blocking)
              Gitleaks on Write/Edit (blocking if secret detected)
              Main branch protection (auto-creates a feature branch)
SessionStart: Verify .env in .gitignore
              Detect missing node_modules
```

To disable a hook on the fly without modifying the shared config:

```bash
# Skip pre-commit tests once
SKIP_PRE_COMMIT_TESTS=1 git commit -m "fix: typo correction"

# Allow a direct modification on main (exceptional case)
ALLOW_MAIN_EDIT=1 claude
```

### MCP servers: shared `.mcp.json`

The `.mcp.json` file is committed to git **empty** (`"mcpServers": {}`) — no server is active by default. There is **no per-server `enabled` flag** in the `.mcp.json` format: a server is active iff it is listed in `.mcp.json`. The curated catalogue ships alongside as **`.mcp.json.example`** (a reference file Claude does not load); each developer copies the server blocks they need into `.mcp.json` and provides the referenced env vars. Project-scoped servers prompt for approval on first use.

```json
// .mcp.json (committed empty — no server active by default)
{
  "mcpServers": {}
}
```

To enable a server, copy its block from `.mcp.json.example` into `.mcp.json` (there is no `enabled` flag — a server is active iff it is listed) and provide the referenced env vars:

```json
// .mcp.json (github enabled)
{
  "mcpServers": {
    "github": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"],
      "env": { "GITHUB_TOKEN": "${GITHUB_TOKEN}" }
    }
  }
}
```

### Environment variables: `.env.example` pattern

```bash
# .env.example (committed - contains ONLY placeholders)
DATABASE_URL=postgresql://user:password@localhost:5432/mydb
GITHUB_TOKEN=ghp_your_token_here
SENTRY_AUTH_TOKEN=your_sentry_token
API_SECRET_KEY=your_secret_key_32_characters

# .env (gitignore - contains the real values)
# NEVER committed
```

### When `.claude/` is gitignored — scope choices for plugins & skills

Some teams gitignore `.claude/` entirely (treating Claude Code config as personal tooling, not part of the codebase). That's a valid choice, but it changes how plugins, skills, and MCP servers should be installed because **nothing under `.claude/` will follow the project for teammates**.

#### (a) Why a team would gitignore `.claude/`

| Reason | When it makes sense |
|--------|---------------------|
| Treat AI tooling as personal preference | Polyglot teams where members use different AI assistants (Claude, Cursor, Copilot, none) |
| Avoid leaking workflow opinions | Open-source projects where contributors shouldn't be forced into one workflow |
| Faster, cleaner PR diffs | Large monorepos where `.claude/` churn would dominate `git log` |
| Vendored secrets concern | Teams that prefer to keep all `.claude/settings.local.json` material out of history, full stop |

#### (b) Consequence: project-scope installs do not propagate

When `.claude/` is gitignored, anything you install with project scope vanishes for the next teammate who clones the repo:

- `claude plugin install foo` with `--scope project` → writes to `.claude/settings.json` → **lost** on clone.
- `npx skills add bar --to ./.claude/skills/` → writes under `.claude/skills/` → **lost** on clone.
- A custom hook script under `scripts/hooks/` → committed (outside `.claude/`) → **kept**, but the hook reference in `.claude/settings.json` → **lost**.

The teammate sees a perfectly working repo, runs `claude` inside it, and silently loses every project-scoped extension you added. No error, no warning. This is the trap US-5 documents.

#### (c) Recommended scope per use case

Three install scopes are available; pick the one that survives the gitignore boundary:

| Scope | Where it lives | Survives `.claude/` gitignore? | When to use |
|-------|----------------|--------------------------------|-------------|
| **`user`** | `~/.claude/` (per-developer) | Yes — outside the repo | Personal preferences (theme, status line, keybindings); skills that all teammates will install anyway via shared onboarding doc |
| **`project`** | `<repo>/.claude/` (per-repo) | **No** if `.claude/` is gitignored | Conventions you're willing to commit; rules that should activate automatically when anyone opens the repo |
| **`local`** | `<repo>/.claude/settings.local.json` | **No** (always gitignored by convention) | Per-developer, per-repo overrides (env-specific paths, secrets) |

If `.claude/` is gitignored, the practical advice is:

1. **Default to `user` scope** for plugins and skills. Each teammate runs the install command themselves (one-time, documented in the onboarding section of TEAM-GUIDE).
2. **Document the recommended set** in the project's README or `docs/guides/onboarding.md` — including the exact install commands. The foundation's `print_recommended_vendor_skills` (re-printed at the end of every `update`) helps here: it lists the curated skills with their `claude plugin install <id>` / `git clone --depth 1 <url>` pointers.
3. **Track the foundation version** via the `.claude/.foundation-version` marker the foundation now writes (US-1). Even though `.claude/` is gitignored locally, that file gives you a stable reference if a teammate hits drift between their local foundation version and yours — they can ask you to share which version of claude-base produced the project.

#### (d) Concrete example per scope

| Scope | Example | Command |
|-------|---------|---------|
| **`user`** | The whole team uses `frontend-design` for UI work | `claude plugin install frontend-design@claude-plugins-official` (each dev runs this once on their machine) |
| **`project`** *(only if `.claude/` is committed)* | Project-specific rule that auto-activates on `*.tsx` | `cp my-rule.md .claude/rules/` + commit |
| **`local`** | Personal API key for a vendor MCP server | `.claude/settings.local.json` with the vendor section, never committed |

The trade-off:

- **`user` scope** keeps the gitignore clean but adds onboarding friction (each teammate must install the recommended set themselves).
- **`project` scope** auto-propagates if `.claude/` is committed but breaks completely if `.claude/` is gitignored.
- **`local` scope** is always per-developer, per-repo — useful for secrets but unsuitable for shared conventions.

If you want auto-propagation without committing `.claude/` wholesale, a partial-gitignore pattern works: gitignore `.claude/settings.local.json` and `.claude/.foundation-version`, but commit `.claude/rules/`, `.claude/agents/`, and `.claude/commands/`. The foundation's `update` flow respects this — it is copy-only by default, and the wipe variant (`--all --clean`) takes a full backup of every managed dir before touching anything.

---

### What ships in `.github/`

### GitHub Actions

- **ci.yml**: Tests (bats + node), shellcheck, lint, build
- **security.yml**: Gitleaks + shellcheck-security workflow
- **pr-check.yml**: PR format / size / labels validation (uses `amannn/action-semantic-pull-request`)
- **docs.yml**: Builds and deploys the Docusaurus site to GitHub Pages
- **release.yml**: Automated releases with changelog
- **dependabot-auto-merge.yml**: Auto-merges dependabot PRs that pass CI

Full file-by-file at `.github/workflows/`.

### Pre-commit Hooks

`claude-base init --hooks` (or `--all`) installs two git hooks into `.husky/`: **auto-lint** on staged
files (`lint-staged`, `pre-commit`) and **Conventional Commits validation** (`commitlint`,
`commit-msg`). Both are guarded on `npx` **and** a `package.json` — without them each one steps
aside rather than refusing the commit, so a project that never set up the Node tooling is not
blocked by a hook it cannot feed. To re-enable manually in an existing install: `npx husky install`
(assumes husky + lint-staged + commitlint are in your project's devDependencies).

Secret detection is **not** in these hooks. It ships in `.pre-commit-config.yaml` (the Python
`pre-commit` framework, `detect-secrets`), opt-in via `pip install pre-commit && pre-commit install`
— a separate tool with its own installation step. On the assistant side, `secret-scan.sh` covers
the same ground on every Edit/Write.

## 3. Code conventions

### Shared rules (`.claude/rules/`)

Files in `.claude/rules/` are committed to git and activate automatically based on the modified files. This is the most efficient mechanism to share code conventions without putting them in CLAUDE.md.

The foundation includes 32 pre-configured rules. For a team, the most important to commit are:

| Rule | Automatic activation | Team usefulness |
|------|---------------------|-----------------|
| `workflow.md` | Global | Mandatory cycle for everyone |
| `git.md` | Global | Conventional Commits, branches |
| `typescript.md` | `**/*.ts`, `**/*.tsx` | Strict mode, no `any` |
| `security.md` | `**/auth/**`, `**/api/**` | OWASP, XSS, injection |
| `tdd-enforcement.md` | All languages | Mandatory proactive TDD |
| `verification.md` | All languages | 4 verification phases |
| `deploy-safety.md` | `Dockerfile`, `.env*` | Pre-deploy checklist |

### Create a team-specific rule

For conventions not covered by the standard rules, create `.claude/rules/team-conventions.md`:

```markdown
---
paths:
  - "**/*.ts"
  - "**/*.tsx"
  - "**/services/**"
---
# My-API Team Conventions

## Service Naming
- One service per business domain: `UserService`, `OrderService`
- Methods as verb + noun: `createUser()`, `findOrderById()`
- NO `Manager`, `Handler`, `Helper` in names

## Error Handling
- Always use `AppError` (never `new Error()` directly)
- Error codes in SCREAMING_SNAKE: `USER_NOT_FOUND`
- Log errors with context: userId, requestId

## Imports
- Absolute imports only (no `../../`)
- Order: node_modules / types / services / utils / local
```

### Recommended effort levels per phase

| Workflow phase | Effort | Justification |
|---------------|--------|---------------|
| Explore (reading code) | `low` | No deep reasoning needed |
| Specify (user stories) | `medium` | Clarifying needs |
| Plan (architecture) | `high` | Structuring decisions |
| TDD (implementation) | `medium` | Implementation guided by tests |
| Audit (quality) | `high` | Detection of subtle problems |
| Complex debug | `xhigh` | Deepest routinely-useful reasoning (`max` is the ceiling above it — reserve it) |

### Recommended models per usage

| Usage | Model | Why |
|-------|-------|-----|
| Hardest / long-horizon autonomous work (rare) | Fable 5.1 (`claude-fable-5-1`) | 2× Opus 5 on input and output, but **cheaper per cache read** — **deliberate niche** use since Opus 5 |
| Architecture, design | Opus 5 | Near-Fable reasoning at half Fable's price, 1M context, `xhigh` effort |
| Feature implementation | Sonnet | Speed/quality balance |
| Exploration, reading | Haiku | Fast for simple operations |
| Security audits | Sonnet or Opus 5 | Detection of subtle flaws |
| PR reviews in CI | Haiku | Low cost, high volume |
| Cloud review (large PRs) | `/code-review ultra` | Parallel agents in cloud (`/ultrareview` is a deprecated alias) |

> **Running the foundation's own heavy sessions on Fable 5.1:** Opus 5 is the right pick for large migrations and deep audits too — this is Anthropic's own guidance, which says to start from Opus 5 and reach for Fable 5.1 when evals on Opus 5 at higher effort still fall short. Reserve `--model claude-fable-5-1` (or `/model`) for those runs. Two updates since 2026-09-01: `claude-fable-5-1` is the default Fable model, and **a `fable` alias now exists** in sub-agent frontmatter. This foundation still never pins an agent to Fable — that is a cost decision, not a limitation. On cost, the old "2× Opus 5" shorthand holds for input and output but not for cache reads, which are `$0.25` per MTok on Fable 5.1 against `$0.50` on Opus 5 ([announcement](https://www.anthropic.com/claude-fable-and-mythos-5-1)).

---

## 4. Onboarding a new member

Complete checklist for a new developer joining the team:

### Step 1: Clone the repo

```bash
git clone https://github.com/org/my-project.git
cd my-project
```

### Step 2: Install Claude Code

```bash
npm install -g @anthropic-ai/claude-code
```

Configure the API key:

```bash
export ANTHROPIC_API_KEY=sk-ant-your-key
# Or add to ~/.bashrc / ~/.zshrc
```

### Step 3: Initialize the foundation

```bash
./bin/claude-base init --simple .
```

This dispatcher invocation configures the hooks, the permissions, and verifies the `.claude/` structure.

### Step 4: Copy the environment variables

```bash
cp .env.example .env
# Edit .env with the real values (provided by the lead)
```

### Step 5: First session - codebase discovery

```bash
claude
/work:work-explore
```

The `work-explore` agent reads the codebase, identifies the patterns in place, and produces a structured summary. Let it run for 10 to 15 minutes for a medium-sized project.

Complement: `/team-onboarding` (built-in CLI 2.1.101+) automatically generates an onboarding guide based on local Claude Code usage. Useful for the lead preparing the ground before the new member arrives.

### Step 6: First task - "good first issue"

The lead assigns an issue labeled `good first issue` on GitHub. Expected workflow:

```bash
/work:work-explore          # Understand the task context
/work:work-specify          # Clarify acceptance criteria
/work:work-plan             # Propose a solution
/dev:dev-tdd                # Implement in TDD
/qa:qa-loop "score 90"      # Validate quality
/work:work-pr               # Create the Pull Request
```

### Step 7: Validate the workflow understanding

Before working autonomously, check that the new member:

- [ ] Understands the difference between `commands/` and `agents/`
- [ ] Knows how to read a quality audit (`/qa:qa-audit`)
- [ ] Has committed their first change with Conventional Commits
- [ ] Has created their first PR with a complete description
- [ ] Knows the active hooks (and how to disable them if needed)

---

## 5. Team git workflow

### Branch strategy

```
main          # Production - protected, merge via PR only
develop       # Integration (optional, teams >5 people)
feature/xxx   # New features
fix/xxx       # Bug fixes
refactor/xxx  # Refactoring without functional change
```

The foundation's `PreToolUse` hook prevents direct modifications on `main` and automatically creates a `feature/auto-YYYYMMDD-HHMMSS` branch. Then rename with:

```bash
git branch -m feature/descriptive-name
```

### Shared hooks for code protection

| Hook | Trigger | Action |
|------|---------|--------|
| Main protection | Edit/Write on main | Auto-creates a feature branch |
| Pre-commit tests | `git commit` | Runs the test suite, blocks on failure |
| Pre-push local CI | `git push` | Lint + type-check + tests, blocks on failure |
| Gitleaks | Write/Edit | Detects secrets, blocks if found |
| Destructive check | SQL DROP/DELETE commands | Asks for confirmation |

### Code review: human vs Claude

| Type of review | Reviewer | Command |
|---------------|----------|---------|
| Business logic, UX | Human mandatory | Standard GitHub PR |
| Security, auth, payment | Human + Claude | `/qa:qa-security` before PR |
| Code quality, conventions | Claude | `/qa:qa-loop "score 90"` |
| Tests, coverage | Claude | `/qa:qa-tech-debt` |
| Accessibility | Claude | `/qa:wcag-audit` |
| Performance | Claude | `/qa:qa-perf` |

Recommendation: configure `claude-code-action` on GitHub so Claude automatically reviews each PR. Ready-to-use GitHub Actions workflows are in `.claude/templates/github-actions/` (the directory also holds the plan/spec/tasks templates used by the workflow commands).

### Conflict resolution

```bash
# Update your branch before pushing
git fetch origin
git rebase origin/main

# In case of difficult conflict
/work:work-explore    # Understand both versions
# Resolve manually, then:
git add .
git rebase --continue
```

---

## 6. Parallel sessions

### Git worktrees for parallel work

The most efficient technique for multiple simultaneous tasks:

```bash
# Create a worktree for a parallel feature
git worktree add ../my-project-feature-auth feature/auth

# Launch Claude Code in the worktree
cd ../my-project-feature-auth
claude

# Clean up after merge
git worktree remove ../my-project-feature-auth
```

### Named sessions

To manage multiple sessions without worktrees:

```bash
# Session dedicated to a feature
claude --name "feature-auth"

# Session dedicated to tests (short flag)
claude -n "test-coverage"
```

### Agent teams for coordinated work

For complex tasks requiring coordination:

```bash
/work:work-team "implement OAuth2 authentication with tests and documentation"
```

The `work-team` agent orchestrates several specialized sub-agents (dev, test, doc) in parallel.

### When to use which approach

| Context | Approach | Command |
|---------|----------|---------|
| Single simple task | Standard session | `claude` |
| Two parallel features | Git worktrees | `git worktree add` |
| Complex multi-domain feature | Agent team | `/work:work-team` |
| 5+ independent tasks | Worktrees + named sessions | `claude --name "name"` |
| Exploration + implementation | `/compact` between phases | `/compact` |

---

## 7. Team security

### Secrets management

Non-negotiable principles:

- `.env` always in `.gitignore` - check before each new project
- `.env.example` committed with placeholders, never real values
- Rotate secrets if a commit containing a secret slips through anyway

The foundation's `SessionStart` hook automatically verifies that `.env` is in `.gitignore` and alerts if it isn't.

### Gitleaks: automatic detection

The foundation's `PreToolUse` hook runs `gitleaks` before each Write/Edit if the tool is installed and a `.gitleaks.toml` file exists:

```bash
# Install gitleaks
brew install gitleaks  # macOS
# or
curl -sSL https://github.com/zricethezav/gitleaks/releases/latest/download/gitleaks_linux_x64.tar.gz | tar xz

# Test manually
gitleaks detect --no-git --source .
```

### Recommended permission modes for the team

| Mode | Use case | Risk |
|------|---------|------|
| `default` | Standard development | Asks confirmation for risky actions |
| `acceptEdits` | CI pipeline, automated reviews | Accepts modifications without confirmation |
| Explicit deny list | All team projects | Blocks defined destructive commands |

The foundation's deny list blocks by default: `git push --force`, `git reset --hard`, `rm -rf`, `sudo`, `chmod 777`, and shutdown operations. Pipe-to-shell patterns (`curl URL | bash`) are blocked by a separate layer: the command-validator PreToolUse hook (category 2 of its 9 risk categories).

### Security checklist for team repos

- [ ] `.env` in `.gitignore` (verified by SessionStart hook)
- [ ] `.env.example` with placeholders committed
- [ ] Gitleaks installed on all developer workstations
- [ ] `.gitleaks.toml` configured and committed
- [ ] `main` branch protected on GitHub (branch protection rules)
- [ ] PRs mandatory to merge on main (1 reviewer minimum)
- [ ] Secrets in a team vault (1Password, Vault, AWS Secrets Manager)
- [ ] Secret rotation documented in the ops runbook
- [ ] `/qa:qa-security` run before each release

---

## 8. Measuring productivity

### Token cost tracking

```bash
/ops:ops-cost
```

This agent produces a report of tokens consumed per session, per model, and per type of task. Useful for optimizing team costs.

### Effort levels to optimize costs

Using the right effort level avoids consuming tokens unnecessarily:

```bash
/effort low      # Reading, exploration
/effort medium   # Standard implementation
/effort high     # Architecture, refactoring
/effort xhigh    # Critical debug (Opus-class models)
```

### Typical consumption per workflow phase

| Phase | Token volume (approximate) | Recommended model |
|-------|---------------------------|-------------------|
| Explore (medium codebase) | 50k - 150k input | Haiku |
| Specify (user stories) | 5k - 20k | Sonnet |
| Plan (complex feature) | 10k - 40k | Opus 5 |
| TDD (implementation) | 30k - 100k | Sonnet |
| Quality audit | 20k - 60k | Sonnet |
| PR review | 5k - 15k | Haiku |

---

## Useful commands for the lead

| Situation | Command | Usage |
|-----------|---------|-------|
| Onboarding new member | `/work:work-explore` | Produce a codebase discovery guide |
| Coordination of parallel features | `/work:work-team "description"` | Orchestrate multiple agents on a large feature |
| Team cost tracking | `/ops:ops-cost` | Token report and optimizations |
| Quality gate before release | `/qa:qa-audit` | Full audit security + RGPD + A11y + Perf |
| Audit + fix loop | `/qa:qa-loop "score 90"` | Automatic correction until target score |
| Full release | `/work:work-flow-release "v2.0.0"` | Release workflow with changelog and tag |
| Batch of stories | `/work:work-batch "prd.json"` | Process a backlog in batch |

---

## Team anti-patterns

- No shared `CLAUDE.md`: each developer invents their conventions, the codebase diverges
- Each dev has a different configuration: impossible to reproduce audits
- No committed rules: conventions stay in heads, not in code
- No code review process: quality depends on individual goodwill
- Secrets in git: a git history is not easily erased, mandatory rotation
- No onboarding document: knowledge is in Slack and emails
- Sessions too long without `/compact`: degraded context, lower generation quality
- Skipping the Audit phase before commit: technical debt accumulates silently
- Modifying shared `settings.json` for personal preferences: use `settings.local.json`
