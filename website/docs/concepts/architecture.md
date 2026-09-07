---
sidebar_position: 20
title: "Claude Code Foundation Architecture"
description: " Understand the difference between Commands, Agents, Skills and Rules"
tags:
  - "concept"
---

<!-- Auto-generated from docs/ - DO NOT EDIT -->

# Claude Code Foundation Architecture

> Understand the difference between Commands, Agents, Skills and Rules

## Why do some files exist in commands/ AND agents/?

The duplication is **intentional** and serves different purposes:

- **commands/xxx.md** = Interactive prompt invoked manually (`/xxx`)
- **agents/xxx.md** = Delegable version with YAML frontmatter (model, tools, skills)

Claude Code uses:
1. The **command** when the user explicitly types `/xxx`
2. The **agent** when Claude automatically delegates a sub-task

### Key differences

| Aspect | Command | Agent |
|--------|---------|-------|
| Trigger | Manual (`/xxx`) | Automatic (delegation) |
| Frontmatter | No | Yes (model, tools, skills) |
| Context | Shared | **Isolated** |
| Variable | `$ARGUMENTS` | No |
| Model | Default | Configurable (haiku/sonnet) |
| Tools | All | Restricted (configurable) |

### Concrete example

```bash
# The user explicitly types the command
/qa:qa-security

# → Claude loads commands/qa/qa-security.md (prompt)
# → Claude delegates to agents/qa-security.md (isolated context, model: opus)
# → The agent uses the qa-security skill
# → Result returned to the main context
```

This architecture enables:
- **Flexibility**: The user controls via commands
- **Optimization**: Claude delegates with the right model
- **Isolation**: Agents do not pollute the context
- **Security**: Restricted tools for audits

---

## Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                            USER                                  │
│                             │                                    │
│    ┌───────────────────────┼───────────────────────┐            │
│    │                       ▼                       │            │
│    │  ┌─────────────────────────────────────────┐  │            │
│    │  │              TRIGGER                     │  │            │
│    │  │                                          │  │            │
│    │  │  Manual (/cmd)    Automatic (context)    │  │            │
│    │  │       │                  │               │  │            │
│    │  │       ▼                  ▼               │  │            │
│    │  │  ┌─────────┐      ┌───────────┐         │  │            │
│    │  │  │COMMANDS │      │  SKILLS   │         │  │            │
│    │  │  └────┬────┘      └─────┬─────┘         │  │            │
│    │  │       │                 │               │  │            │
│    │  │       └────────┬────────┘               │  │            │
│    │  │                │                        │  │            │
│    │  │                ▼                        │  │            │
│    │  │         ┌───────────┐                   │  │            │
│    │  │         │  AGENTS   │ (delegation)      │  │            │
│    │  │         └─────┬─────┘                   │  │            │
│    │  │               │                         │  │            │
│    │  │               ▼                         │  │            │
│    │  │         ┌───────────┐                   │  │            │
│    │  │         │  RULES    │ (constraints)     │  │            │
│    │  │         └───────────┘                   │  │            │
│    │  └─────────────────────────────────────────┘  │            │
│    │                                               │            │
│    └───────────────────────────────────────────────┘            │
└─────────────────────────────────────────────────────────────────┘
```

## Detailed Comparison

| Aspect | Commands | Skills | Agents | Rules |
|--------|----------|--------|--------|-------|
| **Folder** | `.claude/commands/` | `.claude/skills/` | `.claude/agents/` | `.claude/rules/` |
| **Trigger** | Manual (`/cmd`) | Automatic | Auto delegation | Path-based |
| **Context** | Shared | Fork or shared | **Isolated** | Injected |
| **Tools** | All | Configurable | Restricted | N/A |
| **Model** | Default | Default | Configurable | N/A |
| **Use case** | Explicit actions | Detected patterns | Isolated tasks | Constraints |

## Commands (<!-- count:commands -->106<!-- /count --> available)

### Definition
Prompts invoked manually with the `/command-name` syntax.

### Characteristics
- Explicit trigger by the user
- Context shared with the conversation
- Access to all tools
- Structure: markdown prompts

### File structure
```
.claude/commands/
├── work/
│   ├── work-explore.md
│   ├── work-plan.md
│   └── work-commit.md
├── dev/
│   ├── dev-tdd.md
│   └── dev-api.md
└── ...
```

### Format
```markdown
# Command title

## Instructions
Instructions for Claude...

## Variables
$ARGUMENTS - Arguments passed by the user
```

### Usage example
```bash
/work:work-explore "understand the authentication system"
/dev:dev-api "CRUD endpoint for users"
/qa:qa-security
```

### When to use
- Explicit workflow
- Specific actions
- Complex tasks requiring a detailed prompt

## Skills (<!-- count:skills -->53<!-- /count --> available)

### Definition
Patterns automatically triggered by Claude based on the conversation context.

### Characteristics
- Automatic trigger (keywords, context)
- Forked context recommended
- Configurable tools (whitelist)
- Structure: YAML frontmatter + instructions

### File structure
```
.claude/skills/
└── skill-name/
    └── SKILL.md
```

### Format
```yaml
---
name: skill-name
description: When to trigger this skill
allowed-tools:
  - Read
  - Write
  - Edit
context: fork
---

# Instructions

Instructions for the skill...
```

### Skill example
```yaml
---
name: dev-tdd
description: TDD development with Red-Green-Refactor cycle
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
  - Glob
  - Grep
context: fork
---

# TDD Skill

When the user mentions "TDD", "test first", or "write tests first"...
```

### When to use
- Recurring patterns
- Desired contextual triggering
- Standardization of behaviors

## Agents (<!-- count:agents -->44<!-- /count --> available)

### Definition
Specialized sub-agents with isolated context, automatic delegation.

### Characteristics
- **Completely isolated context** (does not pollute the conversation)
- Restricted tools (security)
- Configurable model (haiku/sonnet/opus)
- Pre/post tool hooks
- Injectable skills

### File structure
```
.claude/agents/
├── work-explore.md
├── qa-security.md
├── dev-debug.md
└── ...
```

### Format
```yaml
---
name: agent-name
description: Description of the agent
model: haiku | sonnet | opus
permissionMode: plan | default
disallowedTools:
  - Edit
  - Write
hooks:
  PreToolUse:
    - command: scripts/hooks/command-validator.sh
skills:
  - qa-security
---

# Instructions

Instructions for the agent...
```

### Available models

| Model | Usage | Cost | Speed | Context | Max output |
|--------|-------|------|---------|----------|------------|
| haiku | Simple tasks, reading | $ | Fast | 200k | 8k |
| sonnet | Complex tasks, analysis | $$ | Medium | 200k | 64k |
| opus (Opus 5) | Critical tasks, adaptive thinking | $$$ | Slower | 1M | 128k |

### Agent example
```yaml
---
name: qa-security
description: OWASP Top 10 security audit
model: opus
permissionMode: plan
disallowedTools:
  - Edit
  - Write
  - NotebookEdit
skills:
  - qa-security
---

# QA Security Agent

Performs a complete security audit based on OWASP Top 10...
```

### When to use
- Tasks requiring isolation
- Audits (read-only)
- Parallelization
- Token savings (haiku)

## Rules (32 available)

### Definition
Constraints and conventions automatically injected based on file paths.

### Characteristics
- Automatic injection by path
- No user trigger
- Global or specific constraints
- Affects Commands, Skills, Agents

### File structure (<!-- count:rules -->32<!-- /count --> rules)

Cross-cutting rules (18):
```
.claude/rules/
├── workflow.md            # Global — Explore → (Brainstorm) → Specify → Plan → TDD → Audit → Commit
├── git.md                 # Global — Conventional Commits, branches
├── self-improvement.md    # Global — personal cross-project lessons referential
├── vendor-precedence.md   # Global — foundation-vs-vendor advice precedence
├── tdd-enforcement.md     # TS/Py/Go/Dart code — TDD mandatory
├── verification.md        # TS/Py/Go/Dart code — 4-phase verification
├── security.md            # auth/, api/, middleware/
├── accessibility.md       # tsx/jsx — WCAG 2.1 AA
├── performance.md         # tsx/ts/pages — Core Web Vitals
├── testing.md             # *.test, *.spec, tests/
├── api.md                 # api/, routes/, controllers/
├── design-style.md        # tsx/jsx, components/, app/
├── deploy-safety.md       # Dockerfile, docker-compose, .env
├── migration-safety.md    # package.json, tsconfig, next.config
├── service-worker.md      # sw.js, service-worker*
├── lsp.md                 # Multi-language — LSP vs Grep
├── research.md            # Multi-language — minimal-code ladder (YAGNI), native before custom
└── base-maintenance.md   # .claude/** — sync catalog counters
```

Rules per language/framework (14):
```
├── typescript.md  # **/*.ts, **/*.tsx, **/*.mts
├── python.md      # **/*.py, **/pyproject.toml
├── go.md          # **/*.go, **/go.mod
├── rust.md        # **/*.rs, **/Cargo.toml
├── java.md        # **/*.java, **/pom.xml
├── csharp.md      # **/*.cs
├── ruby.md        # **/*.rb, **/Gemfile
├── php.md         # **/*.php
├── react.md       # **/*.tsx, **/components/**
├── nextjs.md      # **/next.config.*, **/app/**
├── vue.md         # **/*.vue, **/composables/**
├── svelte.md      # **/*.svelte, **/svelte.config.*
├── astro.md       # **/*.astro, **/content/**
└── flutter.md     # **/*.dart, **/lib/**
```

### Format
```yaml
---
paths:
  - "**/*.ts"
  - "**/*.tsx"
---

# TypeScript Rules

## Strict mode
- Always `strict: true`
- No `any` unless justified
...
```

### When to use
- Code conventions
- Security rules
- Quality standards
- Per-technology constraints

## Decision Matrix

### By task type

| Task | Best choice | Reason |
|-------|----------------|--------|
| Explicit workflow | **Command** | User control |
| Recurring pattern | **Skill** | Auto trigger |
| Read-only audit | **Agent** | Isolation, security |
| Code convention | **Rule** | Auto injection |
| Parallel task | **Agent** | Isolated context |
| Complex action | **Command** | Detailed prompt |

### By frequency of use

| Frequency | Best choice |
|-----------|----------------|
| 1x per project | Command |
| Several times/day | Skill |
| In parallel | Agent |
| Always (constraint) | Rule |

### By isolation need

| Need | Choice |
|--------|-------|
| Share context | Command or Skill |
| Isolate completely | Agent |
| Constrain globally | Rule |

## Concrete Examples

### Scenario 1: New feature

```
1. /work:work-explore        → Command (explicit)
2. TDD pattern detected → Skill (auto)
3. Security audit       → Agent (isolated)
4. /work:work-pr             → Command (explicit)

Applied rules: typescript.md, react.md, security.md
```

### Scenario 2: Urgent bug fix

```
1. /dev:dev-debug           → Command (explicit)
2. Investigation        → Agent dev-debug (isolated)
3. Fix applied          → Rules typescript.md
4. /work:work-commit         → Command (explicit)
```

### Scenario 3: Full audit

```
1. /qa:qa-audit            → Command (explicit)
   ├── qa-security      → Agent (parallel)
   ├── qa-perf          → Agent (parallel)
   └── wcag-audit          → Agent (parallel)

All read-only, isolated contexts
```

## Best Practices

### Commands
- Explicit names (`/work:work-explore` not `/we`)
- Group by domain (`work-`, `dev-`, `qa-`)
- Document expected arguments

### Skills
- `context: fork` recommended
- Limit `allowed-tools`
- Clear trigger keywords

### Agents
- `model: haiku` for simple tasks
- `disallowedTools` for security
- Inject relevant skills

### Rules
- Specific paths, not too broad
- Clear and actionable rules
- No conflicting rules

## Data Flow

```
┌────────────────────────────────────────────────────────────────┐
│                                                                │
│  User: "/qa:qa-security"                                          │
│       │                                                        │
│       ▼                                                        │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ COMMAND: /qa:qa-security                                    │   │
│  │ → Loads the qa-security.md prompt                        │   │
│  │ → Detects *.ts files → Injects rules/typescript.md      │   │
│  │ → Detects api/ folder → Injects rules/api.md            │   │
│  │ → Detects auth/ folder → Injects rules/security.md      │   │
│  └─────────────────────────────────────────────────────────┘   │
│       │                                                        │
│       ▼                                                        │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ DELEGATION → AGENT: qa-security                          │   │
│  │ → model: opus                                            │   │
│  │ → permissionMode: plan (read-only)                       │   │
│  │ → disallowedTools: [Edit, Write]                         │   │
│  │ → skills: [qa-security]                                  │   │
│  │ → ISOLATED context                                       │   │
│  └─────────────────────────────────────────────────────────┘   │
│       │                                                        │
│       ▼                                                        │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ SKILL: qa-security (injected into agent)                 │   │
│  │ → OWASP Top 10 checklist                                 │   │
│  │ → Vulnerability patterns                                 │   │
│  └─────────────────────────────────────────────────────────┘   │
│       │                                                        │
│       ▼                                                        │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ RESULT → Returns to the main context                     │   │
│  │ → Agent report                                           │   │
│  │ → Main context preserved                                 │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

## Curation Engine

A deterministic, billing-safe subsystem that keeps the recommended vendor-skill list
honest (the foundation's *curator* role). It never installs — it observes and proposes.

```
DATA      .claude/curation/registry.json        canonicalVendor records (pinned ref, two trust tracks)
          .claude/curation/trust-thresholds.json  popularity/recency bars (authority vs community)
          .claude/curation/discovery-sources.json  per-domain GitHub search queries
          .claude/presets/*.json                 recommendedVendorSkills[] (pinned, provenance)

SCORING   scripts/lib/trust-score.sh             public signals → verdict   [LLM-FREE]
          scripts/lib/curation-safety.sh         pin-time content safety screen (≠ trust)

WATCH     scripts/curation-watch.sh   NIGHTLY    rot + content-drift → ONE digest   [LLM-FREE, $0]
          scripts/curation-discover.sh MONTHLY   new candidates → trust+safety gate (LLM-free)
                                                 → advice-neutrality+fit judge      [LLM, budget-capped]

POLICY    .claude/rules/vendor-precedence.md     foundation-vs-vendor advice precedence
DEPLOY    docs/recipes/curation-bot-deploy.md    nightly ($0) + monthly (capped key) bot
```

- **Nightly path is LLM-free → $0 tokens** (immune to metered agentic billing); the
  monthly discovery is the only model-using part, under a hard budget + fail-safe.
- **Observe-never-install**: the most it does is open a *draft* PR (low-risk re-pin) or a
  *propose-only* issue. Recommendation **drift** is also surfaced on `claude-base update`.
- **One open re-pin PR locks the others** (no nightly near-duplicates). The digest names the
  blocking PR and escalates to a warning past `global.repinLockStaleDays`, so a lock left
  held can never look like a quiet night.

## Summary

| Concept | Trigger | Context | Main usage |
|---------|-------------|----------|-----------------|
| **Command** | `/name` | Shared | Explicit actions |
| **Skill** | Keywords | Fork | Auto patterns |
| **Agent** | Delegation | **Isolated** | Parallel tasks |
| **Rule** | File path | Injected | Constraints |
