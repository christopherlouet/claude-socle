# FAQ - Frequently Asked Questions

Answers to the most common questions about claude-base and Claude Code agents.

---

## General

### What is claude-base?

claude-base is a configuration template for Claude Code that provides a set of agents (slash commands) ready to use to optimize your development workflow.

---

### What's the difference between Claude Code and agents?

- **Claude Code**: Anthropic's official CLI tool for interacting with Claude
- **Agents**: Pre-configured prompts (`.md` files) that specialize Claude for specific tasks

---

### How do I install claude-base?

```bash
# 1. Install Claude Code
npm install -g @anthropic-ai/claude-code

# 2. Copy the .claude folder into your project
cp -r path/to/claude-base/.claude your-project/

# 3. Ready to go!
cd your-project
claude
/explore
```

---

### Do the agents work with other LLMs?

No, claude-base agents are designed specifically for Claude Code and the Anthropic API. However, the templates and structures can be adapted for other systems.

---

## Agents

### How do I create my own agent?

1. Create a `.md` file in `.claude/commands/`
2. Follow the standard structure:

```markdown
# Agent MY-AGENT

Short description of the agent.

## Context
$ARGUMENTS

## Goal
[Goal of the agent]

## Instructions
[Detailed instructions]

## Expected output
[Output format]

---

IMPORTANT: [Critical instructions]
```

---

### How should I name my agents?

| Convention | Example | Usage |
|------------|---------|-------|
| `dev-*` | `dev-tdd.md` | Development |
| `qa-*` | `qa-review.md` | Quality |
| `ops-*` | `ops-ci.md` | Operations |
| `doc-*` | `doc-api.md` | Documentation |
| `biz-*` | `biz-mvp.md` | Business |
| `work-*` | `work-commit.md` | Workflow |

---

### Can I modify existing agents?

Yes! Agents are simple Markdown files. You can:
- Modify them to fit your needs
- Duplicate them to create variants
- Extend them with your own instructions

---

### How do I pass arguments to an agent?

```bash
# Syntax
/agent-name argument1 argument2

# Examples
/explore src/services/
/review AuthService
/commit "feat: add login"
```

Arguments are injected via the `$ARGUMENTS` placeholder in the agent.

---

### Why is my agent ignoring some instructions?

A few possible reasons:

1. **Contradictory instructions**: Check that there are no conflicts
2. **Too many instructions**: Prioritize the most important ones
3. **Format**: Use `IMPORTANT:`, `YOU MUST`, `NEVER` for critical rules

---

## Workflow

### What is the recommended workflow?

```
1. /explore  → Understand the existing code
2. /plan     → Plan the changes
3. /tdd      → Develop with tests
4. /review   → Verify quality
5. /commit   → Commit the changes
6. /pr       → Create the Pull Request
```

---

### Do I always have to follow this workflow?

No, it's a recommendation. Adapt it to your needs:

| Task | Suggested workflow |
|------|--------------------|
| Simple bug fix | `explore → fix → commit` |
| New feature | `explore → plan → tdd → review → commit → pr` |
| Refactoring | `explore → plan → refactor → review → commit` |
| Documentation | `doc → commit` |

---

### When should I use `/explore` vs `/onboard`?

| Agent | Usage |
|-------|-------|
| `/explore` | Targeted exploration of part of the code |
| `/onboard` | Full discovery of a new codebase |

---

## Performance and costs

### How do I reduce token consumption?

1. **Use targeted agents** rather than generic ones
2. **Specify the files** to analyze
3. **Avoid vague requests** like "analyze the whole project"
4. **Use `explore`** to first identify relevant files

---

### What is the maximum context size?

Claude has a 200k token context window by default (1M by default with Opus 5, Opus 4.8, Sonnet 5 and Fable 5.1 on the API, Bedrock and Vertex AI). For large projects:
- Use targeted agents
- Analyze by module/folder
- Exclude irrelevant files
- On Opus-class models, Context Compaction automatically summarizes old context

---

### What is Adaptive Thinking?

Introduced with Opus 4.8 and carried by Opus 5, Adaptive Thinking replaces the "extended thinking" toggle with effort levels (`low`, `medium`, `high`, `xhigh`, `max`). The model automatically adjusts its reasoning based on the complexity of the task. This optimizes the cost/quality ratio without manual configuration. On **Fable 5.1** — Anthropic's most capable tier — thinking is always on and cannot be disabled; effort still controls its depth.

---

### Do agents increase costs?

Agents are pre-configured prompts. They don't add cost on their own, but more detailed instructions may slightly increase token consumption per request.

---

## Customization

### How do I add my code conventions?

Edit the `CLAUDE.md` file at the root of your project:

```markdown
## Code Conventions

### Naming
- Variables: camelCase
- Constants: SCREAMING_SNAKE
- Files: kebab-case

### Specific rules
- [Your rules here]
```

---

### How do I share my agents with my team?

Agents live in the `.claude/commands/` folder. Options:

1. **Commit in the repo**: Agents will be shared along with the code
2. **Separate repo**: Create a dedicated repo for team agents
3. **Submodule**: Use a git submodule for shared agents

---

### Can I have private and shared agents?

Yes, use two sources:

```
project/
├── .claude/
│   └── commands/           # Project agents (shared)
│       └── ...
└── ~/.claude/
    └── commands/           # Personal agents (private)
        └── ...
```

---

## Troubleshooting

### Where can I find help?

1. **TROUBLESHOOTING.md**: Problem-solving guide
2. **Claude Code documentation**: https://code.claude.com/docs/en/overview
3. **GitHub Issues**: https://github.com/anthropics/claude-code/issues

---

### How do I report a bug?

Before reporting:
1. Check TROUBLESHOOTING.md
2. Search existing issues
3. Prepare: version, OS, reproduction steps, logs

---

### Agent X doesn't behave as expected

1. Re-read the agent's instructions
2. Check that you're passing the right arguments
3. Try with a simple example
4. Check TROUBLESHOOTING.md

---

## Updates

### How do I update the agents?

```bash
# If you use a git repo
git pull origin main

# If manual copy
# Download the new version and replace .claude/commands/
```

---

### Do updates overwrite my modifications?

If you've modified the agents:
1. **Back up** your changes before updating
2. **Use separate files** for your customized agents
3. **Version** with git to track changes

---

## Technical questions

### Can agents call other agents?

Agents can **reference** other agents in their instructions, but cannot call them automatically. The user must invoke each agent manually.

---

### What syntax is supported in agents?

- **Standard Markdown**: Titles, lists, tables, code blocks
- **Placeholders**: `$ARGUMENTS` for arguments
- **Special instructions**: `IMPORTANT:`, `YOU MUST`, `NEVER`, `Think hard`

---

### Can I use environment variables?

Agents don't have direct access to environment variables. Pass values via `$ARGUMENTS`:

```bash
/deploy production $MY_API_KEY
```

---

## Contribution

### How do I contribute to claude-base?

1. Fork the repo
2. Create a branch for your changes
3. Follow the existing conventions
4. Test your agents
5. Create a Pull Request

See CONTRIBUTING.md for more details.

---

### Can I propose new agents?

Absolutely! Contributions are welcome:
- New agents for missing use cases
- Improvements to existing agents
- Bug fixes
- Documentation improvements
