---
sidebar_position: 10
title: "Advanced Features"
description: "10 interaction modes in `.claude/output-styles/`: `teaching`, `explanatory` (recommended), `concise`, `technical`, `review`, `emoji`, `minimal`, `stru"
tags:
  - "reference"
---

<!-- Auto-generated from docs/ - DO NOT EDIT -->

# Advanced Features

## Output Styles

10 interaction modes in `.claude/output-styles/`: `teaching`, `explanatory` (recommended), `concise`, `technical`, `review`, `emoji`, `minimal`, `structured`, `debug`, `metrics`.

## Specification Templates

Templates in `.claude/templates/` for the Explore → Specify → Plan → TDD → Audit → Commit workflow:

| Template | Used by |
|----------|-------------|
| `spec-template.md` | `/work:work-specify` |
| `plan-template.md` | `/work:work-plan` |
| `tasks-template.md` | `/work:work-plan` |

Structure: `specs/[feature]/` contains `spec.md`, `plan.md`, `tasks.md`, `clarifications.md` (opt).

Conventions: `P1`=MVP, `P2`=Important, `P3`=Nice-to-have, `[P]`=parallelizable, `[US1]`=User Story 1.

Proxmox templates (Terraform) available in `.claude/templates/proxmox/`.

## Automatic Memory (CLI 2.1.76+)

Claude Code automatically saves and recalls memories as work progresses (preferences, decisions, project context). Memories are stored in `~/.claude/memory/`.

| To memorize | To put in CLAUDE.md | To put in rules/ |
|-------------|------------------------|---------------------|
| Personal preferences | Project conventions | Per-language/framework rules |
| Architecture decisions | Mandatory workflow | Code patterns |
| Team context | Documentation references | Verification checklist |

Best practices:
- Let Claude memorize preferences and decisions (avoids repetition)
- Keep in CLAUDE.md what is shared with the team (versioned in git)
- Do not duplicate: if it is in CLAUDE.md, no need to memorize it
- Use "remember that..." to force an explicit memorization

## Effort Levels (CLI 2.1.76+)

`/effort` command to control the reasoning level (interactive slider since v2.1.111):

| Level | Command | Use case |
|--------|----------|-------------|
| `low` | `/effort low` | Exploration, formatting, simple tasks |
| `medium` | `/effort medium` | Standard development, fixes |
| `high` | `/effort high` | Architecture, audit, complex refactoring, debug |
| `xhigh` | `/effort xhigh` | Critical system architecture, advanced security audit (Opus-class models: Opus 5 / 4.8) |
| `max` | `/effort max` | The ceiling, above `xhigh` — reserve for the hardest single problem; slowest and most expensive per turn |

Recommendations per foundation workflow:

| Phase | Recommended effort |
|-------|-------------------|
| `/work:work-explore` | low |
| `/work:work-specify`, `/work:work-plan` | high |
| `/dev:dev-tdd` | medium |
| `/qa:qa-audit`, `/qa:qa-security` | high or xhigh |
| `/work:work-commit` | low |

## Named Sessions (CLI 2.1.76+)

`--name` / `-n` flag to name a session at startup:

```bash
claude --name "feature-auth"
claude -n "fix-login-bug"
```

Combine with git worktrees for isolated and identifiable sessions:

```bash
git worktree add ../myapp-auth -b feature/auth
cd ../myapp-auth && claude -n "auth-feature"
```

## VSCode URI Handler (CLI 2.1.76+)

Open a Claude Code tab programmatically from VSCode:

```
vscode://anthropic.claude-code/open
```

Useful for: CI/CD integration, setup scripts, notification hooks.

## Opus 5 (recommended default, since 2026-07-24)

`claude-opus-5` is the new default of the `opus` tier alias (CC 2.1.219) — **same price as Opus 4.8 (`$5/$25` per MTok) with greatly improved performance**: within ~0.5% of Fable 5's peak scores at half Fable's price, double Opus 4.8 on Frontier-Bench v0.1, and ahead of Fable 5 on OSWorld 2.0. 1M context, configurable effort settings, fast mode at `$10/$50` per MTok (~2.5× speed). Agent `model: opus` frontmatter picks it up with no change. Opus 4.8 is not deprecated — it serves as fallback for flagged requests and stays available in fast mode. ([Announcement](https://techcrunch.com/2026/07/24/anthropic-launches-opus-5/))

## Fable 5.1 (above-Opus tier — niche since Opus 5)

`claude-fable-5-1` (since 2026-09-01, CC 2.1.257 — the default Fable model, superseding `claude-fable-5`): 1M context (default and max), 128K output, `$10/$50` per MTok. Anthropic's own guidance is to start from Opus 5 for most workloads and reach for Fable 5.1 for demanding reasoning and long-horizon agentic work, or when evals on Opus 5 at higher effort still fall short — which is the position this foundation already took. It stays a **rare, deliberate escalation**, not the routine "hard chantier" pick it briefly was.

**What changed with 5.1 is the cache economics, not the sticker price.** Cache reads dropped to `$0.25` per MTok, a quarter of Fable 5's; Anthropic estimates ~25% off a typical workload and up to ~45% off a highly agentic one. Every other model reads cache at 0.1× base input; Opus 5 reads at `$0.50` per MTok, so **Fable 5.1's cache reads are half of Opus 5's.** Base input and output remain 2× Opus 5, so the "2× Opus 5" shorthand still holds for a short one-shot request but overstates the gap for a long session re-reading a cached prefix.

A **`fable` alias now exists** in sub-agent `model:` frontmatter (alongside `sonnet`, `opus`, `haiku`, full ids and `inherit`). This foundation still pins no agent to Fable: that is a cost decision, no longer a limitation of the tool. In Claude apps gateway sessions `fable` and `best` still resolve to Fable 5 rather than 5.1 (CC 2.1.260), so select 5.1 explicitly.

Three breaking changes if you call it from the SDK: forced tool use (`tool_choice` `any`/`tool`) returns a 400, earlier models cannot read its thinking blocks, and editing earlier turns invalidates them. Claude Code keeps the prefix intact for you; hand-built `messages` arrays need the history-editing check.

> ✅ **Availability:** the tier has been generally available since 2026-07-01 (the June export-control directive was lifted 2026-06-30). Mythos 5.1 is restricted to Project Glasswing participants. ([Fable 5.1 announcement](https://www.anthropic.com/claude-fable-and-mythos-5-1), [what's new](https://platform.claude.com/docs/en/models/fable-5-1/whats-new-fable-5-1))

Behaviourally: thinking is always on (the raw chain of thought is never returned) and individual turns on hard tasks can run several minutes — plan for streaming and async check-ins. Versus Fable 5, 5.1 batches parallel tool calls less predictably, writes fewer progress updates, and is likelier to rewrite a whole file instead of making a targeted edit. For the API-level caveats when building with the SDK (no `thinking:{type:"disabled"}`, no assistant prefill, refusal classifiers, 30-day data retention), see the `dev-ai-integration` skill.

## Opus 4.8 (superseded by Opus 5)

Frontier model from 2026-05-28 to 2026-07-24; now the fallback behind Opus 5 (same pricing). Introduced **`high` effort by default**, Adaptive Thinking (replaces `budget_tokens`), the effort ladder (`low`–`max`, `xhigh` slotted in below `max` in v2.1.111), 1M context by default and 128k output. Anthropic reported it roughly **4× less likely than Opus 4.7 to let a flaw in code it has written pass unremarked** — the property that made Opus-class models the recommendation for the TDD and Audit phases, which Opus 5 inherits.

**Auto mode (native, July 2026)** — a Claude Code permission mode where a model classifier approves/denies each tool call in place of the human (positioned as the safe alternative to `--dangerously-skip-permissions`; default-on for Bedrock/Vertex/Foundry since CLI 2.1.207). **It composes with — and does not replace — this foundation's hooks**: the classifier is probabilistic and decides *approval*, while the foundation's PreToolUse guards (command-validator, destructive-ops, config-protection, bash-write-guard…) are deterministic *class blockers* that keep running under any permission mode, auto included. Running both is defense in depth: keep the hooks even with auto mode on.

## Sonnet 5 (default tier, since 2026-06-30)

`claude-sonnet-5` is Anthropic's most agentic Sonnet yet — released 2026-06-30 and now **Claude Code's default model**. It delivers **near-Opus 4.8 quality on many agentic tasks at roughly a third of the cost**, with a **native 1M-token context**. Pricing is **`$2/$10` per MTok** (vs Opus 4.8 at `$5/$25`) — announced as introductory through 2026-08-31, but **made the permanent standard price on 2026-08-10**; the scheduled rise to `$3/$15` on September 1 will not happen.

The `sonnet` tier alias resolves to Sonnet 5 automatically, so agent `model: sonnet` frontmatter picks it up with **no change needed**. This foundation recommends **Opus 5 for complex/critical work** (TDD, Audit, architecture) — see [best-practices.md](/docs/reference/best-practices) — and uses Sonnet 5 where its price/perf wins: audits, analyses, and high-volume agentic passes.

## Checkpoint / Rewind

Claude Code automatically saves the state of the code before each modification (checkpoint). To return to a previous state:

| Method | Action |
|---------|--------|
| `Esc` × 2 | Cancel the last modification and return to the checkpoint |
| `/rewind` | Choose a specific checkpoint in the history |
| `/undo` | Alias of `/rewind` (CLI 2.1.108+) |

Recommended in the TDD Refactor phase: if the refactoring breaks the tests, `/rewind` (or `/undo`) is faster than a manual git revert.

## Session Recap (CLI 2.1.108+)

`/recap` generates a structured summary of the session: decisions made, files modified, work state. Configurable in `/config`.

| Situation | Action |
|-----------|--------|
| Return after a break | `/recap` to recover the context |
| After `/compact` | `/recap` to verify what has been kept |
| Resumed session | Automatic recap on resume (if enabled in `/config`) |

## Fast Mode (Research Preview)

Same Opus model at ~2.5× faster output, 2× base price (`$10/$50` per MTok on Opus 5). Toggle with `/fast`. Runs on Opus 5 and Opus 4.8 (Opus 4.7 was removed from fast mode in CC 2.1.219).

| Use case | Recommendation |
|-------------|----------------|
| Exploration, commits, simple tasks | Fast mode suitable |
| Architecture, audit, complex debug | Standard mode recommended |

## Context Compaction

Compaction automatically summarizes the context when the window approaches its limit. Manual trigger with `/compact`.

| Command | Effect | When to use |
|----------|-------|----------------|
| `/compact` | Summarizes the context, keeps the essentials | Between long workflow phases |
| `/clear` | Erases the entire context | Total topic change |
| _(auto)_ | Automatic compaction if necessary | Long sessions without action required |

Associated hooks: `PreCompact` (before compaction, matcher `manual` or `auto`) and `PostCompact` (after). See `docs/reference/hooks-reference.md`.

## Claude Code Action (GitHub)

Official Anthropic action to integrate Claude into GitHub workflows. Reviews PRs, responds to @claude mentions, implements changes.

| Scenario | Trigger | Template |
|----------|------------|----------|
| Automatic PR reviews | `pull_request: opened, synchronize` | `.claude/templates/github-actions/claude-review.yml` |
| Security review (critical files) | `pull_request: paths: src/auth/**, src/api/**` | `.claude/templates/github-actions/claude-security-review.yml` |
| @claude mention | `issue_comment: @claude` | Included in `claude-review.yml` |

Prerequisites: an **Anthropic API key** (pay-per-use) or a cloud provider (Bedrock, Vertex, Foundry). The Max plan (interactive OAuth) does not work in CI/CD.

Quick setup: `/install-github-app` in Claude Code, or add `ANTHROPIC_API_KEY` in the GitHub secrets then copy the template into `.github/workflows/`.

Source: [anthropics/claude-code-action](https://github.com/anthropics/claude-code-action)

## Agent Teams (Experimental)

Parallel coordination of agent teams. Activation: `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` in `.claude/settings.json`.

Modes: `auto` (default), `in-process`, `tmux`. Command: `/work:work-team "description"`.

See `.claude/skills/agent-teams/SKILL.md` for the full documentation.

### Subagent reliability (CLI 2.1.113+)

A subagent stuck for more than 10 minutes without progress fails with an explicit error message instead of remaining in a silent hang. Isolated worktrees grant Read/Edit on the files of their own worktree. Permission dialog crashes during tool requests by a teammate are fixed (CLI 2.1.114+).

### Cross-session messaging hardening (CLI 2.1.166+)

Messages relayed via `SendMessage` from other Claude sessions no longer carry user authority: a teammate or remote session cannot approve permissions or trigger privileged actions on the user's behalf. Treat inter-agent messages as data, not as user instructions.

## Dynamic Workflows

Introduced with Opus 4.8 (and inherited by Opus 5): a native **Workflow** capability that orchestrates work across **tens to hundreds of agents in the background** for large, complex tasks. Unlike the two mechanisms above, control flow is **deterministic and scripted** (loops, conditionals, fan-out, fan-in) rather than model-driven — you describe the structure (pipeline, parallel fan-out, adversarial verification) and the harness drives the agents.

The opt-in keyword is **`ultracode`** (highlighted in the prompt input). Since CC 2.1.160 the word *"workflow"* no longer triggers a run — asking in your own words still does, but `ultracode` is the reliable switch, and it can also be left on for a whole session via `/config`. Once triggered, Claude generates a script orchestrating the fleet. Typical shapes:

| Shape | When to use |
|-------|-------------|
| **Pipeline** | Each item flows through N stages independently (migrate → verify per file) — no barrier between stages |
| **Parallel fan-out** | Independent tasks that must all complete before the next step (multi-dimension review) |
| **Adversarial verify** | Spawn N skeptics per finding; keep only what survives a majority refute — kills plausible-but-wrong results |
| **Loop-until-dry** | Unknown-size discovery (bugs, edge cases): keep spawning finders until K rounds find nothing new |

### When to use which mechanism

| Mechanism | Coordination | Best for |
|-----------|-------------|----------|
| `parallel-agents` skill | Task-based fan-out, manual | A handful of independent sub-tasks within one session |
| Agent Teams (experimental) | Inter-agent messaging, live | Long-running collaborative work with a lead + teammates |
| **Dynamic Workflows** | Deterministic script, background | Scale (dozens–hundreds of agents): audits, migrations, exhaustive review |

> Explicit opt-in: dynamic workflows can spawn many agents and consume a large token budget — they run only when you request that scale, not by inference.

## MCP Configuration

`.mcp.json` ships **empty** (`{"mcpServers": {}}`) — no server is active by default. There is **no per-server `enabled` flag**: a server is active iff its block is present in `.mcp.json`. The curated catalogue ships alongside as `.mcp.json.example`. Servers you can copy from it:

| Server | Usage |
|--------|-------|
| `filesystem` | Advanced file access |
| `memory` | Persistent memory |
| `github` | GitHub integration |
| `postgres` | PostgreSQL connection |
| `puppeteer` | Browser automation |
| `slack` | Team communication |
| `sentry` | Error monitoring |
| `linear` | Project management |

To enable a server, copy its block from `.mcp.json.example` into `.mcp.json` (there is no `enabled` flag — presence = active). Provide the referenced environment variables in `.env`.

### MCP Channels

MCP servers can push messages into a session via `--channels`. Available through channel plugins (Telegram, Discord, iMessage) that install as MCP servers.

| Channel | Plugin | Usage |
|---------|--------|-------|
| Telegram | `telegram-channel` | Messages and commands from Telegram |
| Discord | `discord-channel` | Messages from a Discord server |
| iMessage | `imessage-channel` | Messages from iMessage (macOS) |
| Slack | `slack` (native MCP) | Slack notifications and messages |

Activation: `claude --channels` at startup. Channels have access to the filesystem, MCP and git of the local session.

Permission relay: channels declaring the `permission` capability can relay approval requests to your phone.

### MCP Elicitation (CLI 2.1.76+)

MCP servers can request structured input from the user during a task via interactive dialogs. Associated hooks: `Elicitation` (request) and `ElicitationResult` (response).

### Managed Agents — private MCP & sandbox (Enterprise)

As of May 2026, **Claude Managed Agents** can run in a **sandbox you control** and connect to your **private MCP servers** — both the execution environment and the services it reaches stay within your enterprise boundaries. Paired with **Compliance API** integrations (security/compliance tooling), this lets IT and security teams govern Claude across the platform. Enterprise-only; out of scope for the local foundation, listed here as a pointer. See the [Anthropic news feed](https://www.anthropic.com/news).

### MCP OAuth RFC 9728 (CLI 2.1.85+)

Automatic discovery of Protected Resource Metadata for OAuth MCP servers. Simplifies OAuth 2.1 authentication by exposing the authorization server URL via a standard endpoint. Servers can provide a `headersHelper` and use the `CLAUDE_CODE_MCP_SERVER_NAME` and `CLAUDE_CODE_MCP_SERVER_URL` environment variables.

### MCP Step-up Authorization (CLI 2.1.84+)

RFC support for step-up authorization: MCP servers can return a `403 insufficient_scope` to trigger a refresh token with an extended scope. Useful for sensitive operations that require reauthentication without breaking the session.

### MCP Result Size Override (CLI 2.1.84+)

MCP tools can declare `_meta["anthropic/maxResultSizeChars"]` (up to 500K) to override the result persistence limit. Useful for tools that return large payloads (exports, reports, diffs).

## Async Hooks (CLI 2.1.70+)

`"async": true` property to run a hook in the background without blocking the session. Recommended for logging and notification hooks. Security hooks (gitleaks, pre-commit tests) must remain synchronous.

| Hook | Mode | Reason |
|------|------|--------|
| SessionStart, PreToolUse, PostToolUse, Setup | **sync** | Critical actions (security, formatting) |
| SessionEnd, PreCompact, PostCompact, SubagentStop, Notification | **async** | Logging, no impact on the workflow |
| TeammateIdle, TaskCompleted, InstructionsLoaded | **async** | Observability, non-blocking |
| Elicitation, ElicitationResult | **async** | MCP logging |

## HTTP Hooks (CLI 2.1.70+)

`"http"` type to send a JSON POST to an external URL (webhook). Generic webhook configuration example:

```json
{
  "type": "http",
  "url": "https://your-webhook-url.example.com/hook",
  "headers": { "Authorization": "Bearer ${WEBHOOK_TOKEN}" },
  "timeout": 5000,
  "async": true
}
```

Recommendations: always `async: true` and `onFailure: "ignore"` to avoid blocking the session if the remote service is unavailable.

## Model-switch hooks (CLI 2.1.251+)

`PreModelSwitch` and `PostModelSwitch` fire around a model change and can block, confirm, or annotate it. Useful where a project wants the tier pinned: a `PreModelSwitch` hook can refuse an unplanned escalation to the above-Opus tier, which is the deterministic counterpart to the `Agent(model:fable*)` permission rule shown above. The foundation ships neither — both stay opt-in, cost-neutral hardening.

`SessionStart` resume hooks also now receive session staleness and the estimated re-cache cost.

## Skill usage and context costs (Plugins → Stats)

Reports which loaded skills go unused and what each costs in context, so a bloated skill set can be
pruned on measurement rather than on intuition. Introduced as `/skill-doctor` in CLI 2.1.260; **the
report now lives in the `Stats` tab of the Plugins panel** (observed on 2.1.263), and typing
`/skill-doctor` opens it there.

Read the columns before reading the verdict:

| Column | What it measures |
|--------|------------------|
| context | the skill's **one-line listing in the system prompt**, included **every turn**. A dash means the skill is not in the current listing and costs nothing; the full `SKILL.md` loads only when the skill runs |
| 7d tokens | tokens attributed to the skill over the **last 7 days** of sessions on this machine |
| invocations / last used | a **persistent history across sessions**, counted in days since last use — not a snapshot of the session you run it in |

Relevant to any project that installs a large skill set — this foundation ships 53 — and to the same
question for any always-loaded file: the cost is context, so measure what actually fires before
setting a size budget by argument.

One trap, and it is the whole reason this section names the columns. **The counters are
machine-wide, not scoped to the repository you run them from.** The instinct is the opposite: a
foundation repo authors skills and rarely invokes them, so its own reading looks like it must
understate the catalogue. It does not, because the reading was never about that repo. Measured here:
the tab credits `qa:qa-chrome` with 5 invocations, and all five were typed in a different project,
zero in this one. The same holds for every command checked.

What follows is that a "never invoked" row is fleet evidence, not local evidence, and that the number
describes **your** use of the catalogue rather than the catalogue's worth to anyone else. Both
matter before removing anything.

## Claude Code Security (Enterprise/Team)

Vulnerability scanning tool that reasons about code beyond traditional static analysis — data flows, interactions between components, and architectural patterns.

**Claude Security** entered **public beta on 2026-05-22** for Claude Enterprise customers: it scans code repositories for vulnerabilities and generates proposed fixes. It is the productized form of **Project Glasswing**, whose first quantified results (also 2026-05-22) reported 10,000+ high/critical-severity vulnerabilities found across widely used internet software via ~50 partner organizations.

Prerequisites: Enterprise or Team plan. Complement to `/qa:qa-security` (local, OWASP-based) for an in-depth audit. See [Anthropic announcement](https://www.anthropic.com/news/claude-code-security).

## CLAUDE.md @imports

`@path/to/file` syntax to import files. Relative and absolute paths supported, recursive imports (max 5 levels). View loaded imports with `/memory`.

## Plugins

Ecosystem of community extensions for Claude Code. A plugin can contain skills, agents, hooks and MCP servers.

| Action | Command |
|--------|----------|
| Load a local plugin (directory or `.zip`) | `claude --plugin-dir ./my-plugin` |
| Load a remote plugin | `claude --plugin-url https://example.com/my-plugin.zip` |
| Namespaced skills | `/my-plugin:skill-name` |
| Plugin executables | Files in `bin/` invocable as Bash commands |

Plugins can be distributed via an Anthropic-managed directory. Setting `disableSkillShellExecution` to disable shell execution in unverified plugins.

### Evaluating a plugin before adoption (CLI 2.1.128+)

Both `--plugin-dir <path>` (local directory or `.zip`) and `--plugin-url <url>` (remote `.zip`) are session-scoped: the plugin is loaded for the current `claude` invocation only and disappears at session end. They are repeatable, so multiple plugins can be combined for a single trial. This is the foundation's recommended way to validate a plugin against your workflow before requesting it for permanent inclusion in a preset's `marketplacePlugins` list — consistent with the validation-first policy described in [`docs/recipes/recommended-vendor-skills.md`](https://github.com/christopherlouet/claude-base/blob/main/docs/recipes/recommended-vendor-skills.md).

Recipe — try a plugin without committing to it:

1. **Get the plugin**. Either clone the repo (`git clone <repo>`) or download the release `.zip` to a temp dir.
2. **Validate the manifest**. Run `claude plugin validate <unzipped-path>`. The validator reads `<path>/.claude-plugin/plugin.json`; pass an unzipped directory, not a `.zip` (the validator reads the path argument as a JSON file). Confirm at minimum `name`, `version`, `description` are present; `author` is recommended.
3. **Load it transiently**. Either `claude --plugin-dir ./plugin/` or `claude --plugin-dir ./plugin.zip` or `claude --plugin-url <url>`. The plugin is active for this session only.
4. **Use the plugin in your real workflow**. Invoke its skills (`/<plugin-name>:<skill>`), trigger its hooks, exercise the surface you care about. Take notes.
5. **Cleanup is automatic**. Exit the session — no installed state remains. Repeat with `--plugin-dir`/`--plugin-url` if you want to compare with another plugin or against the un-augmented baseline.

If after this trial the plugin is worth adopting, raise an issue or pull request against the relevant preset under [`.claude/presets/`](https://github.com/christopherlouet/claude-base/tree/main/.claude/presets) with the validation evidence (the marketplace-audit methodology under [`specs/marketplace-audit/`](https://github.com/christopherlouet/claude-base/tree/main/specs/marketplace-audit) describes the bar).

## Scheduled Tasks (Cloud)

Recurring jobs executed on Anthropic's cloud infrastructure. Useful for ongoing operational tasks without an active local session.

| Use case | Description |
|-------------|-------------|
| PR reviews | Automatic review of pull requests |
| CI monitoring | Continuous monitoring of the CI pipeline |
| Dependency audits | Periodic audit of dependencies |
| Doc syncing | Documentation synchronization |

Configuration via `/tasks`, `/schedule` or the API. Requires a Pro/Max/Team/Enterprise plan.

See also **Routines** (section above) for more complex automated workflows combining prompts, repos and connectors.

## Computer Use

Direct integration in Claude Code (Pro/Max). Allows opening files, launching dev tools, clicking and navigating in the interface without additional setup.

Useful for: visual tests, UI interactions, workflows requiring a browser or emulator.

## Routines (CLI 2.1.108+)

Routines are automated workflows that run on Anthropic's cloud infrastructure. A routine combines a prompt, one or more repos, and connectors into a single configuration executable on schedule, via API, or on a GitHub event.

| Property | Description |
|-----------|-------------|
| Prompt | The instructions to execute |
| Repos | One or more target repositories |
| Connectors | MCP servers, GitHub events, API triggers |
| Execution | Anthropic cloud — runs even with laptop turned off |

Use cases with the foundation:

| Routine | Description | Foundation equivalent |
|---------|-------------|------------------|
| Automatic PR reviews | Review every new PR | `/qa:qa-review` in cloud version |
| Periodic audit | Weekly security/quality audit | `/qa:qa-audit` in scheduled version |
| Automatic standup | Daily activity summary | `/ops:ops-standup` in cloud version |
| Dependency check | Audit deps every Monday | `/ops:ops-deps` in scheduled version |

Configuration via the Anthropic console or `/schedule`. Requires a Pro/Max/Team/Enterprise plan.

## Self-hosted environments (public beta, CLI 2.1.224+)

The cloud features above run on Anthropic's infrastructure. `claude self-hosted-runner` turns your own machines or containers into that compute layer instead: sessions started from web, mobile, desktop or a routine execute **inside your network**, next to internal services, toolchains and security controls.

| Mode | Behaviour |
|------|-----------|
| Fixed | A set number of runners stays up; sessions are distributed across them |
| On-demand | A runner spins up when work is queued and shuts down when finished |

Public beta since 2026-08-06, on Claude Team and Enterprise plans. Relevant to this foundation when a project cannot send its repo to hosted compute: the hooks, skills and guards all run unchanged on a self-hosted runner, since it is the same CLI on different hardware.

## Cloud review: /code-review ultra (CLI 2.1.111+)

A cloud command that delegates a review to parallel agents on Anthropic's infrastructure.

| Command | Description | When to use |
|----------|-------------|----------------|
| `/code-review ultra` | Parallel multi-agent review in cloud | Large PRs, in-depth reviews |

`/code-review ultra` launches several agents in parallel for a more exhaustive review than local `/qa:qa-review`. Ideal for PRs of more than 500 lines. With no argument it bundles the current local branch and needs no GitHub remote; `/code-review ultra <PR#>` targets a GitHub PR. `/ultrareview` still works as a **deprecated alias** for the same command.

> **`/ultraplan` was removed in CLI 2.1.222** (2026-08). The cloud-planning half of this pair no longer exists; there is no drop-in replacement. For large features, plan locally with `/work:work-plan` (or the `Plan` agent) — the foundation's Explore → Specify → Plan chain never depended on the cloud editor.

### Local /code-review --fix (CLI 2.1.152+)

The local `/code-review` flow gained `--fix`: review findings are **applied automatically to the working tree** instead of only being reported. Combine with the foundation's `qa-loop` (audit + iterative fix to score 90) for a tight local loop, or `--comment` to post findings as inline PR comments. The same release added native **skill management** (list/enable skills from within Claude Code) — complementary to the foundation's `writing-skills` / `base-maintenance` conventions.

> **Rate limits**: Anthropic **doubled Claude Code rate limits** (May 2026) for developers, startups and enterprises — fewer throttling interruptions on agentic/parallel workloads.

## TUI Fullscreen (Research Preview, CLI 2.1.89+)

Alternative rendering mode that takes control of the terminal surface like `vim` or `htop`. "Fullscreen" refers to taking over the drawing surface, **not** to maximizing the window.

Activation: `/tui fullscreen` (CLI 2.1.110+) or `CLAUDE_CODE_NO_FLICKER=1` before launch. Deactivation: `/tui default`.

### Three key benefits

| Benefit | Impact |
|----------|--------|
| Flicker-free | No more flickering in VS Code terminal, tmux, iTerm2 on long sessions |
| Constant memory | Only visible messages in the render tree → flat RAM even on conversations of several hours |
| Mouse support | Click-to-expand tool results, click URLs/file paths, click-and-drag selection with auto-copy |

Visual signal: in fullscreen, the prompt input stays **fixed at the bottom** instead of scrolling up with the output.

### Associated commands

| Mode | Command | Description |
|------|----------|-------------|
| Fullscreen | `/tui fullscreen` | Activates the mode (persists via the `tui` setting) |
| Default | `/tui default` | Deactivates the mode |
| Status | `/tui` | Displays the active renderer |
| Focus | `/focus` | Condensed view: prompt + 1 line per tool + final response (separable from `/tui`) |
| Transcript | `Ctrl+O` | Toggle transcript mode with `less`-style navigation |

### Navigation in fullscreen

| Shortcut | Action |
|-----------|--------|
| `PgUp` / `PgDn` | Half-screen scroll (or `Fn+↑`/`Fn+↓` on Mac) |
| `Ctrl+Home` / `Ctrl+End` | Start / end of conversation |
| `Ctrl+O` then `/` | Search in the transcript |
| `Ctrl+O` then `[` | Dump the conversation into the terminal's native scrollback |
| `Ctrl+O` then `v` | Open the transcript in `$EDITOR` |

### Environment variables

| Variable | Usage |
|----------|-------|
| `CLAUDE_CODE_NO_FLICKER=1` | Activates fullscreen at startup (equivalent to the `tui` setting) |
| `CLAUDE_CODE_DISABLE_MOUSE=1` | Keeps flicker-free + flat memory, but disables mouse capture (useful in SSH/tmux) |
| `CLAUDE_CODE_SCROLL_SPEED` | Scroll wheel speed multiplier (1-20, terminal-dependent default) |

### tmux compatibility

- Requires `set -g mouse on` in `~/.tmux.conf` for the scroll wheel
- **Incompatible with `tmux -CC`** (iTerm2 integration mode)

## Push Notifications (CLI 2.1.110+)

Claude can send push notifications to mobile when Remote Control is enabled. Useful for long background tasks.

Activation: enable Remote Control + "Push when Claude decides" in `/config`. Claude notifies at task end or when a human decision is necessary.

## `/loop` Command

Run a prompt or command at regular intervals:

```bash
/loop 5m "run tests and report failures"   # every 5 minutes
/loop "check CI status"                     # auto-paced by Claude (CLI 2.1.101+)
```

Alias: `/proactive` (CLI 2.1.105+). Without an interval, Claude auto-determines the optimal frequency.

Wakeup control: `Esc` cancels pending wakeups (CLI 2.1.113+), a "Claude resuming /loop wakeup" message confirms restart at each tick.

## Monitor Tool (CLI 2.1.98+)

Native tool that spawns a watcher in the background and streams its events into the conversation: each event arrives as a new transcript message that Claude reacts to immediately. Replaces `Bash sleep` loops that block an entire turn.

| Use case | Example prompt |
|-------------|-------------------|
| Application log tail | `Tail server.log and notify me as soon as a 5xx appears` |
| Babysit CI on a PR | `Watch the CI of this PR and auto-fix the lints` |
| Watch a dev server | `Watch npm run dev and restart on crash` |
| Track a training run | `Monitor the training log and alert on loss spike` |

Recommended pairing with `/loop` (auto-pace): Claude chooses Monitor over polling when the source emits events directly.

Foundation integration: Monitor is useful in `/qa:qa-loop`, `/ops:ops-ci-fix`, and long-running `/loop` workflows where a bash sleep loop would be the alternative.

## `/autofix-pr` (CLI 2.1.92+)

Enables **PR auto-fix on Claude Code Web** from the terminal for the PR of the current branch. After push, Claude monitors the CI and review comments and pushes fixes until green without requiring an active local session.

```bash
git push -u origin feature/auth
/autofix-pr
```

| When to use | Description |
|----------------|-------------|
| Long CI cycle | Lints, tests, type-check looping on small fixes |
| PR with many review nits | Renames, formats, docstrings requested in review |
| Asynchronous work | You want to leave the terminal and let Claude finish |

Complement to `/work:work-pr`: `/work:work-pr` creates the PR, `/autofix-pr` makes it converge autonomously. Requires Claude Code on the web (Pro/Max/Team/Enterprise).

## `/powerup` Command

Interactive lessons and animated demos to discover Claude Code's features. Useful for onboarding new users.

## `/fewer-permission-prompts`

Scans session transcripts and proposes optimized permission allowlists. Reduces the number of permission prompts without compromising security.

Useful for: onboarding (generating initial permissions), sessions with too many prompts, team configuration optimization.

Since CLI 2.1.166, deny rules accept glob patterns in the tool-name position (e.g., `"*"` denies all tools, `mcp__github__*` denies every GitHub MCP tool) — useful to deny whole tool families instead of listing each tool.

## Advanced Prompt Caching (CLI 2.1.108+)

| Variable | TTL | Description |
|----------|-----|-------------|
| `ENABLE_PROMPT_CACHING_1H` | 1 hour | Extended prompt cache for long sessions (API key, Bedrock, Vertex, Foundry) |
| `FORCE_PROMPT_CACHING_5M` | 5 minutes | Forces 5 min TTL (useful if telemetry is disabled) |

Enable in `.claude/settings.local.json` (not committed):

```json
{
  "env": {
    "ENABLE_PROMPT_CACHING_1H": "1"
  }
}
```

## Advanced Environment Variables

| Variable | Description |
|----------|-------------|
| `CLAUDE_CODE_NO_FLICKER=1` | Alt-screen rendering without flicker (virtualized scrollback) |
| `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1` | Strips credentials from subprocess env variables |
| `MCP_CONNECTION_NONBLOCKING=true` | Skip waiting for MCP connection in `-p` mode (headless/CI) |
| `ENABLE_PROMPT_CACHING_1H=1` | 1-hour prompt cache (significant savings) |
| `FORCE_PROMPT_CACHING_5M=1` | Force 5-minute prompt cache |
| `CLAUDE_CODE_USE_POWERSHELL_TOOL` | Opt-in/out of the PowerShell tool on Windows (CLI 2.1.111+) |
| `CLAUDE_CODE_ENABLE_AWAY_SUMMARY=1` | Forces the session recap even if telemetry is disabled (CLI 2.1.108+) |
| `CLAUDE_CODE_PERFORCE_MODE=1` | Edit/Write fail on read-only files with `p4 edit` hint (CLI 2.1.98+) |
| `CLAUDE_STREAM_IDLE_TIMEOUT_MS` | Configures the streaming inactivity watchdog (CLI 2.1.84+) |
| `OTEL_LOG_RAW_API_BODIES=1` | Emits full API request/response bodies via OpenTelemetry (CLI 2.1.113+) |
| `MAX_THINKING_TOKENS=0` | Disables thinking, including on models that think by default — same effect as `--thinking disabled` or the per-model toggle (CLI 2.1.166+) |
| `CLAUDE_CODE_SUBAGENT_MODEL` | Sets the **default** sub-agent model. Since CLI 2.1.248 it no longer overrides everything: an agent definition's `model:` and an explicit per-spawn model win over it — which is why this foundation's 44 pinned agents keep their tier when it is set |
| `CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1` | Applies `CLAUDE_CODE_SUBAGENT_MODEL` (or the main model) to **every** sub-agent, ignoring per-spawn and agent-definition overrides (CLI 2.1.248+). The escape hatch for a whole-fleet cost experiment |

## Advanced Settings

| Setting | Description |
|---------|-------------|
| `fallbackModel` | Up to three fallback models tried in order when the primary is overloaded or unavailable; unexpected API errors retry on the fallback automatically (CLI 2.1.166+) |
| `disableSkillShellExecution` | Disables inline shell execution in skills, commands and plugins |
| `managed-settings.d/` | Drop-in directory for policy fragments (Team/Enterprise) |
| `sandbox.network.deniedDomains` | Blocks specific domains even under a wildcard `allowedDomains` (CLI 2.1.113+) |
| `sandbox.failIfUnavailable` | Exit with error if sandbox enabled but unavailable (CLI 2.1.83+) |
| `modelOverrides` | Maps picker entries to custom model IDs (Bedrock Application Inference Profile ARNs, etc.) (CLI 2.1.84+) |
| `worktree.sparsePaths` | Sparse-checkout for large monorepos with `claude --worktree` (CLI 2.1.76+) |
| `autoScrollEnabled` | Disables auto-scroll in fullscreen mode (CLI 2.1.110+) |
| `showThinkingSummaries` | Generates extended thinking summaries (default now `false` — CLI 2.1.108+) |
| `disableDeepLinkRegistration` | Prevents registration of the `claude-cli://` protocol handler (CLI 2.1.83+) |
| `feedbackSurveyRate` | Admin sample rate of the session quality survey (CLI 2.1.76+) |
| `forceRemoteSettingsRefresh` | Blocks startup until remote managed settings are refreshed (policy) |
| Theme `"Auto (match terminal)"` | Automatically follows the terminal's dark/light mode (CLI 2.1.111+) |
| `attribution.sessionUrl` | Set `false` to omit the claude.ai session link from commits and PRs (web / Remote Control sessions) — the native toggle for the "no AI attribution in commits/PRs" convention (CLI 2.1.183, June 2026) |
| `sandbox.credentials` | Blocks sandboxed commands from reading credential files and secret env vars — defense-in-depth for the secrets-management posture (CLI 2.1.187, June 2026) |
| `respondToBashCommands` | Set `false` so `! <cmd>` shell-mode output is not auto-explained by the model (saves a prompt per `!` call) (CLI 2.1.186, June 2026) |

### Permission parameter matching — `Tool(param:value)` (CLI 2.1.178, June 2026)

`permissions.deny` / `permissions.ask` rules can now match a tool's **input parameters**, not just its name, with a `*` wildcard. This gives the foundation's security posture a finer lever than an all-or-nothing tool block:

```json
// .claude/settings.json
{
  "permissions": {
    "ask": [
      "Agent(model:opus)",        // confirm before spawning a costly Opus sub-agent
      "Agent(isolation:remote)"   // confirm before a remote/cloud agent run
    ],
    "deny": [
      "Agent(model:fable*)"        // block the costlier above-Opus Fable tier outright
    ]
  }
}
```

Use it to cap sub-agent cost (gate `model:opus`/`model:fable*`), to require confirmation before `isolation:worktree`/`remote` agents, or to scope any tool by a sensitive parameter. The foundation ships none of these by default (it stays cost-neutral) — they are opt-in hardening a project can add.

## LSP (Language Server Protocol)

Semantic code navigation via `.lsp.json`. Activation: `export ENABLE_LSP_TOOL=1`.

12 supported languages (TypeScript, Python, Go, Rust, Java, C/C++, C#, PHP, Kotlin, Ruby, HTML, CSS).

LSP for: symbol definitions, references, diagnostics. Grep for: textual searches.
See `.claude/rules/lsp.md` for detailed rules.

## Marketplace Curation Engine

A deterministic, **billing-safe** system that keeps the recommended vendor-skill list
current — observe-and-propose only, never auto-install. Two scheduled jobs:

- **Nightly rot-watch** (`scripts/curation-watch.sh`) — **LLM-free → $0 tokens**. Re-verifies
  every recommended/pointed skill (archived / abandoned / sustained popularity-collapse /
  license-change / **content-drift vs the pinned ref**) and emits ONE digest. Opt-in,
  fail-safe GitHub emission: `--emit-issue` (propose-only) and `--emit-pr --draft` (low-risk
  re-pin, gated by a pin-time safety screen).
- **Monthly discovery** (`scripts/curation-discover.sh`) — model-using under a **hard token
  budget + fail-safe** (the 2026-06-15 agentic-billing change). Trust + safety gates run
  first (LLM-free); only survivors reach the advice-neutrality + fit judge. Flags
  *moat-encroachment* as a strategic signal, never an auto-candidate.

Deploy both as cron/systemd timers — the monthly job uses a **dedicated, capped API key**
in its own env, never mixed with the $0 nightly path. See
[`docs/recipes/curation-bot-deploy.md`](https://github.com/christopherlouet/claude-base/blob/main/docs/recipes/curation-bot-deploy.md). Policy:
advice-neutrality + provenance (not publisher-veto); foundation-vs-vendor precedence in
[`.claude/rules/vendor-precedence.md`](https://github.com/christopherlouet/claude-base/blob/main/.claude/rules/vendor-precedence.md).
