#!/usr/bin/env bash
# =============================================================================
# curation-watch.sh — nightly rot-watch for the marketplace curation engine
# (Slice 3a, specs/marketplace-curation-engine). LLM-FREE → $0 tokens, immune to
# the 2026-06-15 agentic-billing change (EF-012). It re-verifies every recommended
# / pointed vendor skill and emits ONE reviewable digest per run.
#
# This 3a slice PRODUCES the digest only — it performs NO outbound gh mutation.
# The mix-output emission (re-pin draft-PR vs propose-only issue) and the
# sustained-collapse state live in Slice 3b + the deploy recipe (Slice 4).
#
# Per target it flags: archived / abandoned(stale) / below-popularity-bar /
# license change (all via trust-score.sh) and content-DRIFT (the repo's current
# good ref has moved beyond our pinnedRef → a newer version exists). gh failures
# are fail-safe: the target becomes an "error" finding, the run still completes.
#
# It ALSO consistency-checks the graduatable watch-list (awaiting-vendors.json):
# each entry's currentBest prose carries a license stance ("unlicensed" / a named
# SPDX id) that humans hand-edit and that NEVER passes through the 4-source probe,
# so it silently rots. For every entry that asserts a stance we re-probe the repo
# (canonical trust-score cascade) and emit a "license-note" finding when the live
# result disagrees — e.g. a stale "unlicensed" note hiding a README-declared MIT
# (the exact false-negative that understates a candidate against a "+license" bar).
#
# Usage:
#   curation-watch.sh [--dry-run] [--digest-dir DIR]
#                     [--registry FILE] [--presets-dir DIR] [--thresholds FILE]
#                     [--awaiting FILE]
#   --dry-run      do not write lastVerified back to the registry
#   --digest-dir   write digest.json + digest.md here (default: stdout JSON only)
#
# Exit: 0 = run completed (with or without findings); 2 = usage/setup error.
# =============================================================================

set -u

_WATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/curation-common.sh
source "$_WATCH_DIR/lib/curation-common.sh"
# shellcheck source=scripts/lib/trust-score.sh
source "$_WATCH_DIR/lib/trust-score.sh"
# shellcheck source=scripts/lib/curation-safety.sh
source "$_WATCH_DIR/lib/curation-safety.sh"
# shellcheck source=scripts/lib/curation-emit.sh
source "$_WATCH_DIR/lib/curation-emit.sh"

REGISTRY="${CURATION_REGISTRY:-$_WATCH_DIR/../.claude/curation/registry.json}"
PRESETS_DIR="${CURATION_PRESETS_DIR:-$_WATCH_DIR/../.claude/presets}"
AWAITING="${CURATION_AWAITING:-$_WATCH_DIR/../.claude/curation/awaiting-vendors.json}"
STATE_FILE="${CURATION_STATE:-}"
DIGEST_DIR=""
DRY_RUN=false
EMIT_ISSUE=false
EMIT_PR=false
PR_DRAFT=true   # auto-emitted re-pins are DRAFT by default; --no-draft to override

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        --digest-dir) DIGEST_DIR="${2:-}"; [ -n "$DIGEST_DIR" ] || { echo "--digest-dir requires a path" >&2; exit 2; }; shift 2 ;;
        --registry) REGISTRY="${2:-}"; [ -n "$REGISTRY" ] || { echo "--registry requires a path" >&2; exit 2; }; shift 2 ;;
        --presets-dir) PRESETS_DIR="${2:-}"; [ -n "$PRESETS_DIR" ] || { echo "--presets-dir requires a path" >&2; exit 2; }; shift 2 ;;
        --awaiting) AWAITING="${2:-}"; [ -n "$AWAITING" ] || { echo "--awaiting requires a path" >&2; exit 2; }; shift 2 ;;
        --state-file) STATE_FILE="${2:-}"; [ -n "$STATE_FILE" ] || { echo "--state-file requires a path" >&2; exit 2; }; shift 2 ;;
        --thresholds) CURATION_THRESHOLDS="${2:-}"; [ -n "$CURATION_THRESHOLDS" ] || { echo "--thresholds requires a path" >&2; exit 2; }; export CURATION_THRESHOLDS; shift 2 ;;
        --emit-issue) EMIT_ISSUE=true; shift ;;
        --emit-pr) EMIT_PR=true; shift ;;
        --draft) PR_DRAFT=true; shift ;;        # explicit (default); kept for clarity
        --no-draft) PR_DRAFT=false; shift ;;    # escape hatch: open a ready PR
        -h|--help) sed -nE 's/^# ?//p' "$0" | sed -nE '/^curation-watch/,/^Exit/p'; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

command -v jq >/dev/null 2>&1 || { echo "[ERROR] jq is required" >&2; exit 2; }
[ -f "$REGISTRY" ] || { echo "[ERROR] registry not found: $REGISTRY" >&2; exit 2; }

# watch-state.json lives beside the registry by default — it is the cross-run
# memory the sustained-collapse / license-change detectors need (a single noisy
# reading must never alarm; only a SUSTAINED signal does — spec edge case).
[ -n "$STATE_FILE" ] || STATE_FILE="$(dirname "$REGISTRY")/watch-state.json"

# Collapse drop threshold (percent below the reference popularity). Read from the
# thresholds file with a documented default so a config typo never silently
# changes sensitivity.
COLLAPSE_PCT=$(jq -r '(.global.collapseDropPct | numbers) // 50' "$CURATION_THRESHOLDS" 2>/dev/null || echo 50)
[ -n "$COLLAPSE_PCT" ] || COLLAPSE_PCT=50

# Days an open re-pin PR may hold the #458 lock before the digest escalates from
# a note to a warning. Same read-with-a-documented-default shape as above, plus
# an INTEGER check: `numbers` lets a float through and `[ 7 -ge 3.5 ]` aborts
# with status 2, which every caller reads as "not stale" — a config typo would
# have turned the escalation off silently, the opposite of failing safe.
LOCK_STALE_DAYS=$(jq -r '(.global.repinLockStaleDays | numbers) // 3' "$CURATION_THRESHOLDS" 2>/dev/null || echo 3)
case "$LOCK_STALE_DAYS" in
    ''|*[!0-9]*) LOCK_STALE_DAYS=3 ;;
esac

# _repo_root <vendorId-or-url> — the scoreable owner/repo (first two path
# segments), derived from a registry vendorId (owner/repo[/subpath…]) or a
# github.com URL. Echoes nothing for a non-github / non-repo identifier.
_repo_root() {
    local s="$1"
    case "$s" in
        https://github.com/*) s="${s#https://github.com/}" ;;
        http://github.com/*)  s="${s#http://github.com/}" ;;
        *://*) return 0 ;;  # some other URL (e.g. claude.com marketplace) → skip
    esac
    s="${s%%[?#]*}"   # drop any ?query / #fragment
    # take the first two slash-separated segments
    local owner="${s%%/*}"; local rest="${s#*/}"; local repo="${rest%%/*}"
    [ -n "$owner" ] && [ -n "$repo" ] && [ "$owner" != "$rest" ] && printf '%s/%s\n' "$owner" "$repo"
}

# _prose_repo <currentBest-prose> — the first owner/repo token in a watch-list
# entry's free-text currentBest ("vp-k/flutter-craft (~10 stars, …)" → vp-k/
# flutter-craft). Echoes nothing when the prose names no repo (e.g. "NO-SUPPLY …").
_prose_repo() {
    printf '%s' "$1" | grep -oE '[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' | head -n1
}

# _prose_license_stance <currentBest-prose> — classify the license CLAIM the prose
# makes, so the guardrail only fires on a genuine contradiction (silent entries
# make no claim and are never flagged). A named SPDX id wins over an "unlicensed"
# phrase, so "MIT … no LICENSE file" reads as licensed (the README declares MIT;
# the missing FILE is incidental). Echoes: licensed | none | unknown.
_prose_license_stance() {
    local p="$1"
    if printf '%s' "$p" | grep -iqE '(^|[^[:alnum:]-])(MIT|Apache(-| )?2|BSD(-[0-9]-Clause)?|ISC|MPL-2\.0|GPL-[0-9]|AGPL-[0-9]|LGPL-[0-9]|Unlicense|CC0|BSL)([^[:alnum:]-]|$)'; then
        echo "licensed"
    elif printf '%s' "$p" | grep -iqE 'unlicensed|no licen[cs]ed?\b|without (a )?licen[cs]e|licen[cs]e:? *none'; then
        echo "none"
    else
        echo "unknown"
    fi
}

# watch_awaiting_licenses — consistency-check the watch-list (awaiting-vendors).
# For each entry that names a repo AND asserts a license stance, re-probe the repo
# via the canonical trust-score cascade and emit a "license-note" finding when the
# live result disagrees with the prose. LLM-free; fail-safe (a gh outage skips the
# entry rather than raising a false drift alarm). Emits newline-delimited finding
# objects on stdout (none when every note matches its probe).
watch_awaiting_licenses() {
    [ -f "$AWAITING" ] || return 0
    jq -c '.entries[]?' "$AWAITING" 2>/dev/null | while IFS= read -r entry; do
        local prose fs repo stance score reasons probe note
        prose=$(printf '%s' "$entry" | jq -r '.currentBest // ""')
        fs=$(printf '%s' "$entry" | jq -r '.foundationSkill // ""')
        repo=$(_prose_repo "$prose")
        [ -n "$repo" ] || continue
        stance=$(_prose_license_stance "$prose")
        [ "$stance" = "unknown" ] && continue   # no claim → nothing can drift
        # Live probe — reuse the 4-source cascade (manifest/file/README/SPDX). A
        # "missing-license" reason appears IFF all four sources fail.
        score=$(trust_score "$repo" community 2>/dev/null) || continue
        reasons=$(printf '%s' "$score" | jq -r '.reasons | join(",")')
        if printf '%s' "$reasons" | grep -q 'missing-license'; then
            probe="missing"
        else
            probe="licensed"
        fi
        note=""
        if [ "$stance" = "none" ] && [ "$probe" = "licensed" ]; then
            note="note-claims-unlicensed-but-probe-finds-license:$reasons"
        elif [ "$stance" = "licensed" ] && [ "$probe" = "missing" ]; then
            note="note-claims-license-but-probe-finds-none"
        fi
        [ -n "$note" ] || continue
        printf '%s' "$score" | jq -c --arg fs "$fs" --arg note "$note" \
            '{subject:.repo, track:"community", pinnedRef:"(watch-list)",
              currentRef:null, drift:false, type:"license-note", verdict:"flag",
              reasons:[$note], forSkills:(if $fs=="" then null else $fs end),
              stars:.stars, license:.license, ageDays:.ageDays,
              proposedAction:"propose"}'
    done
}

# collect_targets — emit unique {repoRoot,track,pinnedRef} JSON objects gathered
# from the registry records and every preset recommendation, deduped by
# (repoRoot,pinnedRef). gh is NOT called here.
#
# Attribution is REPO-LEVEL by design. When one repo backs several subpath
# records (e.g. anthropics/skills → mcp-builder for dev-mcp AND claude-api for
# dev-ai-integration), a drift finding lists ALL of that repo's foundation
# skills in forSkills even if only one subpath's files changed. Pinning is
# per-repo-ref (both records share the ref), so a re-pin advances both baselines
# correctly regardless — the only imprecision is cosmetic (the digest can't say
# WHICH subpath changed). Narrowing forSkills to the changed subpath would need a
# per-drift `gh compare pinned...current` file-list call on the nightly path;
# that gh/rate-limit cost is not justified for the current single multi-subpath
# repo, so attribution stays repo-level intentionally (not a bug). Revisit if
# multi-subpath repos proliferate.
collect_targets() {
    {
        jq -c '.records[] | {repoRoot:.vendorId, track:.trustTrack, pinnedRef:.pinnedRef}' "$REGISTRY"
        local f
        for f in "$PRESETS_DIR"/*.json; do
            [ -f "$f" ] || continue
            jq -c '.recommendedVendorSkills[]? | {repoRoot:(.url // .id), track:.trustTrack, pinnedRef:.pinnedRef}' "$f"
        done
    } | while IFS= read -r line; do
            local root track pin
            root=$(printf '%s' "$line" | jq -r '.repoRoot')
            root=$(_repo_root "$root")
            [ -n "$root" ] || continue
            track=$(printf '%s' "$line" | jq -r '.track')
            pin=$(printf '%s' "$line" | jq -r '.pinnedRef')
            jq -cn --arg r "$root" --arg t "$track" --arg p "$pin" '{repoRoot:$r, track:$t, pinnedRef:$p}'
        done | jq -s 'unique_by([.repoRoot, .pinnedRef])'
}

# resolve_current_ref <repo> <pinnedRef> — the repo's current good ref, compared
# LIKE-WITH-LIKE: a 40-hex SHA pin resolves to HEAD sha; a tag pin resolves to the
# latest release tag. A tag pin on a repo that publishes NO releases stays
# UNRESOLVED (empty) rather than falling back to a sha — comparing a tag to a sha
# would report drift on every run. Echoes the current ref, or nothing when it
# cannot be resolved (gh failure or tag-pin-without-releases).
#
# Like-with-like extends to tag FAMILIES: a monorepo releases several packages
# under distinct tag prefixes (`shadcn@4.13.0`, `@shadcn/react@0.2.1`, ...), so
# the repo-global latest release can belong to a DIFFERENT package than the pin
# and would report phantom drift on every run. A `<name>@<version>` pin therefore
# resolves to the newest stable release of ITS OWN family (same `<name>@` prefix,
# drafts/prereleases skipped — releases/latest excludes them too); a family with
# no release in the first page stays UNRESOLVED rather than crossing families.
resolve_current_ref() {
    local repo="$1" pinned="$2"
    if [[ "$pinned" =~ ^[0-9a-f]{40}$ ]]; then
        curation_gh_api "repos/$repo/commits/HEAD" 2>/dev/null | jq -r '.sha // empty'
        return
    fi
    local family=""
    [[ "$pinned" == *@* ]] && family="${pinned%@*}"
    if [ -n "$family" ]; then
        curation_gh_api "repos/$repo/releases?per_page=100" 2>/dev/null \
            | jq -r --arg fam "$family" \
                '[.[] | select(.draft == false and .prerelease == false)
                      | select(.tag_name | startswith($fam + "@"))]
                 | first.tag_name // empty'
    else
        curation_gh_api "repos/$repo/releases/latest" 2>/dev/null | jq -r '.tag_name // empty'
    fi
}

# _repo_has_root_record <owner/repo> <registry> <presets-dir> — true when any
# registry record or preset recommendation watches the repo at its ROOT (no
# subpath): the whole repo is then the skill and every change is relevant, so
# subpath-scoped drift must not engage.
_repo_has_root_record() {
    local want="$1" registry="$2" presets_dir="$3" f
    {
        [ -f "$registry" ] && jq -r '.records[].vendorId // empty' "$registry" 2>/dev/null
        for f in "$presets_dir"/*.json; do
            [ -f "$f" ] || continue
            jq -r '.recommendedVendorSkills[]? | (.id // .url) // empty' "$f" 2>/dev/null
        done
    } | sed -e 's#^https\{0,1\}://github.com/##' -e 's#[?\#].*$##' -e 's#/$##' \
      | grep -qxF "$want"
}

# _drift_subpath_touched <repo> <oldRef> <newRef> <'+'-joined subpaths> — did
# the old→new range touch any of the subpaths? Echoes yes|no|unknown. ONE
# compare call; every unconfirmable outcome is "unknown" (treated as touched):
# unfetchable compare, and a possibly-truncated file list (the compare API caps
# files at 300 — an all-outside verdict on a truncated list would be a false
# suppression). A rename is a touch on BOTH its old and new path.
_drift_subpath_touched() {
    local repo="$1" old="$2" new="$3" subs="$4" body
    body=$(curation_gh_api "repos/$repo/compare/$old...$new" 2>/dev/null) || { printf 'unknown'; return; }
    printf '%s' "$body" | jq -r --arg subs "$subs" '
        def under($p): . == $p or startswith($p + "/");
        ($subs | split("+")) as $S
        | (.files // []) as $F
        | if ($F | length) >= 300 then "unknown"
          elif ([$F[] | .filename, (.previous_filename // empty)]
                | any(. as $f | $S | any(. as $s | $f | under($s)))) then "yes"
          else "no" end' 2>/dev/null || printf 'unknown'
}

# watch_one <repoRoot> <track> <pinnedRef> — emit one finding JSON object.
watch_one() {
    local repo="$1" track="$2" pinned="$3"

    # Provenance: the foundation skill(s) this repo is watched FOR. Carried on the
    # finding so the digest can explain WHY a repo is tracked (empty for a
    # preset-only repo). Computed offline from the registry — no gh call.
    local for_skills; for_skills=$(_skills_for_repo "$repo" "$REGISTRY")

    local score verdict
    if ! score=$(trust_score "$repo" "$track" 2>/dev/null); then
        # gh unavailable → fail-safe error finding; never abort the run.
        jq -cn --arg repo "$repo" --arg track "$track" --arg pinned "$pinned" \
            --arg forSkills "$for_skills" \
            '{subject:$repo, track:$track, pinnedRef:$pinned, type:"error",
              verdict:"error", reasons:["gh-unavailable"], currentRef:null,
              forSkills:(if $forSkills=="" then null else $forSkills end),
              proposedAction:"propose"}'
        return
    fi
    verdict=$(printf '%s' "$score" | jq -r '.verdict')

    local current drift="false"
    current=$(resolve_current_ref "$repo" "$pinned")
    if [ -n "$current" ] && [ "$current" != "$pinned" ]; then
        drift="true"
    fi

    # Subpath-scoped drift (narrow lift of the #444 "repo-level attribution"
    # doctrine): a sha pin on a subpath skill in a very active monorepo (e.g.
    # anthropics/claude-code/plugins/frontend-design) re-drifts on EVERY repo
    # commit and re-proposed a content-no-op re-pin nightly — which, since the
    # #458 open-PR lock, would also block every other re-pin. When ALL records
    # watching the repo are subpath-scoped, one compare call checks whether the
    # pinned...current range touches any of those subpaths; untouched → not
    # drift (lastVerified still refreshes). Fail-safe: root record present,
    # unfetchable compare, or a possibly-truncated file list all keep the
    # drift. The pin then only advances when the subpath REALLY changes — or
    # when the accumulated repo range exceeds the compare cap (300 files),
    # whose fail-open surfaces a baseline-advancing re-pin at bounded
    # intervals. Tag pins are governed by release/tag-family semantics instead.
    if [ "$drift" = "true" ] && [[ "$pinned" =~ ^[0-9a-f]{40}$ ]] \
        && ! _repo_has_root_record "$repo" "$REGISTRY" "$PRESETS_DIR"; then
        local scope
        scope=$(_subpaths_for_repo "$repo" "$REGISTRY" "$PRESETS_DIR")
        if [ -n "$scope" ] \
            && [ "$(_drift_subpath_touched "$repo" "$pinned" "$current" "$scope")" = "no" ]; then
            drift="false"
        fi
    fi

    # Classify. Only things that need a NEW action are surfaced (see the digest
    # filter): a hard-failing verdict is "rot"; an outdated pin is "drift". A soft
    # "flag" with no drift (e.g. a repo that simply has no license) is a STANDING,
    # already-recorded condition — it is typed "flag" and NOT re-surfaced every
    # run (that would be perpetual noise). Detecting a CHANGE to a soft signal
    # (license removed, popularity collapse) is state-based → Slice 3b.
    #   rot/error → propose-only (digest); drift+pass → re-pin (auto-draftable in 3b).
    local type action
    if [ "$verdict" = "fail" ]; then
        type="rot"; action="propose"
    elif [ "$drift" = "true" ]; then
        type="drift"; action=$([ "$verdict" = "pass" ] && echo "re-pin" || echo "propose")
    elif [ "$verdict" = "flag" ]; then
        type="flag"; action="none"
    else
        type="clean"; action="none"
    fi

    printf '%s' "$score" | jq -c \
        --arg pinned "$pinned" --arg current "${current:-}" \
        --arg type "$type" --arg drift "$drift" --arg action "$action" \
        --arg forSkills "$for_skills" \
        '{subject:.repo, track:.track, pinnedRef:$pinned,
          currentRef:(if $current=="" then null else $current end),
          drift:($drift=="true"), type:$type, verdict:.verdict, reasons:.reasons,
          forSkills:(if $forSkills=="" then null else $forSkills end),
          stars:.stars, license:.license, ageDays:.ageDays, proposedAction:$action}'
}

# apply_state <finding> <priorSubjectState|null> — fold cross-run state into a
# base finding. Detects two STATE-BASED signals the single-run scorer cannot:
#   * popularity collapse — current stars fell ≥ COLLAPSE_PCT% below the tracked
#     reference; surfaced only once SUSTAINED (collapseStreak ≥ 2) so a single
#     noisy reading / metric reset never alarms (spec edge case). The reference
#     is held steady WHILE collapsed (so consecutive runs keep comparing to the
#     pre-drop level) and re-tracks the current value once recovered.
#   * license change — a previously-recorded real license differs now (removed or
#     swapped); we point, never copy (EF-010), but a license regressing is a
#     review-worthy change.
# Both only ever re-type a soft/drift finding (never a hard rot/error) and force
# proposedAction back to "propose" — neither is safe to auto-re-pin. Echoes a
# JSON object {finding:<augmented>, state:<newSubjectState>}.
apply_state() {
    local finding="$1" prior="$2"
    jq -cn --argjson f "$finding" --argjson prior "$prior" \
        --argjson pct "$COLLAPSE_PCT" --arg now "$NOW" '
        ($f.stars) as $cur
        | ($f.license // "NONE") as $lic
        | (if $prior == null then ($cur // 0) else ($prior.refStars // $prior.stars // $cur // 0) end) as $ref
        # Collapse only when we actually observed a star count this run; an absent
        # reading must NOT fabricate a 0-star "collapse". ≥ COLLAPSE_PCT% drop uses
        # <= so a clean 50% halving (the canonical example) is caught.
        | (($prior != null) and ($cur != null) and ($ref > 0) and (($cur * 100) <= ($ref * (100 - $pct)))) as $collapsed
        | (if $collapsed then (($prior.collapseStreak // 0) + 1) else 0 end) as $streak
        | (if $collapsed then $ref else ($cur // $ref) end) as $newref
        | ($collapsed and ($streak >= 2)) as $collapseActive
        | ($prior.license // null) as $plic
        # A license CHANGE requires a real license on BOTH sides (removed → NONE,
        # or swapped MIT→GPL); NOASSERTION means "present but unclassified" (see
        # trust-score) so MIT→NOASSERTION is not a regression and must not flag.
        | (($plic != null)
           and ($plic | IN("", "NONE", "null", "NOASSERTION") | not)
           and ($lic | IN("", "null", "NOASSERTION") | not)
           and ($plic != $lic)) as $licChanged
        | ($f
           | (if $licChanged then .reasons += ["license-change:\($plic)->\($lic)"] else . end)
           | (if $collapseActive then .reasons += ["collapse:\($cur)<ref\($ref)"] else . end)
           | (if (.type == "clean" or .type == "flag" or .type == "drift") then
                 (if $licChanged then .type = "license" | .proposedAction = "propose"
                  elif $collapseActive then .type = "collapse" | .proposedAction = "propose"
                  else . end)
              else . end)
           | .collapseStreak = $streak) as $nf
        | {finding:$nf,
           state:{stars:$cur, license:$lic, verdict:$f.verdict,
                  refStars:$newref, collapseStreak:$streak, lastSeen:$now}}'
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
NOW=$(curation_now)
targets=$(collect_targets)
n_targets=$(printf '%s' "$targets" | jq 'length')
n_watchlist=$(jq '.entries | length' "$AWAITING" 2>/dev/null || echo 0)

# Prior cross-run state (empty object on first ever run).
if [ -f "$STATE_FILE" ]; then
    OLD_STATE=$(cat "$STATE_FILE" 2>/dev/null)
    printf '%s' "$OLD_STATE" | jq -e . >/dev/null 2>&1 || OLD_STATE='{"subjects":{}}'
else
    OLD_STATE='{"subjects":{}}'
fi

# One pass over the targets; accumulate each finding + its new state entry.
findings_arr=()
state_arr=()
while IFS= read -r t; do
    [ -n "$t" ] || continue
    repo=$(printf '%s' "$t" | jq -r '.repoRoot')
    track=$(printf '%s' "$t" | jq -r '.track')
    pin=$(printf '%s' "$t" | jq -r '.pinnedRef')
    base=$(watch_one "$repo" "$track" "$pin")
    subject=$(printf '%s' "$base" | jq -r '.subject')
    verdict=$(printf '%s' "$base" | jq -r '.verdict')
    prior=$(printf '%s' "$OLD_STATE" | jq -c --arg s "$subject" '.subjects[$s] // null')
    if [ "$verdict" = "error" ]; then
        # No fresh observation this run — surface the error finding but PRESERVE
        # the subject's prior state (streak / reference must survive a transient
        # gh outage, else a flapping API would reset the sustained signal).
        findings_arr+=("$base")
        [ "$prior" != "null" ] && state_arr+=("$(jq -cn --arg s "$subject" --argjson v "$prior" '{subject:$s, state:$v}')")
        continue
    fi
    applied=$(apply_state "$base" "$prior")
    findings_arr+=("$(printf '%s' "$applied" | jq -c '.finding')")
    state_arr+=("$(printf '%s' "$applied" | jq -c --arg s "$subject" '{subject:$s, state:.state}')")
done < <(printf '%s' "$targets" | jq -c '.[]')

# Watch-list license-note consistency check (stateless, no cross-run folding).
# Appended after the scored targets so its findings land in the same digest.
while IFS= read -r af; do
    [ -n "$af" ] || continue
    findings_arr+=("$af")
done < <(watch_awaiting_licenses)

if [ "${#findings_arr[@]}" -gt 0 ]; then
    findings=$(printf '%s\n' "${findings_arr[@]}" | jq -s '.')
else
    findings='[]'
fi

# Rebuild the state object from THIS run's subjects (prunes vanished targets).
if [ "${#state_arr[@]}" -gt 0 ]; then
    new_subjects=$(printf '%s\n' "${state_arr[@]}" | jq -s 'map({(.subject): .state}) | add // {}')
else
    new_subjects='{}'
fi
new_state=$(jq -cn --arg now "$NOW" --argjson subj "$new_subjects" \
    '{version:"1.0.0", updatedAt:$now, subjects:$subj}')

# Counts by type. Only actionable findings (rot / drift / error) are SURFACED to
# the operator; "clean" and standing "flag" conditions are counted but not
# re-alarmed each run (no-noise contract).
counts=$(printf '%s' "$findings" | jq -c 'group_by(.type) | map({(.[0].type): length}) | add // {}')
surfaced=$(printf '%s' "$findings" | jq -c '[.[] | select(.type == "rot" or .type == "drift" or .type == "error" or .type == "collapse" or .type == "license" or .type == "license-note")]')
n_surfaced=$(printf '%s' "$surfaced" | jq 'length')

digest=$(jq -cn \
    --arg generatedAt "$NOW" --argjson targets "$n_targets" \
    --argjson watchlist "${n_watchlist:-0}" \
    --argjson counts "$counts" --argjson findings "$surfaced" \
    '{generatedAt:$generatedAt, scope:{targets:$targets, watchlist:$watchlist},
      counts:$counts, findingCount:($findings|length), findings:$findings}')

# The #458 open-PR lock, as reported by emit_repin_pr (empty when the lock was
# not consulted: no --emit-pr, --dry-run, or no re-pin finding to emit).
REPIN_LOCK=""

# render_lock_notice — say, in the digest itself, that the re-pin emission was
# locked out. Without it the table's `re-pin` rows read as actions being taken
# while nothing is being opened: the lock once held for 7 nights on a single
# unreviewed draft and every digest of that week looked like a normal night.
# Past LOCK_STALE_DAYS the note becomes a warning; an unknown age (an undatable
# createdAt) escalates too rather than passing for fresh.
render_lock_notice() {
    [ -n "$REPIN_LOCK" ] || return 0
    local num age url count
    num=$(printf '%s' "$REPIN_LOCK" | jq -r '.number // "?"')
    age=$(printf '%s' "$REPIN_LOCK" | jq -r '.ageDays // "?"')
    url=$(printf '%s' "$REPIN_LOCK" | jq -r '.url // empty')
    count=$(printf '%s' "$REPIN_LOCK" | jq -r '.count // 1')
    local ref="#$num"; [ -n "$url" ] && ref="[#$num]($url)"
    local unit="days"; [ "$age" = "1" ] && unit="day"
    if _lock_is_stale; then
        printf '> ⚠️ **Re-pin emission has been locked for %s %s** by %s.\n' "$age" "$unit" "$ref"
        printf '> No re-pin PR can be opened until it is merged or closed, so the drift below keeps accumulating.\n\n'
    else
        printf -- '- Re-pin emission is **locked** by %s (open %s %s): the `re-pin` rows below are proposals, not opened PRs.\n\n' \
            "$ref" "$age" "$unit"
    fi
    [ "$count" -gt 1 ] 2>/dev/null && printf -- '- %s open re-pin PRs hold the lock; the oldest is shown.\n\n' "$count"
    return 0
}

# _lock_is_stale — true when the lock has been held at least LOCK_STALE_DAYS, or
# when its age could not be determined (fail toward escalation: an unknown age
# must never read as "opened today").
_lock_is_stale() {
    [ -n "$REPIN_LOCK" ] || return 1
    local age; age=$(printf '%s' "$REPIN_LOCK" | jq -r '.ageDays // empty')
    case "$age" in
        ''|*[!0-9]*) return 0 ;;
        *) [ "$age" -ge "$LOCK_STALE_DAYS" ] ;;
    esac
}

# render_markdown — the human-readable digest (also the issue body). Defined here
# so the emission step below can reuse it before the file-persistence step runs.
render_markdown() {
    printf '# Curation digest — %s\n\n' "$NOW"
    printf -- '- Targets scored: **%s**\n- Findings: **%s**\n\n' "$n_targets" "$n_surfaced"
    render_lock_notice
    if [ "$n_surfaced" -eq 0 ]; then
        printf 'No rot or drift detected. lastVerified refreshed.\n'
        return
    fi
    printf '| Subject | For | Type | Verdict | Pinned | Current | Action |\n'
    printf '|---|---|---|---|---|---|---|\n'
    printf '%s' "$surfaced" | jq -r 'def esc: tostring | gsub("\\|"; "\\|");
        .[] |
        "| \(.subject|esc) | \((.forSkills // "—")|esc) | \(.type|esc) | \(.verdict|esc) | \(.pinnedRef|esc) | \((.currentRef // "?")|esc) | \(.proposedAction|esc) |"'
}

# OPT-IN gh emission (Slice 3b). Runs BEFORE the file-persistence step so the
# re-pin PR sees a CLEAN working tree (the lastVerified / state writes below
# would otherwise dirty it). Both paths are no-ops unless their flag is set and
# fully fail-safe. Skipped entirely under --dry-run (no outbound mutation).
if [ "$DRY_RUN" = false ]; then
    if [ "$EMIT_PR" = true ]; then
        repin_summary=$(emit_repin_pr "$surfaced" "$REGISTRY" "$PRESETS_DIR" "$PR_DRAFT" "$NOW")
        n_drafted=$(printf '%s' "$repin_summary" | jq -r '.drafted | length' 2>/dev/null || echo 0)
        [ "${n_drafted:-0}" -gt 0 ] && echo "[OK] re-pin draft PR: $n_drafted skill(s)" >&2
        REPIN_LOCK=$(printf '%s' "$repin_summary" | jq -c '.lock // empty' 2>/dev/null) || REPIN_LOCK=""
        # Escalate on stderr as well: the box's journal is the ops channel, and a
        # lock silently starving the auto-heal must be greppable there.
        if _lock_is_stale; then
            curation_warn "re-pin lock is STALE: PR #$(printf '%s' "$REPIN_LOCK" | jq -r '.number // "?"') has held it for $(printf '%s' "$REPIN_LOCK" | jq -r '.ageDays // "?"') day(s) — merge or close it to release the auto-heal"
        fi
    fi
    if [ "$EMIT_ISSUE" = true ] && [ "$n_surfaced" -gt 0 ]; then
        issue_body=$(mktemp 2>/dev/null)
        render_markdown > "$issue_body"
        emit_issue "Curation digest — $NOW" "$issue_body" "watch-digest"
        rm -f "$issue_body"
    fi
elif [ "$EMIT_PR" = true ] \
    && [ "$(printf '%s' "$surfaced" | jq '[.[] | select(.proposedAction == "re-pin")] | length')" -gt 0 ]; then
    # --dry-run still CONSULTS the lock (a `gh pr list` READ, never a mutation).
    # Without this, the one command a maintainer runs to inspect a suspicious
    # digest by hand returns exactly the digest that hid the lock in the first
    # place. Gated on --emit-pr and on there being a re-pin to be locked out of,
    # so an observe-only or quiet preview spends no extra call.
    REPIN_LOCK=$(curation_repin_lock) || REPIN_LOCK=""
fi

# Record the lock in the machine-readable digest too, so a consumer can alert on
# it without parsing the markdown. Absent entirely on an unlocked night.
#
# The merged value is assigned ONLY on success. Written as `digest=$(…) || :`
# the assignment lands FIRST and the `|| :` only swallows the status afterwards,
# so a jq failure would blank the whole digest — a guard that destroys exactly
# what it protects. CURATION_LOCK_MERGE_FILTER is a test seam for that path.
if [ -n "$REPIN_LOCK" ]; then
    lock_stale=false
    _lock_is_stale && lock_stale=true
    # The default is built on its own line: a `}` inside a ${VAR:-default} word
    # closes the expansion early, which would hand jq a truncated program.
    lock_filter="${CURATION_LOCK_MERGE_FILTER:-}"
    [ -n "$lock_filter" ] || lock_filter='.repinLock = ($l + {stale:$s})'
    merged=$(printf '%s' "$digest" | jq -c --argjson l "$REPIN_LOCK" --argjson s "$lock_stale" \
        "$lock_filter" 2>/dev/null) \
        && [ -n "$merged" ] && digest="$merged"
fi

# Idempotent lastVerified update — only records whose repo was ACTUALLY verified
# this run (verdict != error) are stamped; a gh-errored target keeps its old
# date so "verified" never lies about a repo we could not reach. The temp file
# is created in the registry's own directory so the mv is an atomic same-fs
# rename. Skipped under --dry-run.
if [ "$DRY_RUN" = false ]; then
    scored_ok=$(printf '%s' "$findings" | jq -c '[.[] | select(.verdict != "error") | .subject] | unique')
    reg_dir=$(dirname "$REGISTRY")
    if tmp=$(mktemp "$reg_dir/.registry.XXXXXX" 2>/dev/null) \
        && jq --arg now "$NOW" --argjson ok "$scored_ok" \
            '.records |= map(if (.vendorId | split("/")[0:2] | join("/")) as $r | ($ok | index($r)) then .lastVerified = $now else . end)' \
            "$REGISTRY" > "$tmp" 2>/dev/null \
        && mv "$tmp" "$REGISTRY"; then
        :
    else
        [ -n "${tmp:-}" ] && rm -f "$tmp"
        curation_warn "could not update lastVerified in $REGISTRY"
    fi

    # Persist the cross-run state (atomic same-fs rename). Skipped under
    # --dry-run so a dry run never advances the sustained-collapse counters.
    state_dir=$(dirname "$STATE_FILE")
    if tmp=$(mktemp "$state_dir/.watch-state.XXXXXX" 2>/dev/null) \
        && printf '%s\n' "$new_state" > "$tmp" \
        && mv "$tmp" "$STATE_FILE"; then
        :
    else
        [ -n "${tmp:-}" ] && rm -f "$tmp"
        curation_warn "could not update state file $STATE_FILE"
    fi
fi

# Emit the digest. Markdown form when a digest dir is given; JSON always.
if [ -n "$DIGEST_DIR" ]; then
    mkdir -p "$DIGEST_DIR"
    printf '%s\n' "$digest" > "$DIGEST_DIR/digest.json"
    render_markdown > "$DIGEST_DIR/digest.md"
    echo "[OK] digest written: $DIGEST_DIR/digest.json (+ digest.md) — $n_surfaced finding(s)"
else
    printf '%s\n' "$digest"
fi

exit 0
