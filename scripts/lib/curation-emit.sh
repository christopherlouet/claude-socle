#!/usr/bin/env bash
# =============================================================================
# curation-emit.sh — OPT-IN, flag-gated GitHub emission for the curation engine
# (Slice 3b, specs/marketplace-curation-engine). Sourced by curation-watch.sh.
#
# The nightly watch is silent by default (it only writes a digest). Emission is
# wired by the deploy bot via explicit flags, and implements the spec's "mix"
# output contract (clarification 1):
#   --emit-issue : ONE propose-only GitHub issue carrying the digest (the human
#                  approves; nothing is auto-applied). Only when there are
#                  findings (no-noise contract).
#   --emit-pr    : a single draft PR re-pinning low-risk DRIFT (a newer ref that
#                  re-passes BOTH the trust scorer AND the pin-time safety screen
#                  — EF-006 / US-4 / T303). A drift whose new content FAILS the
#                  safety screen is DEMOTED to propose-only (it stays in the
#                  issue digest, never auto-drafted).
#
# Every path is FAIL-SAFE (EF-012): a missing tool, a dirty tree, or a gh/git
# failure logs a warning and returns cleanly — it never aborts the watch run and
# never leaves a half-applied change unreported.
# =============================================================================

_EMIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/curation-common.sh
source "$_EMIT_DIR/curation-common.sh"
# shellcheck source=scripts/lib/curation-safety.sh
source "$_EMIT_DIR/curation-safety.sh"

# _curation_gh_repo — resolve the owner/repo `gh` should target, so emission does
# NOT depend on the caller's CWD (the deploy bot runs from / via systemd, where
# `gh` cannot infer a repo → every create silently failed). Order: CURATION_GH_REPO
# override, else the origin remote of this checkout. Empty on failure (caller
# falls back to no -R, preserving the old behaviour).
_curation_gh_repo() {
    if [ -n "${CURATION_GH_REPO:-}" ]; then printf '%s' "$CURATION_GH_REPO"; return 0; fi
    local url
    url=$(git -C "$_EMIT_DIR" remote get-url origin 2>/dev/null) || return 1
    url="${url%.git}"
    case "$url" in
        *github.com[:/]*) url="${url##*github.com}"; printf '%s' "${url#[:/]}" ;;
        *) return 1 ;;
    esac
}

# _gh_issue_create <body-file> <title> <rflag...> — create with label, retry w/o.
_gh_issue_create() {
    local body_file="$1" title="$2"; shift 2
    gh issue create "$@" --title "$title" --body-file "$body_file" --label curation >/dev/null 2>&1 && return 0
    # Retry without the label — a repo may not have the 'curation' label yet.
    gh issue create "$@" --title "$title" --body-file "$body_file" >/dev/null 2>&1 \
        || curation_warn "gh issue create failed"
    return 0
}

# emit_issue <title> <body-file> [dedupe-key] — propose-only issue, fail-safe.
# With a dedupe-key it is IDEMPOTENT: the body carries a stable marker
# (<!-- curation-issue:KEY -->) and a daily run UPDATES the one rolling issue
# instead of opening a duplicate (a fresh open issue per day was the digest-dup
# bug). Without a key, legacy create-only.
emit_issue() {
    local title="$1" body_file="$2" key="${3:-}"
    command -v gh >/dev/null 2>&1 || { curation_warn "gh not found; skipping issue"; return 0; }
    [ -f "$body_file" ] || { curation_warn "issue body missing: $body_file"; return 0; }
    local repo; repo=$(_curation_gh_repo) || repo=""
    local -a rflag; rflag=()
    [ -n "$repo" ] && rflag=(-R "$repo")

    if [ -z "$key" ]; then
        _gh_issue_create "$body_file" "$title" ${rflag[@]+"${rflag[@]}"}
        return 0
    fi

    # Keyed/idempotent path: prepend a findable marker, then update-or-create.
    local marker="<!-- curation-issue:${key} -->"
    local tmpbody
    if tmpbody=$(mktemp 2>/dev/null); then
        { printf '%s\n\n' "$marker"; cat "$body_file"; } > "$tmpbody"
    else
        tmpbody="$body_file"
    fi
    # Find an existing OPEN issue whose body carries the marker (local jq match —
    # no dependence on GitHub search handling of HTML comments).
    local existing=""
    existing=$(gh issue list ${rflag[@]+"${rflag[@]}"} --state open --limit 100 --json number,body \
        --jq "[.[] | select(.body | contains(\"$marker\"))] | .[0].number // empty" 2>/dev/null || true)
    if [ -n "$existing" ]; then
        gh issue edit "$existing" ${rflag[@]+"${rflag[@]}"} --title "$title" --body-file "$tmpbody" >/dev/null 2>&1 \
            || curation_warn "gh issue edit failed (#$existing)"
    else
        _gh_issue_create "$tmpbody" "$title" ${rflag[@]+"${rflag[@]}"}
    fi
    [ "$tmpbody" != "$body_file" ] && rm -f "$tmpbody"
    return 0
}

# _repin_apply <registry> <presets-dir> <repoRoot> <newRef> <now> — re-pin every
# registry record and preset recommendation whose repo-root matches, in place.
# Marketplace plugins: a preset copy of a marketplace plugin carries a
# NON-github url (e.g. claude.com/plugins/<x>) that no github repo-root can
# ever match, so preset entries are ALSO matched by the normalised marketplace
# key (mktkey) of the subject's registry record(s) (vendorUrl). Without this,
# a drift of such a plugin re-pins the registry only and the PR fails the
# pin-lockstep gate. NOTE: mktkey semantics MIRROR validate_pin_lockstep in
# scripts/validate-presets.sh — keep the two normalisations in lockstep,
# INCLUDING the (.vendorUrl // .vendorId) fallback (validate_registry now
# enforces a URL-shaped vendorUrl, so the fallback is dead on any valid
# registry — it is kept purely so the two expressions stay textually mirrored).
# Repin scope note: records are matched by repo-root, so every plugin of one
# marketplace repo moves to the new ref together — result stays lockstep-
# consistent and lands in a draft PR a maintainer reviews before merge.
_repin_apply() {
    local registry="$1" presets_dir="$2" subj="$3" cur="$4" now="$5" tmp f
    # Marketplace keys of the subject's registry records (empty array when the
    # subject has none, or the registry is missing — github-only behaviour).
    local mkeys='[]'
    if [ -f "$registry" ]; then
        mkeys=$(jq -c --arg s "$subj" '
            def mktkey: sub("^https?://";"") | (split("?")[0]) | (split("#")[0]) | sub("/$";"");
            def is_marketplace: test("^https?://") and (test("github\\.com") | not);
            [ .records[]?
              | select((.vendorId | split("/")[0:2] | join("/")) == $s)
              | (.vendorUrl // .vendorId // "") | strings
              | select(is_marketplace) | mktkey
            ] | unique' "$registry" 2>/dev/null) || mkeys='[]'
        [ -n "$mkeys" ] || mkeys='[]'
    fi
    if [ -f "$registry" ]; then
        if tmp=$(mktemp "$(dirname "$registry")/.repin.XXXXXX" 2>/dev/null) \
            && jq --arg s "$subj" --arg ref "$cur" --arg now "$now" \
                '.records |= map(if (.vendorId | split("/")[0:2] | join("/")) == $s
                                 then .pinnedRef = $ref | .lastVerified = $now else . end)' \
                "$registry" > "$tmp" 2>/dev/null; then
            mv "$tmp" "$registry"
        else
            [ -n "${tmp:-}" ] && rm -f "$tmp"
        fi
    fi
    for f in "$presets_dir"/*.json; do
        [ -f "$f" ] || continue
        # Match the SAME repo-root semantics the registry uses (owner/repo,
        # exact) — a substring `contains` would re-pin unrelated entries whose
        # url/id merely contains "owner/repo" as a fragment. A marketplace
        # entry (non-github url) matches by exact mktkey against the subject's
        # registry marketplace keys instead (see the function comment).
        if tmp=$(mktemp "$presets_dir/.repin.XXXXXX" 2>/dev/null) \
            && jq --arg s "$subj" --arg ref "$cur" --arg now "$now" --argjson mk "$mkeys" \
                'def root($x): ($x | sub("^https?://github.com/"; "") | split("?")[0] | split("#")[0] | split("/") | .[0:2] | join("/"));
                 def mktkey($x): ($x | sub("^https?://";"") | (split("?")[0]) | (split("#")[0]) | sub("/$";""));
                 def is_mkt($x): ($x | test("^https?://")) and (($x | test("github\\.com")) | not);
                 (.recommendedVendorSkills[]? | select(
                     (.url // .id // "") as $u
                     | (root($u) == $s)
                       or (is_mkt($u) and (($mk | index(mktkey($u))) != null))))
                   |= (.pinnedRef = $ref | .lastVerified = $now)' \
                "$f" > "$tmp" 2>/dev/null; then
            mv "$tmp" "$f"
        else
            [ -n "${tmp:-}" ] && rm -f "$tmp"
        fi
    done
}

# _repin_pr_body <safe-findings-json> <now> — the draft-PR description.
_repin_pr_body() {
    printf 'Automated re-pin of drifted vendor skills (curation engine, %s).\n\n' "$2"
    printf 'Each entry below re-passed the **trust scorer** AND the **pin-time safety screen** (EF-006).\n'
    printf 'The safety screen re-opens on every drift; any drift whose new content failed the screen was **demoted to propose-only** and is NOT in this PR.\n\n'
    printf '| Subject | Old pin | New ref |\n|---|---|---|\n'
    printf '%s' "$1" | jq -r '.[] | "| \(.subject) | \(.pinnedRef) | \(.currentRef) |"'
    printf '\n_Draft — a maintainer must review (re-confirm the safety screen) before merge._\n'
}

# _subpaths_for_repo <owner/repo> <registry> <presets-dir> — echo the '+'-joined,
# deduped union of subpaths (the part after owner/repo) for every registry record
# and preset recommendation whose repo-root matches. Empty when the skill sits at
# the repo root. Lets the pin-time safety screen scope to the skill's subpath
# instead of scanning the whole monorepo (#384 false-truncation fix).
_subpaths_for_repo() {
    local want="$1" registry="$2" presets_dir="$3" id owner rest repo sub acc="" f
    {
        [ -f "$registry" ] && jq -r '.records[].vendorId // empty' "$registry" 2>/dev/null
        for f in "$presets_dir"/*.json; do
            [ -f "$f" ] || continue
            jq -r '.recommendedVendorSkills[]? | (.id // .url) // empty' "$f" 2>/dev/null
        done
    } | {
        while IFS= read -r id; do
            [ -n "$id" ] || continue
            case "$id" in
                https://github.com/*) id="${id#https://github.com/}" ;;
                http://github.com/*)  id="${id#http://github.com/}" ;;
                *://*) continue ;;
            esac
            id="${id%%[?#]*}"; id="${id%/}"
            owner="${id%%/*}"; rest="${id#*/}"
            [ "$owner" != "$rest" ] || continue
            repo="${rest%%/*}"
            [ "$owner/$repo" = "$want" ] || continue
            sub="${rest#*/}"
            [ "$sub" = "$rest" ] && continue           # no subpath (root skill)
            case "$sub" in tree/*) sub="${sub#tree/*/}" ;; esac   # drop /tree/<branch>/
            [ -n "$sub" ] && acc+="${sub}+"
        done
        # split on '+', dedup segments, re-join with '+'
        printf '%s' "$acc" | tr '+' '\n' | grep . | sort -u | paste -sd'+' - || true
    }
}

# _skills_for_repo <owner/repo> <registry> — echo the comma-joined, deduped,
# sorted foundation-skill name(s) that pin <owner/repo> in the registry. This is
# the provenance answer to "why is this repo watched" — the digest renders it so
# a row like `anthropics/claude-code` reads as serving `dev-frontend-design`
# rather than an unexplained repo. Empty when the repo is reached ONLY via a
# preset recommendation (those carry no foundation-skill name).
_skills_for_repo() {
    local want="$1" registry="$2"
    [ -f "$registry" ] || return 0
    jq -r --arg want "$want" '
        .records[]
        | select((.vendorId | split("/")[0:2] | join("/")) == $want)
        | .foundationSkill // empty' "$registry" 2>/dev/null \
        | grep . | sort -u | paste -sd',' - || true
}

# curation_repin_lock — echo the #458 open-PR lock as ONE JSON object
# {count,number,createdAt,url,ageDays}, or NOTHING when no curation/re-pin-* PR
# is open or the lookup could not be trusted. Read-only (a single `gh pr list`),
# so a preview may call it without emitting anything.
#
# It reports WHO holds the lock and since WHEN (2026-09-06): held for 7 nights
# on one unreviewed draft, the lock silently starved every other re-pin while
# the digest kept printing "re-pin" as the action for each drift. The caller
# renders that and escalates past a staleness bar, so a long-held lock can never
# again look like a quiet night.
#
# A failed lookup echoes NOTHING — the worst case of an outage is the status-quo
# duplicate PR, never a missed re-pin.
curation_repin_lock() {
    local lookup_repo rows n_open
    lookup_repo=$(_curation_gh_repo) || lookup_repo=""
    # --limit 100 mirrors emit_issue's rolling-issue lookup: gh's default page
    # of 30 could miss the open lock PR on a busy repo (silent lock bypass).
    # The branch filter is applied HERE, not in a server-side `--jq` string: as
    # an argument handed to gh it could never be exercised by an offline test.
    # The --json value is ONE comma-joined argument (quoted so it does not read
    # as an array of elements — SC2054).
    local lookup_args=(pr list --state open --limit 100
        --json "number,createdAt,headRefName,url")
    [ -n "$lookup_repo" ] && lookup_args+=(-R "$lookup_repo")
    # Undatable rows sort LAST: a blank createdAt ahead of every real timestamp
    # would make an undatable PR the reported holder and its unknown age the
    # reported age, hiding a perfectly datable older one.
    rows=$(gh "${lookup_args[@]}" 2>/dev/null) || return 0
    rows=$(printf '%s' "$rows" | jq -c '
        [.[] | select(.headRefName // "" | startswith("curation/re-pin-"))]
        | sort_by(if (.createdAt // "") == "" then "9999" else .createdAt end)' 2>/dev/null) || return 0
    n_open=$(printf '%s' "$rows" | jq 'length' 2>/dev/null) || return 0
    [ "${n_open:-0}" -gt 0 ] 2>/dev/null || return 0

    # Oldest first: the lock's age is the age of the PR that has held it
    # longest, which is the number the maintainer needs to see.
    local lock_num lock_created lock_url lock_age
    lock_num=$(printf '%s' "$rows" | jq -r '.[0].number // empty')
    lock_created=$(printf '%s' "$rows" | jq -r '.[0].createdAt // empty')
    lock_url=$(printf '%s' "$rows" | jq -r '.[0].url // empty')
    # An undatable createdAt still holds the lock — the age is reported as
    # unknown (null) rather than guessed, and never as 0 (which would read as
    # "opened today" and defuse the escalation).
    lock_age=$(curation_days_since "$lock_created" 2>/dev/null) || lock_age=""
    # The age is measured against the HOST clock, so a box running behind makes
    # a fresh PR look future-dated. Read that as just-opened rather than
    # printing a negative age or letting skew fake an escalation.
    case "$lock_age" in -*) lock_age=0 ;; esac
    jq -cn --argjson n "$n_open" --arg num "$lock_num" --arg created "$lock_created" \
        --arg url "$lock_url" --arg age "$lock_age" \
        '{count:$n,
          number:(if $num=="" then null else ($num|tonumber) end),
          createdAt:(if $created=="" then null else $created end),
          url:(if $url=="" then null else $url end),
          ageDays:(if $age=="" then null else ($age|tonumber) end)}'
}

# emit_repin_pr <surfaced-findings> <registry> <presets-dir> <draft-bool> <now>
# Echoes a JSON summary {drafted:[subjects], demoted:[findings], branch?}. When
# the open-PR lock stopped the emission it also carries skipped:"open-pr" and
# lock:{count,number,createdAt,url,ageDays} — who holds it and for how long, so
# the caller can say so in the digest instead of reporting a quiet night.
emit_repin_pr() {
    local findings="$1" registry="$2" presets_dir="$3" draft="$4" now="$5"
    local repins n
    repins=$(printf '%s' "$findings" | jq -c '[.[] | select(.type == "drift" and .proposedAction == "re-pin")]')
    n=$(printf '%s' "$repins" | jq 'length')
    [ "$n" -gt 0 ] || { echo '{"drafted":[],"demoted":[]}'; return 0; }

    # Dedupe (mirrors emit_issue's rolling-issue lookup): while a previous
    # re-pin PR is still OPEN, emitting another stacks a near-duplicate every
    # night, and updating/closing it instead could clobber a maintainer's
    # in-flight curation commits on its branch. So the open PR holds a lock:
    # skip emission (the digest still reports the fresh drift set each night;
    # the night after the open PR merges, the remaining delta emits normally).
    # A failed lookup PROCEEDS — the worst case of an outage is the status-quo
    # duplicate PR, never a missed re-pin (checked before the safety screens,
    # sparing their per-finding gh calls on locked nights).
    local lock lock_num lock_age
    lock=$(curation_repin_lock)
    if [ -n "$lock" ]; then
        lock_num=$(printf '%s' "$lock" | jq -r '.number // "?"')
        lock_age=$(printf '%s' "$lock" | jq -r '.ageDays // "?"')
        curation_warn "an open curation/re-pin-* PR already exists (#$lock_num, open $lock_age day(s)); re-pin emission skipped"
        jq -cn --argjson l "$lock" '{drafted:[], demoted:[], skipped:"open-pr", lock:$l}'
        return 0
    fi

    # Pin-time safety gate (T303): only a drift whose NEW ref passes the content
    # screen may auto-draft; the rest are demoted to propose-only.
    local safe='[]' demoted='[]' f subj cur screen sv
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        subj=$(printf '%s' "$f" | jq -r '.subject')
        cur=$(printf '%s' "$f" | jq -r '.currentRef')
        # Scope the screen to the skill's subpath(s) — a subpath skill in a big
        # monorepo must not be judged by the whole repo's exec surface (#384).
        local subp; subp=$(_subpaths_for_repo "$subj" "$registry" "$presets_dir")
        screen=$(curation_safety_screen "$subj" "$cur" "$subp")
        sv=$(printf '%s' "$screen" | jq -r '.verdict')
        if [ "$sv" = "pass" ]; then
            safe=$(jq -cn --argjson a "$safe" --argjson f "$f" '$a + [$f]')
        else
            demoted=$(jq -cn --argjson a "$demoted" --argjson f "$f" --argjson s "$screen" '$a + [$f + {safety:$s}]')
        fi
    done < <(printf '%s' "$repins" | jq -c '.[]')

    local n_safe; n_safe=$(printf '%s' "$safe" | jq 'length')
    if [ "$n_safe" -eq 0 ]; then
        jq -cn --argjson d "$demoted" '{drafted:[], demoted:$d}'
        return 0
    fi

    # Guard the maintainer's tree: only proceed on a clean git checkout (the bot
    # always runs on one). Any deviation → no PR, reported.
    command -v git >/dev/null 2>&1 || { curation_warn "git not found; re-pin PR skipped"; jq -cn --argjson d "$demoted" '{drafted:[], demoted:$d, skipped:"no-git"}'; return 0; }
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { curation_warn "not a git repo; re-pin PR skipped"; jq -cn --argjson d "$demoted" '{drafted:[], demoted:$d, skipped:"no-repo"}'; return 0; }
    if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
        curation_warn "working tree not clean; re-pin PR skipped"
        jq -cn --argjson d "$demoted" '{drafted:[], demoted:$d, skipped:"dirty-tree"}'
        return 0
    fi

    # Remember the starting branch so we never strand the invoker on the bot
    # branch (every exit path below restores it).
    local orig; orig=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
    _restore_branch() { [ -n "$orig" ] && { git switch "$orig" >/dev/null 2>&1 || git checkout "$orig" >/dev/null 2>&1; }; }

    local branch="curation/re-pin-$now"
    if ! { git switch -c "$branch" >/dev/null 2>&1 || git checkout -b "$branch" >/dev/null 2>&1; }; then
        curation_warn "could not create branch $branch"
        jq -cn --argjson d "$demoted" '{drafted:[], demoted:$d, skipped:"branch"}'
        return 0
    fi

    while IFS= read -r f; do
        [ -n "$f" ] || continue
        subj=$(printf '%s' "$f" | jq -r '.subject')
        cur=$(printf '%s' "$f" | jq -r '.currentRef')
        _repin_apply "$registry" "$presets_dir" "$subj" "$cur" "$now"
    done < <(printf '%s' "$safe" | jq -c '.[]')

    git add -A >/dev/null 2>&1
    # A commit failure here has two very different causes that both used to read
    # the same "nothing to commit": (1) _repin_apply matched no registry/preset
    # record → git genuinely has nothing staged; (2) there IS a change but the
    # commit fails — almost always an unset git identity (user.name/user.email) on
    # the bot box. Classify by the git output and surface the real error. Keep a
    # SINGLE commit call (no extra `git diff` probe) so the mocked-git test path
    # and the real one behave identically.
    local _commit_err
    if ! _commit_err=$(git commit -m "chore(curation): re-pin ${n_safe} drifted vendor skill(s) to latest verified ref" 2>&1); then
        if printf '%s' "$_commit_err" | grep -qiF "nothing to commit"; then
            curation_warn "re-pin produced no staged change (finding matched no registry/preset record)"
            _restore_branch
            jq -cn --argjson d "$demoted" '{drafted:[], demoted:$d, skipped:"no-changes"}'
        else
            curation_warn "re-pin commit failed (is git user.name/user.email set?): ${_commit_err}"
            _restore_branch
            jq -cn --argjson d "$demoted" '{drafted:[], demoted:$d, skipped:"no-commit"}'
        fi
        return 0
    fi
    # A failed push aborts PR creation (no PR against a branch the remote lacks)
    # and restores the original branch — fail safe, leaving only a local branch.
    if ! git push -u origin "$branch" >/dev/null 2>&1; then
        curation_warn "git push failed; re-pin PR not opened"
        _restore_branch
        jq -cn --argjson d "$demoted" '{drafted:[], demoted:$d, skipped:"push"}'
        return 0
    fi

    local body_file; body_file=$(mktemp 2>/dev/null)
    _repin_pr_body "$safe" "$now" > "$body_file"
    local repo; repo=$(_curation_gh_repo) || repo=""
    local args=(pr create)
    [ -n "$repo" ] && args+=(-R "$repo")
    args+=(--title "chore(curation): re-pin ${n_safe} vendor skill(s)" --body-file "$body_file")
    [ "$draft" = "true" ] && args+=(--draft)
    gh "${args[@]}" >/dev/null 2>&1 || curation_warn "gh pr create failed"
    rm -f "$body_file"
    _restore_branch

    jq -cn --argjson s "$safe" --argjson d "$demoted" --arg b "$branch" \
        '{drafted:($s | map(.subject)), demoted:$d, branch:$b}'
    return 0
}
