# Recipe: deploying the nightly curation bot

**Audience**: the foundation maintainer who wants the marketplace curation engine to re-verify the recommended vendor skills automatically, on a schedule, and surface a single reviewable digest — without paying for model tokens.

This recipe wires `scripts/curation-watch.sh` (the rot-watch, Slice 3 of `specs/marketplace-curation-engine`) into a nightly timer on a small Linux box. It is **observe-and-propose only**: nothing is installed, nothing is merged automatically. The most the bot ever does is open a *draft* PR or a *propose-only* issue for you to approve.

---

## Why this is safe to run unattended

The nightly path is **deterministic and LLM-free** — it calls the GitHub API for public repo signals (stars, recency, archived, license) and compares content references against the pinned ones. It uses **zero model tokens**.

This matters because of the **2026-06-15 Anthropic agentic-billing change**: from that date `claude -p` / the Agent SDK / cron-driven model usage is metered on a separate credit at API rates, with no rollover, and automation stops on exhaustion. The rot-watch is immune to this — it never invokes a model (EF-012). The only part of the engine that touches an LLM is the **monthly discovery** sweep (Slice 5), which is a separate, infrequent job on a dedicated capped API key. **This recipe deploys the LLM-free nightly watch only.**

So the bot needs **no model API key** — just an authenticated `gh`.

---

## What the bot does each run

1. Refresh a clean checkout to `origin/main` (so the watch sees exactly what is shipped).
2. Run `curation-watch.sh`, which for every recommended / pointed vendor skill:
   - scores public trust signals (archived / abandoned / popularity-collapse / license-change),
   - detects **content drift** vs the pinned ref,
   - applies the **sustained-collapse** rule (a popularity drop is only flagged after ≥2 consecutive runs — a single noisy reading never alarms),
   - emits **one** batched digest (`digest.json` + `digest.md`).
3. Optionally surface findings via `gh`:
   - `--emit-issue` → one **propose-only** issue containing the digest (only when there are findings — an all-clean run stays silent).
   - `--emit-pr` → one **draft** PR re-pinning low-risk drift that re-passes **both** the trust scorer **and** the pin-time safety screen. A drift whose new content fails the safety screen is demoted to propose-only (it stays in the issue, never auto-drafted).

State (the `collapseStreak` / reference popularity needed for the sustained-collapse rule) is kept in a **`watch-state.json` outside the checkout** so it survives the nightly `git reset --hard` (see below).

---

## Prerequisites on the box

- `bash`, `jq`, `git`, and the GitHub CLI `gh`.
- A clone of the repo, e.g. at `/opt/claude-base`.
- An authenticated `gh`. Use a **fine-grained token** scoped to this one repo with the minimum permissions:
  - **Contents: read** — required (the watch reads the registry/presets and the GitHub API).
  - **Issues: read & write** — only if you use `--emit-issue`.
  - **Pull requests: read & write** + **Contents: read & write** — required for the **recommended** `--emit-pr` auto-heal (it pushes a branch and opens a draft PR). Omit these scopes only if you deliberately run observe-only.

Store the token as an environment variable for `gh` (never commit it):

```bash
# /etc/claude-base-bot.env   (chmod 600, owned by the bot user)
GH_TOKEN=github_pat_xxxxxxxxxxxxxxxxxxxxx
```

`gh` reads `GH_TOKEN` automatically. No other secret is needed — there is **no model key** in the nightly path.

**If you use `--emit-pr`, two one-time setups are also required** (the auto-heal commits, pushes a branch, and opens a PR — all three fail silently without these):

```bash
# 1. Let git push authenticate with the gh token (installs gh as the git
#    credential helper) — without it `git push` fails with a 403 / "could not
#    read Username", and the re-pin PR is skipped.
gh auth setup-git

# 2. A git identity for the commit — without it `git commit` fails and the run
#    reports it could not commit the re-pin.
git config --global user.name  "curation-bot"
git config --global user.email "curation-bot@users.noreply.github.com"
```

---

## The wrapper script

Keep the git hygiene and flags in one place. Save as `/opt/claude-base/scripts/curation-bot-run.sh` (or anywhere on the box — it is not part of the repo):

```bash
#!/usr/bin/env bash
# Nightly curation bot wrapper — LLM-free, $0 tokens.
set -euo pipefail

REPO=/opt/claude-base
STATE=/var/lib/curation-bot/watch-state.json   # persists across runs (outside the checkout)
DIGEST=/var/lib/curation-bot/digest            # last digest.json + digest.md

mkdir -p "$(dirname "$STATE")" "$DIGEST"

# Always re-verify exactly what main ships. reset --hard guarantees the clean
# tree that --emit-pr requires; the external --state-file is what survives it.
git -C "$REPO" fetch --quiet origin main
git -C "$REPO" reset --hard --quiet origin/main

# REQUIRED for --emit-pr: run from inside the repo. The re-pin auto-heal
# commits against the CURRENT working directory, so a wrapper that invokes the
# script by absolute path without cd'ing in first makes it skip with
# "not a git repo". Harmless for observe-only runs.
cd "$REPO"

"$REPO/scripts/curation-watch.sh" \
    --state-file "$STATE" \
    --digest-dir "$DIGEST" \
    --emit-issue \
    --emit-pr
```

Notes:
- **`--emit-pr` is the recommended auto-heal** (needs Contents + PR write). For every low-risk `re-pin` (a `verdict=pass` version bump) it advances the baseline `pinnedRef` in `registry.json` **and every matching preset in lockstep**, behind the pin-time safety screen, then opens a **draft** PR a human still reviews and merges. It **installs nothing** and stays `$0`/LLM-free. Without it the bot is observe-only and every benign version bump must be re-pinned by hand — recurring toil that also tends to leave `registry.json` and the preset copies diverged (the phantom-duplicate-drift failure the `validate-presets.sh` lockstep guard now blocks). Drop the flag only if you consciously want observe-only.
- The nightly `git reset --hard origin/main` discards the watch's in-place `lastVerified` writes to `registry.json` — that is intentional and harmless (freshness bookkeeping; the digest is the durable output). The sustained-collapse **state** is preserved because it lives in `--state-file`, outside the checkout.
- `curation-watch.sh` exits `0` on a completed run (with or without findings) and `2` only on a usage/setup error, so the timer's `OnFailure` only fires on real breakage.
- `--emit-pr` is **draft by default**; pass `--no-draft` only if you want a ready PR.
- **One open re-pin PR holds a lock on all the others.** While any `curation/re-pin-*` PR is open, no new re-pin PR is emitted (it would stack a near-duplicate every night, and force-updating the open branch could clobber in-flight curation commits). The digest names the blocking PR and its age, and escalates to a warning past `global.repinLockStaleDays` in `.claude/curation/trust-thresholds.json` (default 3 days). **Merge or close the open re-pin PR to release the auto-heal** — a lock left held simply parks every other re-pin behind it. The escalation also goes to stderr, so `journalctl -u curation-bot.service` shows it.

```bash
chmod +x /opt/claude-base/scripts/curation-bot-run.sh
```

---

## Option A — systemd timer (recommended)

`/etc/systemd/system/curation-bot.service`:

```ini
[Unit]
Description=Marketplace curation rot-watch (LLM-free)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=curation-bot
EnvironmentFile=/etc/claude-base-bot.env
ExecStart=/opt/claude-base/scripts/curation-bot-run.sh
# Hardening (read-only system, writable state dir only)
ProtectSystem=strict
ReadWritePaths=/opt/claude-base /var/lib/curation-bot
PrivateTmp=true
NoNewPrivileges=true
```

`/etc/systemd/system/curation-bot.timer`:

```ini
[Unit]
Description=Run the curation rot-watch nightly

[Timer]
OnCalendar=*-*-* 03:30:00
Persistent=true
RandomizedDelaySec=900

[Install]
WantedBy=timers.target
```

Enable it:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now curation-bot.timer
systemctl list-timers curation-bot.timer
```

## Option B — cron

```cron
# /etc/cron.d/curation-bot   (runs 03:30 nightly as the bot user)
30 3 * * * curation-bot . /etc/claude-base-bot.env; /opt/claude-base/scripts/curation-bot-run.sh >> /var/log/curation-bot.log 2>&1
```

---

## First run / verification

Run the wrapper once by hand and confirm the outcome:

```bash
sudo -u curation-bot --preserve-env=GH_TOKEN /opt/claude-base/scripts/curation-bot-run.sh
# or:  sudo systemctl start curation-bot.service && journalctl -u curation-bot.service -n 40

cat /var/lib/curation-bot/digest/digest.md          # the human-readable digest
jq '.findingCount' /var/lib/curation-bot/digest/digest.json
```

- If there are findings and you passed `--emit-issue`, a single issue titled `Curation digest — <date>` appears on the repo.
- An all-clean run writes a "No rot or drift detected" digest and opens **no** issue (no-noise contract).
- To rehearse without any side effects, run with `--dry-run` (no state write, no issue, no PR).

---

## Monthly discovery (the one LLM job — keep it separate)

`scripts/curation-discover.sh` surfaces **newly-published** community skills in covered domains and proposes the ones that clear trust + safety + advice-neutrality. The trust and safety gates are LLM-free; only the advice-neutrality + fit judgment calls a model (`claude -p`, Haiku triage with escalation), under a **hard token budget** that **fails safe** — budget exhaustion defers the remaining candidates and is reported, never a silent stop or runaway spend (EF-012).

It runs **monthly**, in its **own unit, never mixed with the $0 nightly watch**, under a hard `--budget` token cap.

> **Billing status (verify before relying on it):** the 2026-06-15 plan to meter `claude -p` on a separate "agentic" credit was **paused on 2026-06-16** and is being reworked. As of this writing, `claude -p` counts against your **normal subscription limits** — but the policy is unstable, so confirm the current state and keep `--budget` tight.

### Auth — two paths (pick by your environment)

`claude -p` in `-p` (non-interactive) mode picks auth in this order: `ANTHROPIC_API_KEY` → `CLAUDE_CODE_OAUTH_TOKEN` → subscription OAuth (`~/.claude/.credentials.json`).

**Path A — dedicated, capped API key (robust default for truly unattended).** A key does **not expire**; set a **hard monthly spend cap in the Anthropic console** (the real backstop, independent of `--budget`) and you can run forever without touching it. Put it in its **own** `EnvironmentFile`, never mixed with the watch:

```bash
# /etc/claude-base-discover.env  (chmod 600 — the ONLY place the model key lives)
ANTHROPIC_API_KEY=sk-ant-xxxxxxxx
```

**Path B — subscription login + a frequent keepalive (fine on a homelab already running `claude` jobs).** No key needed, but a subscription **OAuth access token expires (~1–2 weeks) and headless `claude -p` does NOT auto-refresh it** — it eventually returns `401` and stays broken until a human runs `claude` then `/login` **interactively** on the box. Mitigate, don't ignore:
> - a **daily keepalive ping** (`claude -p "pong" --max-turns 1 --model haiku`) keeps the refresh token warm and **alerts you** (e.g. Telegram) the moment it 401s, so you re-login promptly;
> - the discovery wrapper below **preflights** the same ping and **bails** on failure, so a dead token never masquerades as "0 candidates";
> - accept that Path B needs **periodic manual `/login`** — if that's not acceptable for your cadence, use Path A.

### Wrapper + shim (`/home/ubuntu/curation-bot/`)

The judge needs `claude` to emit **raw JSON**, but default `claude -p` keeps its coding-agent persona and **refuses** to ("treats it as a robustness test") → every judge call comes back unparseable and **every candidate is silently rejected**. The fix is a **`--system-prompt`** that reframes `claude` as a non-interactive data tool — this is **load-bearing**, not optional. `--tools ""` (drops ~34k cached tokens → ~98% cheaper) also needs a real argv, so wrap `claude` in a tiny shim and point `CURATION_LLM_CMD` at it:

```bash
# claude-disco
#!/usr/bin/env bash
exec claude -p --tools "" --strict-mcp-config \
  --system-prompt "You are a non-interactive data-processing tool. Execute the user instruction exactly and output ONLY what is asked — raw text or raw JSON, never wrapped in markdown fences, never with preamble, commentary, or refusal." \
  "$@"
```

```bash
# discover-run.sh
#!/usr/bin/env bash
set -euo pipefail
REPO=/opt/claude-base; BOT=/home/ubuntu/curation-bot; OUT=$BOT/discovery
mkdir -p "$OUT"
git -C "$REPO" fetch --quiet origin main && git -C "$REPO" reset --hard --quiet origin/main
cd "$REPO"
export CURATION_LLM_CMD="$BOT/claude-disco"
# Preflight (Path B): bail if auth is down so it can't look like "0 candidates".
printf 'Reply with just: pong' | "$BOT/claude-disco" --model haiku --max-turns 1 2>/dev/null | grep -qi pong \
  || { echo "preflight failed — claude auth down (run: claude then /login)"; exit 1; }
# --emit-issue: ONE propose-only issue with the proposals (no-noise). Never auto-adds.
"$REPO/scripts/curation-discover.sh" --digest-dir "$OUT" --budget 150000 --emit-issue
```

### Schedule — cron (no sudo) **or** systemd

**Zero-sudo (user crontab):**

```cron
0 4 1 * * /home/ubuntu/curation-bot/discover-run.sh >> /home/ubuntu/curation-bot/discover.log 2>&1
```

**Or a systemd unit** (Path A wants `EnvironmentFile=/etc/claude-base-discover.env`; needs root to place in `/etc` + `systemctl enable`):

```ini
# /etc/systemd/system/curation-discover.service        |  # …discover.timer
[Service]                                               |  [Timer]
Type=oneshot                                            |  OnCalendar=*-*-01 04:00:00
User=ubuntu                                             |  Persistent=true
Environment=HOME=/home/ubuntu                           |  RandomizedDelaySec=1800
EnvironmentFile=/etc/claude-base-discover.env  # Path A  |  [Install]
ExecStart=/home/ubuntu/curation-bot/discover-run.sh     |  WantedBy=timers.target
```

> **`--emit-issue` needs the same `gh` as the nightly watch**, with **`Issues: read & write`** on the PAT — the emission now passes `-R` (so it works from any CWD), but the **token still needs the scope**. `gh` is shared from `~/.config/gh`; the discover env file (Path A) adds **only** `ANTHROPIC_API_KEY`, never the `gh` token.

---

## Scope

- Two timers, two trust boundaries: the **nightly watch** ($0, `gh`-only) and the **monthly discovery** (model key, capped). Never share an `EnvironmentFile` — the model key must never be present in the nightly path.
- The bot only ever **proposes**. Acting on a digest (approving a re-pin, removing a dead recommendation, adding a discovered candidate) stays a human decision, consistent with the foundation's observe-never-install stance.
