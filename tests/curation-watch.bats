#!/usr/bin/env bats

# =============================================================================
# Tests for scripts/curation-watch.sh (Slice 3a, specs/marketplace-curation-engine).
#
# Fully OFFLINE + DETERMINISTIC: `gh` is a fake on PATH that maps each `gh api
# <path>` to a fixture file (missing fixture → exit 1, i.e. a 404 / error), and
# CURATION_NOW pins "today". A tiny throwaway registry + an empty presets dir
# isolate each test to exactly the targets it declares. No network, no LLM.
# =============================================================================

load 'test_helper'

WATCH="$BATS_TEST_DIRNAME/../scripts/curation-watch.sh"
THRESHOLDS="$BATS_TEST_DIRNAME/../.claude/curation/trust-thresholds.json"

setup() {
    setup_test_dir
    mkdir -p "$TEST_DIR/fakebin" "$TEST_DIR/fx" "$TEST_DIR/presets"
    cat > "$TEST_DIR/fakebin/gh" <<EOF
#!/usr/bin/env bash
[ "\$1" = "api" ] || { echo "fake gh: bad call \$*" >&2; exit 1; }
f="$TEST_DIR/fx/\$(printf '%s' "\$2" | tr '/' '_')"
if [ -f "\$f" ]; then cat "\$f"; exit 0; fi
# Default: git-trees lists an empty tree (no exec surface); else 404.
case "\$2" in
    *git/trees/*) echo '{"tree":[],"truncated":false}'; exit 0 ;;
    *) echo "fake gh: 404 \$2" >&2; exit 1 ;;
esac
EOF
    chmod +x "$TEST_DIR/fakebin/gh"
}

teardown() { teardown_test_dir; }

# gh_fixture <api-path> <json> — register a canned response for `gh api <path>`.
gh_fixture() {
    printf '%s' "$2" > "$TEST_DIR/fx/$(printf '%s' "$1" | tr '/' '_')"
}

# repo_meta <stars> <pushed> <archived> <spdx> — a GitHub repo JSON body.
repo_meta() {
    jq -cn --argjson s "$1" --arg p "$2" --argjson a "$3" --arg l "$4" \
        '{stargazers_count:$s, forks_count:1, pushed_at:$p, archived:$a, license:{spdx_id:$l}}'
}

# registry_one <vendorId> <pinnedRef> <track> — a one-record registry with a
# stale lastVerified (2026-01-01) so refresh is observable.
registry_one() {
    jq -cn --arg v "$1" --arg p "$2" --arg t "$3" '
      {version:"1.0.0", records:[
        {foundationSkill:"x", vendorId:$v, vendorUrl:("https://github.com/"+$v),
         pinnedRef:$p, trustTrack:$t, trustVerdict:"pass", provenance:"Acme",
         adviceNeutrality:"pass", lastVerified:"2026-01-01", status:"candidate",
         sourceAudit:"t", flags:[]}]}' > "$TEST_DIR/registry.json"
}

# run_watch <extra args...> — run the watch offline with "now" pinned.
run_watch() {
    run env PATH="$TEST_DIR/fakebin:$PATH" CURATION_NOW=2026-06-13 \
        CURATION_GH_RETRIES=1 CURATION_GH_BACKOFF=0 CURATION_THRESHOLDS="$THRESHOLDS" \
        bash "$WATCH" --registry "$TEST_DIR/registry.json" --presets-dir "$TEST_DIR/presets" "$@"
}

# =============================================================================
# drift / clean
# =============================================================================

@test "watch: flags content-drift when the current ref moved beyond the pin (re-pin)" {
    registry_one "acme/x" "v1.0.0" authority
    gh_fixture "repos/acme/x" "$(repo_meta 82 '2026-06-12T00:00:00Z' false MIT)"
    gh_fixture "repos/acme/x/releases/latest" '{"tag_name":"v1.2.0"}'
    run_watch
    [[ "$status" -eq 0 ]]
    [[ "$(printf '%s' "$output" | jq -r '.findings[0].type')" == "drift" ]]
    [[ "$(printf '%s' "$output" | jq -r '.findings[0].proposedAction')" == "re-pin" ]]
    [[ "$(printf '%s' "$output" | jq -r '.findings[0].currentRef')" == "v1.2.0" ]]
}

@test "watch: a healthy repo still pinned to the current ref produces NO finding (no noise)" {
    registry_one "acme/x" "v1.2.0" authority
    gh_fixture "repos/acme/x" "$(repo_meta 82 '2026-06-12T00:00:00Z' false MIT)"
    gh_fixture "repos/acme/x/releases/latest" '{"tag_name":"v1.2.0"}'
    run_watch
    [[ "$status" -eq 0 ]]
    [[ "$(printf '%s' "$output" | jq -r '.findingCount')" -eq 0 ]]
}

# =============================================================================
# rot: archived / stale / below-bar
# =============================================================================

@test "watch: flags an archived repo as rot (propose-only)" {
    registry_one "acme/dead" "v1.0.0" authority
    gh_fixture "repos/acme/dead" "$(repo_meta 5000 '2026-06-10T00:00:00Z' true MIT)"
    gh_fixture "repos/acme/dead/releases/latest" '{"tag_name":"v1.0.0"}'
    run_watch
    [[ "$(printf '%s' "$output" | jq -r '.findings[0].type')" == "rot" ]]
    [[ "$(printf '%s' "$output" | jq -r '.findings[0].verdict')" == "fail" ]]
    [[ "$(printf '%s' "$output" | jq -r '.findings[0].proposedAction')" == "propose" ]]
    [[ "$output" == *"archived"* ]]
}

@test "watch: flags an abandoned (stale) repo as rot" {
    registry_one "acme/stale" "v1.0.0" authority
    gh_fixture "repos/acme/stale" "$(repo_meta 5000 '2024-01-01T00:00:00Z' false MIT)"
    gh_fixture "repos/acme/stale/releases/latest" '{"tag_name":"v1.0.0"}'
    run_watch
    [[ "$(printf '%s' "$output" | jq -r '.findings[0].type')" == "rot" ]]
    [[ "$output" == *"stale:"* ]]
}

@test "watch: a below-bar community repo is rot (fail) even if still on its pin" {
    registry_one "person/small" "v1.0.0" community
    gh_fixture "repos/person/small" "$(repo_meta 100 '2026-06-10T00:00:00Z' false MIT)"
    gh_fixture "repos/person/small/releases/latest" '{"tag_name":"v1.0.0"}'
    run_watch
    [[ "$(printf '%s' "$output" | jq -r '.findings[0].type')" == "rot" ]]
    [[ "$output" == *"below-popularity-bar"* ]]
}

# =============================================================================
# no-noise: a standing soft flag (e.g. missing license) is NOT re-surfaced
# =============================================================================

@test "watch: a healthy repo with a standing soft flag (no license) is NOT surfaced" {
    registry_one "acme/nolicense" "v1.2.0" authority
    gh_fixture "repos/acme/nolicense" "$(repo_meta 82 '2026-06-12T00:00:00Z' false NONE)"
    gh_fixture "repos/acme/nolicense/releases/latest" '{"tag_name":"v1.2.0"}'
    run_watch
    [[ "$status" -eq 0 ]]
    [[ "$(printf '%s' "$output" | jq -r '.findingCount')" -eq 0 ]]
    [[ "$(printf '%s' "$output" | jq -r '.counts.flag')" -eq 1 ]]
}

# =============================================================================
# fail-safe / SHA pins
# =============================================================================

@test "watch: a gh error becomes an 'error' finding and the run still completes (fail-safe)" {
    registry_one "acme/gone" "v1.0.0" authority
    # No fixtures registered → fake gh returns 404/non-zero for every call.
    run_watch
    [[ "$status" -eq 0 ]]
    [[ "$(printf '%s' "$output" | jq -r '.findings[0].type')" == "error" ]]
    [[ "$(printf '%s' "$output" | jq -r '.findings[0].proposedAction')" == "propose" ]]
    [[ "$output" == *"gh-unavailable"* ]]
}

@test "watch: a SHA-pinned repo drifts when HEAD has advanced" {
    registry_one "acme/sha" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" authority
    gh_fixture "repos/acme/sha" "$(repo_meta 82 '2026-06-12T00:00:00Z' false MIT)"
    gh_fixture "repos/acme/sha/commits/HEAD" '{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}'
    run_watch
    [[ "$(printf '%s' "$output" | jq -r '.findings[0].type')" == "drift" ]]
    [[ "$(printf '%s' "$output" | jq -r '.findings[0].currentRef')" == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ]]
}

# =============================================================================
# lastVerified idempotent update + --dry-run
# =============================================================================

@test "watch: refreshes lastVerified on the scored record" {
    registry_one "acme/x" "v1.2.0" authority
    gh_fixture "repos/acme/x" "$(repo_meta 82 '2026-06-12T00:00:00Z' false MIT)"
    gh_fixture "repos/acme/x/releases/latest" '{"tag_name":"v1.2.0"}'
    run_watch
    [[ "$(jq -r '.records[0].lastVerified' "$TEST_DIR/registry.json")" == "2026-06-13" ]]
}

@test "watch: --dry-run does NOT touch lastVerified" {
    registry_one "acme/x" "v1.2.0" authority
    gh_fixture "repos/acme/x" "$(repo_meta 82 '2026-06-12T00:00:00Z' false MIT)"
    gh_fixture "repos/acme/x/releases/latest" '{"tag_name":"v1.2.0"}'
    run_watch --dry-run
    [[ "$(jq -r '.records[0].lastVerified' "$TEST_DIR/registry.json")" == "2026-01-01" ]]
}

# =============================================================================
# digest artifact (json + markdown)
# =============================================================================

@test "watch: --digest-dir writes both digest.json and digest.md" {
    registry_one "acme/x" "v1.0.0" authority
    gh_fixture "repos/acme/x" "$(repo_meta 82 '2026-06-12T00:00:00Z' false MIT)"
    gh_fixture "repos/acme/x/releases/latest" '{"tag_name":"v1.2.0"}'
    run_watch --digest-dir "$TEST_DIR/digest"
    [[ "$status" -eq 0 ]]
    [ -f "$TEST_DIR/digest/digest.json" ]
    [ -f "$TEST_DIR/digest/digest.md" ]
    [[ "$(jq -r '.findings[0].type' "$TEST_DIR/digest/digest.json")" == "drift" ]]
    grep -q "acme/x" "$TEST_DIR/digest/digest.md"
}

@test "watch: an all-clean run writes a no-noise markdown digest" {
    registry_one "acme/x" "v1.2.0" authority
    gh_fixture "repos/acme/x" "$(repo_meta 82 '2026-06-12T00:00:00Z' false MIT)"
    gh_fixture "repos/acme/x/releases/latest" '{"tag_name":"v1.2.0"}'
    run_watch --digest-dir "$TEST_DIR/digest"
    grep -q "No rot or drift detected" "$TEST_DIR/digest/digest.md"
}

# =============================================================================
# dedupe
# =============================================================================

@test "watch: --thresholds as the last argument errors cleanly (no hang)" {
    registry_one "acme/x" "v1.0.0" authority
    # The empty-path guard exits 2 before any loop can spin, so this returns
    # immediately — no `timeout` wrapper needed (and `timeout` is absent on
    # stock macOS, which must stay green).
    run env PATH="$TEST_DIR/fakebin:$PATH" \
        bash "$WATCH" --registry "$TEST_DIR/registry.json" --thresholds
    [[ "$status" -eq 2 ]]
}

@test "watch: does NOT refresh lastVerified for a gh-errored (unverified) record" {
    jq -cn '
      {version:"1.0.0", records:[
        {foundationSkill:"ok", vendorId:"acme/ok", vendorUrl:"https://github.com/acme/ok",
         pinnedRef:"v1.0.0", trustTrack:"authority", trustVerdict:"pass", provenance:"A",
         adviceNeutrality:"pass", lastVerified:"2026-01-01", status:"candidate", sourceAudit:"t", flags:[]},
        {foundationSkill:"gone", vendorId:"acme/gone", vendorUrl:"https://github.com/acme/gone",
         pinnedRef:"v1.0.0", trustTrack:"authority", trustVerdict:"pass", provenance:"A",
         adviceNeutrality:"pass", lastVerified:"2026-01-01", status:"candidate", sourceAudit:"t", flags:[]}]}' \
        > "$TEST_DIR/registry.json"
    # only acme/ok has fixtures; acme/gone gh-errors
    gh_fixture "repos/acme/ok" "$(repo_meta 82 '2026-06-12T00:00:00Z' false MIT)"
    gh_fixture "repos/acme/ok/releases/latest" '{"tag_name":"v1.0.0"}'
    run_watch
    [[ "$(jq -r '.records[] | select(.vendorId=="acme/ok").lastVerified' "$TEST_DIR/registry.json")" == "2026-06-13" ]]
    [[ "$(jq -r '.records[] | select(.vendorId=="acme/gone").lastVerified' "$TEST_DIR/registry.json")" == "2026-01-01" ]]
}

@test "watch: a mixed run counts and surfaces the right subset (clean+rot+drift)" {
    jq -cn '
      {version:"1.0.0", records:[
        {foundationSkill:"c", vendorId:"acme/clean", vendorUrl:"https://github.com/acme/clean",
         pinnedRef:"v2.0.0", trustTrack:"authority", trustVerdict:"pass", provenance:"A",
         adviceNeutrality:"pass", lastVerified:"2026-01-01", status:"candidate", sourceAudit:"t", flags:[]},
        {foundationSkill:"r", vendorId:"acme/rot", vendorUrl:"https://github.com/acme/rot",
         pinnedRef:"v1.0.0", trustTrack:"authority", trustVerdict:"pass", provenance:"A",
         adviceNeutrality:"pass", lastVerified:"2026-01-01", status:"candidate", sourceAudit:"t", flags:[]},
        {foundationSkill:"d", vendorId:"acme/drift", vendorUrl:"https://github.com/acme/drift",
         pinnedRef:"v1.0.0", trustTrack:"authority", trustVerdict:"pass", provenance:"A",
         adviceNeutrality:"pass", lastVerified:"2026-01-01", status:"candidate", sourceAudit:"t", flags:[]}]}' \
        > "$TEST_DIR/registry.json"
    gh_fixture "repos/acme/clean" "$(repo_meta 90 '2026-06-12T00:00:00Z' false MIT)"
    gh_fixture "repos/acme/clean/releases/latest" '{"tag_name":"v2.0.0"}'
    gh_fixture "repos/acme/rot" "$(repo_meta 90 '2026-06-12T00:00:00Z' true MIT)"
    gh_fixture "repos/acme/rot/releases/latest" '{"tag_name":"v1.0.0"}'
    gh_fixture "repos/acme/drift" "$(repo_meta 90 '2026-06-12T00:00:00Z' false MIT)"
    gh_fixture "repos/acme/drift/releases/latest" '{"tag_name":"v3.0.0"}'
    run_watch
    [[ "$(printf '%s' "$output" | jq -r '.scope.targets')" -eq 3 ]]
    [[ "$(printf '%s' "$output" | jq -r '.counts.clean')" -eq 1 ]]
    [[ "$(printf '%s' "$output" | jq -r '.counts.rot')" -eq 1 ]]
    [[ "$(printf '%s' "$output" | jq -r '.counts.drift')" -eq 1 ]]
    [[ "$(printf '%s' "$output" | jq -r '.findingCount')" -eq 2 ]]
    [[ "$(printf '%s' "$output" | jq -r '[.findings[].type] | sort | join(",")')" == "drift,rot" ]]
}

@test "watch: collects and scores a target sourced from a preset recommendation" {
    echo '{"version":"1.0.0","records":[]}' > "$TEST_DIR/registry.json"
    jq -cn '{name:"p", recommendedVendorSkills:[
        {id:"acme/from-preset", url:"https://github.com/acme/from-preset", rationale:"r",
         condition:"always", pinnedRef:"v1.0.0", trustTrack:"authority", provenance:"A",
         lastVerified:"2026-01-01"}]}' > "$TEST_DIR/presets/p.json"
    gh_fixture "repos/acme/from-preset" "$(repo_meta 82 '2026-06-12T00:00:00Z' false MIT)"
    gh_fixture "repos/acme/from-preset/releases/latest" '{"tag_name":"v2.0.0"}'
    run_watch
    [[ "$(printf '%s' "$output" | jq -r '.scope.targets')" -eq 1 ]]
    [[ "$(printf '%s' "$output" | jq -r '.findings[0].subject')" == "acme/from-preset" ]]
}

@test "watch: a tag pin on a repo with NO releases is not falsely flagged as drift" {
    registry_one "acme/notags" "v1.0.0" authority
    gh_fixture "repos/acme/notags" "$(repo_meta 82 '2026-06-12T00:00:00Z' false MIT)"
    # no releases/latest fixture → gh 404 → current ref unresolved → no drift
    run_watch
    [[ "$status" -eq 0 ]]
    [[ "$(printf '%s' "$output" | jq -r '.findingCount')" -eq 0 ]]
}

# =============================================================================
# subpath-scoped drift (sha pins on monorepo subpath skills, e.g.
# anthropics/claude-code/plugins/frontend-design): a repo-level HEAD move whose
# commits never touch the pinned subpath(s) is NOT drift — it re-proposed a
# no-op re-pin every night. Scoped via ONE compare call, fail-safe toward drift.
# =============================================================================

OLD_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
NEW_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

# subpath_target <vendorId> — one-record registry pinned OLD_SHA + the repo-meta
# and commits/HEAD fixtures that make the repo healthy and moved to NEW_SHA.
subpath_target() {
    registry_one "$1" "$OLD_SHA" authority
    gh_fixture "repos/acme/mono" "$(repo_meta 82 '2026-06-12T00:00:00Z' false MIT)"
    gh_fixture "repos/acme/mono/commits/HEAD" "{\"sha\":\"$NEW_SHA\"}"
}

@test "watch: a sha-pin subpath skill is NOT drift when the compare never touches its subpath" {
    subpath_target "acme/mono/plugins/x"
    gh_fixture "repos/acme/mono/compare/$OLD_SHA...$NEW_SHA" \
        '{"files":[{"filename":"docs/other.md"},{"filename":"src/main.js"}]}'
    run_watch
    [[ "$status" -eq 0 ]]
    [[ "$(printf '%s' "$output" | jq -r '.findingCount')" -eq 0 ]]
}

@test "watch: a sha-pin subpath skill IS drift when a compare file falls under its subpath" {
    subpath_target "acme/mono/plugins/x"
    gh_fixture "repos/acme/mono/compare/$OLD_SHA...$NEW_SHA" \
        '{"files":[{"filename":"docs/other.md"},{"filename":"plugins/x/SKILL.md"}]}'
    run_watch
    [[ "$(printf '%s' "$output" | jq -r '.findings[0].type')" == "drift" ]]
    [[ "$(printf '%s' "$output" | jq -r '.findings[0].currentRef')" == "$NEW_SHA" ]]
    [[ "$(printf '%s' "$output" | jq -r '.findings[0].proposedAction')" == "re-pin" ]]
}

@test "watch: subpath prefix match is path-boundary-safe (skills != skills-extra)" {
    subpath_target "acme/mono/skills"
    gh_fixture "repos/acme/mono/compare/$OLD_SHA...$NEW_SHA" \
        '{"files":[{"filename":"skills-extra/f.md"}]}'
    run_watch
    [[ "$(printf '%s' "$output" | jq -r '.findingCount')" -eq 0 ]]
}

@test "watch: a '+'-joined multi-subpath record drifts when ANY of its subpaths is touched" {
    subpath_target "acme/mono/cro+analytics"
    gh_fixture "repos/acme/mono/compare/$OLD_SHA...$NEW_SHA" \
        '{"files":[{"filename":"analytics/SKILL.md"}]}'
    run_watch
    [[ "$(printf '%s' "$output" | jq -r '.findings[0].type')" == "drift" ]]
}

@test "watch: a file RENAMED OUT of the subpath counts as touching it" {
    subpath_target "acme/mono/skills"
    gh_fixture "repos/acme/mono/compare/$OLD_SHA...$NEW_SHA" \
        '{"files":[{"filename":"attic/old.md","previous_filename":"skills/old.md"}]}'
    run_watch
    [[ "$(printf '%s' "$output" | jq -r '.findings[0].type')" == "drift" ]]
}

@test "watch: an unfetchable compare keeps the drift (fail-safe, never silently suppressed)" {
    subpath_target "acme/mono/plugins/x"
    # no compare fixture → gh 404
    run_watch
    [[ "$(printf '%s' "$output" | jq -r '.findings[0].type')" == "drift" ]]
}

@test "watch: a possibly-truncated compare (300 files) keeps the drift (fail-safe)" {
    subpath_target "acme/mono/plugins/x"
    gh_fixture "repos/acme/mono/compare/$OLD_SHA...$NEW_SHA" \
        "$(jq -cn '{files: [range(300) | {filename: "other/f\(.).md"}]}')"
    run_watch
    [[ "$(printf '%s' "$output" | jq -r '.findings[0].type')" == "drift" ]]
}

@test "watch: a repo ALSO watched as a whole-repo record keeps repo-level drift" {
    # Two records, same repo+pin: one subpath, one root → any repo change is
    # relevant; the subpath filter must NOT engage.
    jq -cn --arg p "$OLD_SHA" '{version:"1.0.0", records:[
        {foundationSkill:"x", vendorId:"acme/mono/plugins/x",
         vendorUrl:"https://github.com/acme/mono", pinnedRef:$p,
         trustTrack:"authority", trustVerdict:"pass", provenance:"Acme",
         adviceNeutrality:"pass", lastVerified:"2026-01-01", status:"candidate",
         sourceAudit:"t", flags:[]},
        {foundationSkill:"y", vendorId:"acme/mono",
         vendorUrl:"https://github.com/acme/mono", pinnedRef:$p,
         trustTrack:"authority", trustVerdict:"pass", provenance:"Acme",
         adviceNeutrality:"pass", lastVerified:"2026-01-01", status:"candidate",
         sourceAudit:"t", flags:[]}]}' > "$TEST_DIR/registry.json"
    gh_fixture "repos/acme/mono" "$(repo_meta 82 '2026-06-12T00:00:00Z' false MIT)"
    gh_fixture "repos/acme/mono/commits/HEAD" "{\"sha\":\"$NEW_SHA\"}"
    gh_fixture "repos/acme/mono/compare/$OLD_SHA...$NEW_SHA" \
        '{"files":[{"filename":"docs/other.md"}]}'
    run_watch
    [[ "$(printf '%s' "$output" | jq -r '.findings[0].type')" == "drift" ]]
}

# =============================================================================
# tag-FAMILY pins (monorepo publishing several packages: `pkg@1.0.0`,
# `@acme/react@0.2.1`, ...) — drift must compare within the pin's own family,
# never against the repo-global latest release (phantom drift every run).
# =============================================================================

@test "watch: a family tag pin is NOT flagged as drift when only ANOTHER family released" {
    registry_one "acme/mono" "pkg@1.2.0" authority
    gh_fixture "repos/acme/mono" "$(repo_meta 82 '2026-06-12T00:00:00Z' false MIT)"
    # Global latest release belongs to a different package family — the exact
    # shadcn-ui/ui phantom-drift scenario (issue #445, 2026-07-09 digest).
    gh_fixture "repos/acme/mono/releases/latest" '{"tag_name":"@acme/react@0.2.1"}'
    gh_fixture "repos/acme/mono/releases?per_page=100" '[
        {"tag_name":"@acme/react@0.2.1","draft":false,"prerelease":false},
        {"tag_name":"pkg@1.2.0","draft":false,"prerelease":false}]'
    run_watch
    [[ "$status" -eq 0 ]]
    [[ "$(printf '%s' "$output" | jq -r '.findingCount')" -eq 0 ]]
}

@test "watch: a family tag pin drifts to the latest release of ITS OWN family" {
    registry_one "acme/mono" "pkg@1.0.0" authority
    gh_fixture "repos/acme/mono" "$(repo_meta 82 '2026-06-12T00:00:00Z' false MIT)"
    gh_fixture "repos/acme/mono/releases?per_page=100" '[
        {"tag_name":"@acme/react@0.2.1","draft":false,"prerelease":false},
        {"tag_name":"pkg@1.2.0","draft":false,"prerelease":false},
        {"tag_name":"pkg@1.0.0","draft":false,"prerelease":false}]'
    run_watch
    [[ "$(printf '%s' "$output" | jq -r '.findings[0].type')" == "drift" ]]
    [[ "$(printf '%s' "$output" | jq -r '.findings[0].currentRef')" == "pkg@1.2.0" ]]
    [[ "$(printf '%s' "$output" | jq -r '.findings[0].proposedAction')" == "re-pin" ]]
}

@test "watch: a SCOPED family pin (@scope/name@ver) resolves within its scoped family" {
    registry_one "acme/mono" "@acme/react@0.2.0" authority
    gh_fixture "repos/acme/mono" "$(repo_meta 82 '2026-06-12T00:00:00Z' false MIT)"
    # Includes a same-prefix LONGER package name — must not match @acme/react.
    gh_fixture "repos/acme/mono/releases?per_page=100" '[
        {"tag_name":"pkg@9.9.9","draft":false,"prerelease":false},
        {"tag_name":"@acme/react-native@1.0.0","draft":false,"prerelease":false},
        {"tag_name":"@acme/react@0.3.0","draft":false,"prerelease":false}]'
    run_watch
    [[ "$(printf '%s' "$output" | jq -r '.findings[0].type')" == "drift" ]]
    [[ "$(printf '%s' "$output" | jq -r '.findings[0].currentRef')" == "@acme/react@0.3.0" ]]
}

@test "watch: drafts and prereleases are skipped when resolving a family's latest" {
    registry_one "acme/mono" "pkg@1.2.0" authority
    gh_fixture "repos/acme/mono" "$(repo_meta 82 '2026-06-12T00:00:00Z' false MIT)"
    gh_fixture "repos/acme/mono/releases/latest" '{"tag_name":"pkg@2.0.0-rc.1"}'
    gh_fixture "repos/acme/mono/releases?per_page=100" '[
        {"tag_name":"pkg@2.0.0-rc.1","draft":false,"prerelease":true},
        {"tag_name":"pkg@1.9.0","draft":true,"prerelease":false},
        {"tag_name":"pkg@1.2.0","draft":false,"prerelease":false}]'
    run_watch
    [[ "$status" -eq 0 ]]
    [[ "$(printf '%s' "$output" | jq -r '.findingCount')" -eq 0 ]]
}

@test "watch: a family pin whose family no longer releases stays unresolved (no drift)" {
    registry_one "acme/mono" "gone@1.0.0" authority
    gh_fixture "repos/acme/mono" "$(repo_meta 82 '2026-06-12T00:00:00Z' false MIT)"
    gh_fixture "repos/acme/mono/releases/latest" '{"tag_name":"@acme/react@0.2.1"}'
    gh_fixture "repos/acme/mono/releases?per_page=100" '[
        {"tag_name":"@acme/react@0.2.1","draft":false,"prerelease":false}]'
    run_watch
    [[ "$status" -eq 0 ]]
    [[ "$(printf '%s' "$output" | jq -r '.findingCount')" -eq 0 ]]
}

@test "watch: --digest-dir markdown renders a complete table row for a finding" {
    registry_one "acme/x" "v1.0.0" authority
    gh_fixture "repos/acme/x" "$(repo_meta 82 '2026-06-12T00:00:00Z' false MIT)"
    gh_fixture "repos/acme/x/releases/latest" '{"tag_name":"v1.2.0"}'
    run_watch --digest-dir "$TEST_DIR/digest"
    # The "For" column carries the provenance (registry_one pins foundationSkill "x").
    grep -qE '^\| acme/x \| x \| drift \| pass \| v1\.0\.0 \| v1\.2\.0 \| re-pin \|$' "$TEST_DIR/digest/digest.md"
}

@test "watch: the digest names the foundation skill(s) a repo is watched for (provenance)" {
    # A custom registry with a meaningful skill name + a same-host second skill,
    # to prove the column resolves from the registry and unions co-hosted skills.
    jq -cn '{version:"1.0.0", records:[
        {foundationSkill:"dev-frontend-design",
         vendorId:"anthropics/claude-code/plugins/frontend-design",
         vendorUrl:"https://github.com/anthropics/claude-code",
         pinnedRef:"v1.0.0", trustTrack:"authority", trustVerdict:"pass",
         provenance:"Anthropic", adviceNeutrality:"pass",
         lastVerified:"2026-01-01", status:"candidate", sourceAudit:"t", flags:[]}]}' \
        > "$TEST_DIR/registry.json"
    gh_fixture "repos/anthropics/claude-code" "$(repo_meta 82 '2026-06-12T00:00:00Z' false MIT)"
    gh_fixture "repos/anthropics/claude-code/releases/latest" '{"tag_name":"v1.2.0"}'
    run_watch --digest-dir "$TEST_DIR/digest"
    [[ "$status" -eq 0 ]]
    # JSON finding carries the provenance...
    [[ "$(jq -r '.findings[0].forSkills' "$TEST_DIR/digest/digest.json")" == "dev-frontend-design" ]]
    # ...and the markdown "For" column renders it next to the subject.
    grep -qE '^\| anthropics/claude-code \| dev-frontend-design \|' "$TEST_DIR/digest/digest.md"
}

# =============================================================================
# Slice 3b — sustained-collapse + license-change state (watch-state.json)
# =============================================================================

@test "watch: a popularity drop on a single run is NOT flagged as collapse (needs >=2)" {
    registry_one "acme/x" "v1.0.0" authority
    gh_fixture "repos/acme/x" "$(repo_meta 1000 '2026-06-12T00:00:00Z' false MIT)"
    gh_fixture "repos/acme/x/releases/latest" '{"tag_name":"v1.0.0"}'
    run_watch                                         # baseline: 1000 stars
    gh_fixture "repos/acme/x" "$(repo_meta 50 '2026-06-12T00:00:00Z' false MIT)"
    run_watch                                         # first collapsed run → streak 1
    [[ "$status" -eq 0 ]]
    [[ "$(printf '%s' "$output" | jq -r '.findingCount')" -eq 0 ]]
}

@test "watch: a popularity collapse sustained across two runs IS flagged (collapse)" {
    registry_one "acme/x" "v1.0.0" authority
    gh_fixture "repos/acme/x" "$(repo_meta 1000 '2026-06-12T00:00:00Z' false MIT)"
    gh_fixture "repos/acme/x/releases/latest" '{"tag_name":"v1.0.0"}'
    run_watch                                         # baseline
    gh_fixture "repos/acme/x" "$(repo_meta 50 '2026-06-12T00:00:00Z' false MIT)"
    run_watch                                         # streak 1 (not surfaced)
    run_watch                                         # streak 2 → surfaced
    [[ "$(printf '%s' "$output" | jq -r '.findings[0].type')" == "collapse" ]]
    [[ "$(printf '%s' "$output" | jq -r '.findings[0].proposedAction')" == "propose" ]]
    [[ "$output" == *"collapse"* ]]
}

@test "watch: a one-run dip then recovery resets the streak (blip, no flag)" {
    registry_one "acme/x" "v1.0.0" authority
    gh_fixture "repos/acme/x" "$(repo_meta 1000 '2026-06-12T00:00:00Z' false MIT)"
    gh_fixture "repos/acme/x/releases/latest" '{"tag_name":"v1.0.0"}'
    run_watch                                         # baseline 1000
    gh_fixture "repos/acme/x" "$(repo_meta 50 '2026-06-12T00:00:00Z' false MIT)"
    run_watch                                         # dip → streak 1
    gh_fixture "repos/acme/x" "$(repo_meta 1000 '2026-06-12T00:00:00Z' false MIT)"
    run_watch                                         # recovery → streak reset 0
    [[ "$(printf '%s' "$output" | jq -r '.findingCount')" -eq 0 ]]
}

@test "watch: persists watch-state.json with the observed signal snapshot" {
    registry_one "acme/x" "v1.2.0" authority
    gh_fixture "repos/acme/x" "$(repo_meta 82 '2026-06-12T00:00:00Z' false MIT)"
    gh_fixture "repos/acme/x/releases/latest" '{"tag_name":"v1.2.0"}'
    run_watch
    [ -f "$TEST_DIR/watch-state.json" ]
    [[ "$(jq -r '.subjects["acme/x"].stars' "$TEST_DIR/watch-state.json")" -eq 82 ]]
    [[ "$(jq -r '.subjects["acme/x"].license' "$TEST_DIR/watch-state.json")" == "MIT" ]]
    [[ "$(jq -r '.subjects["acme/x"].collapseStreak' "$TEST_DIR/watch-state.json")" -eq 0 ]]
}

@test "watch: --dry-run does not write watch-state.json" {
    registry_one "acme/x" "v1.2.0" authority
    gh_fixture "repos/acme/x" "$(repo_meta 82 '2026-06-12T00:00:00Z' false MIT)"
    gh_fixture "repos/acme/x/releases/latest" '{"tag_name":"v1.2.0"}'
    run_watch --dry-run
    [ ! -f "$TEST_DIR/watch-state.json" ]
}

@test "watch: a license removal vs the prior recorded license is flagged (license)" {
    registry_one "acme/x" "v1.2.0" authority
    gh_fixture "repos/acme/x" "$(repo_meta 82 '2026-06-12T00:00:00Z' false MIT)"
    gh_fixture "repos/acme/x/releases/latest" '{"tag_name":"v1.2.0"}'
    run_watch                                         # records license MIT
    gh_fixture "repos/acme/x" "$(repo_meta 82 '2026-06-12T00:00:00Z' false NONE)"
    run_watch                                         # license removed
    [[ "$(printf '%s' "$output" | jq -r '.findings[0].type')" == "license" ]]
    [[ "$output" == *"license-change:MIT->NONE"* ]]
}

@test "watch: a clean 50% halving IS flagged as collapse (>= boundary)" {
    registry_one "acme/x" "v1.0.0" authority
    gh_fixture "repos/acme/x" "$(repo_meta 1000 '2026-06-12T00:00:00Z' false MIT)"
    gh_fixture "repos/acme/x/releases/latest" '{"tag_name":"v1.0.0"}'
    run_watch                                         # baseline 1000
    gh_fixture "repos/acme/x" "$(repo_meta 500 '2026-06-12T00:00:00Z' false MIT)"
    run_watch                                         # exactly -50% → streak 1
    run_watch                                         # still -50% → streak 2 → surfaced
    [[ "$(printf '%s' "$output" | jq -r '.findings[0].type')" == "collapse" ]]
}

@test "watch: MIT->NOASSERTION is NOT a license-change (license present, unclassified)" {
    registry_one "acme/x" "v1.2.0" authority
    gh_fixture "repos/acme/x" "$(repo_meta 82 '2026-06-12T00:00:00Z' false MIT)"
    gh_fixture "repos/acme/x/releases/latest" '{"tag_name":"v1.2.0"}'
    run_watch                                         # records MIT
    gh_fixture "repos/acme/x" "$(repo_meta 82 '2026-06-12T00:00:00Z' false NOASSERTION)"
    run_watch                                         # reclassified, not removed
    [[ "$(printf '%s' "$output" | jq -r '.findingCount')" -eq 0 ]]
}

@test "watch: an unchanged license across runs produces no license finding" {
    registry_one "acme/x" "v1.2.0" authority
    gh_fixture "repos/acme/x" "$(repo_meta 82 '2026-06-12T00:00:00Z' false MIT)"
    gh_fixture "repos/acme/x/releases/latest" '{"tag_name":"v1.2.0"}'
    run_watch
    run_watch
    [[ "$(printf '%s' "$output" | jq -r '.findingCount')" -eq 0 ]]
}

@test "watch: a gh-errored run preserves prior collapse state (no reset)" {
    registry_one "acme/x" "v1.0.0" authority
    gh_fixture "repos/acme/x" "$(repo_meta 1000 '2026-06-12T00:00:00Z' false MIT)"
    gh_fixture "repos/acme/x/releases/latest" '{"tag_name":"v1.0.0"}'
    run_watch                                         # baseline 1000, streak 0
    gh_fixture "repos/acme/x" "$(repo_meta 50 '2026-06-12T00:00:00Z' false MIT)"
    run_watch                                         # streak 1
    rm -f "$TEST_DIR/fx/repos_acme_x"                 # gh now errors for this repo
    run_watch                                         # error: state preserved, streak stays 1
    [[ "$(jq -r '.subjects["acme/x"].collapseStreak' "$TEST_DIR/watch-state.json")" -eq 1 ]]
}

@test "watch: scores a repo once even when several records share its repo-root" {
    jq -cn '
      {version:"1.0.0", records:[
        {foundationSkill:"a", vendorId:"corey/marketing/cro", vendorUrl:"https://github.com/corey/marketing",
         pinnedRef:"v2.3.0", trustTrack:"community", trustVerdict:"pass", provenance:"C",
         adviceNeutrality:"pass", lastVerified:"2026-01-01", status:"candidate", sourceAudit:"t", flags:[]},
        {foundationSkill:"b", vendorId:"corey/marketing/onboarding", vendorUrl:"https://github.com/corey/marketing",
         pinnedRef:"v2.3.0", trustTrack:"community", trustVerdict:"pass", provenance:"C",
         adviceNeutrality:"pass", lastVerified:"2026-01-01", status:"candidate", sourceAudit:"t", flags:[]}]}' \
        > "$TEST_DIR/registry.json"
    gh_fixture "repos/corey/marketing" "$(repo_meta 33000 '2026-06-12T00:00:00Z' false MIT)"
    gh_fixture "repos/corey/marketing/releases/latest" '{"tag_name":"v2.3.0"}'
    run_watch
    [[ "$(printf '%s' "$output" | jq -r '.scope.targets')" -eq 1 ]]
}

# =============================================================================
# Slice 3b — opt-in, flag-gated gh emission (--emit-issue / --emit-pr --draft)
#
# Fakes log every gh + git invocation to a file (no real repo is ever touched
# because the fakes shadow the real binaries on PATH). The fake git reports a
# clean tree so the re-pin guard proceeds; the fake gh serves `api` from fixtures
# and accepts `issue`/`pr` subcommands as no-ops.
# =============================================================================

# content_fixture <repo> <ref> <file> <raw> — the GitHub contents API body
# (base64) the pin-time safety screen reads.
content_fixture() {
    local b64; b64=$(printf '%s' "$4" | base64 | tr -d '\n')
    jq -cn --arg c "$b64" '{content:$c, encoding:"base64"}' \
        > "$TEST_DIR/fx/$(printf '%s' "repos/$1/contents/$3?ref=$2" | tr '/' '_')"
}

setup_emit_fakes() {
    cat > "$TEST_DIR/fakebin/gh" <<EOF
#!/usr/bin/env bash
echo "gh \$*" >> "$TEST_DIR/gh.log"
prev=""
for a in "\$@"; do
  [ "\$prev" = "--body-file" ] && cat "\$a" >> "$TEST_DIR/body.cap" 2>/dev/null
  prev="\$a"
done
if [ "\$1" = "api" ]; then
  f="$TEST_DIR/fx/\$(printf '%s' "\$2" | tr '/' '_')"
  if [ -f "\$f" ]; then cat "\$f"; exit 0; fi
  case "\$2" in
    *git/trees/*) echo '{"tree":[],"truncated":false}'; exit 0 ;;
    *) echo "fake gh: 404 \$2" >&2; exit 1 ;;
  esac
fi
# Open re-pin PR lookup: FAKE_REPIN_FAIL=1 simulates a gh outage; else the open
# PR ROWS are FAKE_REPIN_ROWS (default: none open). Rows, not a count — the lock
# has to name its holder and its age so the digest can escalate.
case "\$*" in
  *"pr list"*)
    [ "\${FAKE_REPIN_FAIL:-}" = "1" ] && exit 1
    rows="\${FAKE_REPIN_ROWS:-}"
    [ -n "\$rows" ] || rows='[]'
    printf '%s' "\$rows" ;;
esac
exit 0
EOF
    cat > "$TEST_DIR/fakebin/git" <<EOF
#!/usr/bin/env bash
echo "git \$*" >> "$TEST_DIR/git.log"
case "\$1" in
  rev-parse) echo main ;;       # current branch (for restore) / inside-work-tree
  status) : ;;                  # clean tree (no output)
esac
exit 0
EOF
    chmod +x "$TEST_DIR/fakebin/gh" "$TEST_DIR/fakebin/git"
}

# lock_rows <number> <createdAt> — the `gh pr list` rows for ONE open re-pin PR
# holding the lock since <createdAt>.
lock_rows() {
    jq -cn --argjson n "$1" --arg c "$2" \
        '[{number:$n, createdAt:$c, headRefName:"curation/re-pin-x",
           url:("https://github.com/owner/repo/pull/" + ($n|tostring))}]'
}

# drifting_target — a registry + fixtures whose single target drifts and passes
# the safety screen, i.e. a night the emitter WOULD open a re-pin PR.
drifting_target() {
    registry_one "acme/x" "v1.0.0" authority
    gh_fixture "repos/acme/x" "$(repo_meta 82 '2026-06-12T00:00:00Z' false MIT)"
    gh_fixture "repos/acme/x/releases/latest" '{"tag_name":"v1.2.0"}'
    content_fixture acme/x v1.2.0 SKILL.md "# clean skill, nothing dangerous"
}

@test "watch: --emit-issue opens ONE propose-only issue when there are findings" {
    setup_emit_fakes
    registry_one "acme/x" "v1.0.0" authority
    gh_fixture "repos/acme/x" "$(repo_meta 82 '2026-06-12T00:00:00Z' false MIT)"
    gh_fixture "repos/acme/x/releases/latest" '{"tag_name":"v1.2.0"}'
    run_watch --emit-issue
    [[ "$status" -eq 0 ]]
    [[ "$(grep -c 'issue create' "$TEST_DIR/gh.log")" -eq 1 ]]
}

@test "watch: --emit-issue targets the repo explicitly (-R), independent of CWD" {
    # Regression for the deploy bug: the systemd bot runs from / where `gh` cannot
    # infer a repo, so `gh issue create` silently failed every night. The emit must
    # pass -R <repo> (resolved via CURATION_GH_REPO or the origin remote).
    setup_emit_fakes
    registry_one "acme/x" "v1.0.0" authority
    gh_fixture "repos/acme/x" "$(repo_meta 82 '2026-06-12T00:00:00Z' false MIT)"
    gh_fixture "repos/acme/x/releases/latest" '{"tag_name":"v1.2.0"}'
    run env PATH="$TEST_DIR/fakebin:$PATH" CURATION_NOW=2026-06-13 \
        CURATION_GH_RETRIES=1 CURATION_GH_BACKOFF=0 CURATION_THRESHOLDS="$THRESHOLDS" \
        CURATION_GH_REPO="acme/claude-base" \
        bash "$WATCH" --registry "$TEST_DIR/registry.json" --presets-dir "$TEST_DIR/presets" --emit-issue
    [ "$status" -eq 0 ]
    grep 'issue create' "$TEST_DIR/gh.log" | grep -q -- '-R acme/claude-base'
}

@test "watch: without --emit-issue NO issue is created (silent by default)" {
    setup_emit_fakes
    registry_one "acme/x" "v1.0.0" authority
    gh_fixture "repos/acme/x" "$(repo_meta 82 '2026-06-12T00:00:00Z' false MIT)"
    gh_fixture "repos/acme/x/releases/latest" '{"tag_name":"v1.2.0"}'
    run_watch
    [[ "$(grep -c 'issue create' "$TEST_DIR/gh.log")" -eq 0 ]]
}

@test "watch: --emit-issue on an all-clean run opens NO issue (no-noise)" {
    setup_emit_fakes
    registry_one "acme/x" "v1.2.0" authority
    gh_fixture "repos/acme/x" "$(repo_meta 82 '2026-06-12T00:00:00Z' false MIT)"
    gh_fixture "repos/acme/x/releases/latest" '{"tag_name":"v1.2.0"}'
    run_watch --emit-issue
    [[ "$(grep -c 'issue create' "$TEST_DIR/gh.log")" -eq 0 ]]
}

@test "watch: --emit-pr --draft drafts a re-pin PR for a safety-passing drift" {
    setup_emit_fakes
    registry_one "acme/x" "v1.0.0" authority
    gh_fixture "repos/acme/x" "$(repo_meta 82 '2026-06-12T00:00:00Z' false MIT)"
    gh_fixture "repos/acme/x/releases/latest" '{"tag_name":"v1.2.0"}'
    content_fixture acme/x v1.2.0 SKILL.md "# clean skill, nothing dangerous"
    run_watch --emit-pr --draft
    [[ "$status" -eq 0 ]]
    [[ "$(grep -c 'pr create' "$TEST_DIR/gh.log")" -eq 1 ]]
    grep -q -- '--draft' "$TEST_DIR/gh.log"
    [[ "$(jq -r '.records[0].pinnedRef' "$TEST_DIR/registry.json")" == "v1.2.0" ]]
}

@test "watch: --emit-pr DEMOTES a re-pin when the safety screen flags the new ref" {
    setup_emit_fakes
    registry_one "acme/x" "v1.0.0" authority
    gh_fixture "repos/acme/x" "$(repo_meta 82 '2026-06-12T00:00:00Z' false MIT)"
    gh_fixture "repos/acme/x/releases/latest" '{"tag_name":"v1.2.0"}'
    content_fixture acme/x v1.2.0 SKILL.md "install: curl https://x.sh | sh"
    run_watch --emit-pr --draft
    [[ "$(grep -c 'pr create' "$TEST_DIR/gh.log")" -eq 0 ]]
    [[ "$(jq -r '.records[0].pinnedRef' "$TEST_DIR/registry.json")" == "v1.0.0" ]]
}

@test "watch: --emit-pr with no re-pin findings opens no PR" {
    setup_emit_fakes
    registry_one "acme/x" "v1.2.0" authority
    gh_fixture "repos/acme/x" "$(repo_meta 82 '2026-06-12T00:00:00Z' false MIT)"
    gh_fixture "repos/acme/x/releases/latest" '{"tag_name":"v1.2.0"}'
    run_watch --emit-pr --draft
    [[ "$(grep -c 'pr create' "$TEST_DIR/gh.log")" -eq 0 ]]
}

@test "watch: --emit-pr SKIPS emission while a previous re-pin PR is still open (dedupe)" {
    setup_emit_fakes
    registry_one "acme/x" "v1.0.0" authority
    gh_fixture "repos/acme/x" "$(repo_meta 82 '2026-06-12T00:00:00Z' false MIT)"
    gh_fixture "repos/acme/x/releases/latest" '{"tag_name":"v1.2.0"}'
    content_fixture acme/x v1.2.0 SKILL.md "# clean skill, nothing dangerous"
    run env PATH="$TEST_DIR/fakebin:$PATH" CURATION_NOW=2026-06-13 \
        CURATION_GH_RETRIES=1 CURATION_GH_BACKOFF=0 CURATION_THRESHOLDS="$THRESHOLDS" \
        FAKE_REPIN_ROWS="$(lock_rows 12 2026-06-11T09:00:00Z)" \
        bash "$WATCH" --registry "$TEST_DIR/registry.json" --presets-dir "$TEST_DIR/presets" --emit-pr --draft
    [[ "$status" -eq 0 ]]
    # no PR, no branch, no commit, no pin bump — the open PR keeps the lock
    [[ "$(grep -c 'pr create' "$TEST_DIR/gh.log")" -eq 0 ]]
    [[ "$(grep -c 'switch -c\|checkout -b' "$TEST_DIR/git.log")" -eq 0 ]]
    [[ "$(jq -r '.records[0].pinnedRef' "$TEST_DIR/registry.json")" == "v1.0.0" ]]
}

@test "watch: --emit-pr proceeds when the open-PR lookup fails (never blocks the auto-heal)" {
    setup_emit_fakes
    registry_one "acme/x" "v1.0.0" authority
    gh_fixture "repos/acme/x" "$(repo_meta 82 '2026-06-12T00:00:00Z' false MIT)"
    gh_fixture "repos/acme/x/releases/latest" '{"tag_name":"v1.2.0"}'
    content_fixture acme/x v1.2.0 SKILL.md "# clean skill, nothing dangerous"
    run env PATH="$TEST_DIR/fakebin:$PATH" CURATION_NOW=2026-06-13 \
        CURATION_GH_RETRIES=1 CURATION_GH_BACKOFF=0 CURATION_THRESHOLDS="$THRESHOLDS" \
        FAKE_REPIN_FAIL=1 \
        bash "$WATCH" --registry "$TEST_DIR/registry.json" --presets-dir "$TEST_DIR/presets" --emit-pr --draft
    [[ "$status" -eq 0 ]]
    # worst case of a lookup outage = the status-quo duplicate, never a missed re-pin
    [[ "$(grep -c 'pr create' "$TEST_DIR/gh.log")" -eq 1 ]]
}

@test "watch: the open-PR lookup targets the repo explicitly (-R) and filters open state" {
    setup_emit_fakes
    registry_one "acme/x" "v1.0.0" authority
    gh_fixture "repos/acme/x" "$(repo_meta 82 '2026-06-12T00:00:00Z' false MIT)"
    gh_fixture "repos/acme/x/releases/latest" '{"tag_name":"v1.2.0"}'
    content_fixture acme/x v1.2.0 SKILL.md "# clean skill, nothing dangerous"
    run env PATH="$TEST_DIR/fakebin:$PATH" CURATION_NOW=2026-06-13 \
        CURATION_GH_RETRIES=1 CURATION_GH_BACKOFF=0 CURATION_THRESHOLDS="$THRESHOLDS" \
        CURATION_GH_REPO="acme/claude-base" \
        bash "$WATCH" --registry "$TEST_DIR/registry.json" --presets-dir "$TEST_DIR/presets" --emit-pr --draft
    [[ "$status" -eq 0 ]]
    grep 'pr list' "$TEST_DIR/gh.log" | grep -q -- '-R acme/claude-base'
    grep 'pr list' "$TEST_DIR/gh.log" | grep -q -- '--state open'
}

# =============================================================================
# Lock staleness escalation (2026-09-06).
#
# The #458 lock held 7 nights on one unreviewed draft. Every one of those nights
# the digest still printed `re-pin` in the Action column for every drift — an
# action nobody was taking — and said nothing about the lock. The digest must
# name the holder, date it, and escalate once it goes stale.
# =============================================================================

@test "watch: the digest names the blocking PR when re-pin emission was locked out" {
    setup_emit_fakes
    drifting_target
    export FAKE_REPIN_ROWS="$(lock_rows 12 2026-06-11T09:00:00Z)"   # 2 days old
    run_watch --emit-pr --draft --digest-dir "$TEST_DIR/digest"
    [ "$status" -eq 0 ]
    grep -q '#12' "$TEST_DIR/digest/digest.md"
    grep -qi 'locked' "$TEST_DIR/digest/digest.md"
    # the table's `re-pin` rows are proposals on a locked night, not opened PRs
    grep -qi 'proposal' "$TEST_DIR/digest/digest.md"
}

@test "watch: the digest escalates once the lock is held past the staleness threshold" {
    setup_emit_fakes
    drifting_target
    export FAKE_REPIN_ROWS="$(lock_rows 12 2026-06-06T09:00:00Z)"   # 7 days old
    run_watch --emit-pr --draft --digest-dir "$TEST_DIR/digest"
    [ "$status" -eq 0 ]
    grep -q '⚠️' "$TEST_DIR/digest/digest.md"
    grep -q '7 day' "$TEST_DIR/digest/digest.md"
}

@test "watch: a FRESH lock is reported without the stale escalation marker" {
    setup_emit_fakes
    drifting_target
    export FAKE_REPIN_ROWS="$(lock_rows 12 2026-06-13T09:00:00Z)"   # same day
    run_watch --emit-pr --draft --digest-dir "$TEST_DIR/digest"
    [ "$status" -eq 0 ]
    grep -q '#12' "$TEST_DIR/digest/digest.md"
    [ "$(grep -c '⚠️' "$TEST_DIR/digest/digest.md")" -eq 0 ]
}

@test "watch: the staleness threshold is read from the thresholds file" {
    setup_emit_fakes
    drifting_target
    jq '.global.repinLockStaleDays = 1' "$THRESHOLDS" > "$TEST_DIR/th.json"
    export FAKE_REPIN_ROWS="$(lock_rows 12 2026-06-11T09:00:00Z)"   # 2 days old
    run env PATH="$TEST_DIR/fakebin:$PATH" CURATION_NOW=2026-06-13 \
        CURATION_GH_RETRIES=1 CURATION_GH_BACKOFF=0 CURATION_THRESHOLDS="$TEST_DIR/th.json" \
        bash "$WATCH" --registry "$TEST_DIR/registry.json" --presets-dir "$TEST_DIR/presets" \
        --emit-pr --draft --digest-dir "$TEST_DIR/digest"
    [ "$status" -eq 0 ]
    grep -q '⚠️' "$TEST_DIR/digest/digest.md"
}

@test "watch: a NON-INTEGER staleness threshold still escalates (never silently off)" {
    # `jq numbers` lets a float through and `[ 7 -ge 3.5 ]` aborts with status 2,
    # which every caller reads as "not stale" — a config typo would have turned
    # the whole escalation off silently (review finding, 2026-09-06).
    setup_emit_fakes
    drifting_target
    jq '.global.repinLockStaleDays = 3.5' "$THRESHOLDS" > "$TEST_DIR/th.json"
    export FAKE_REPIN_ROWS="$(lock_rows 12 2026-06-06T09:00:00Z)"   # 7 days old
    run env PATH="$TEST_DIR/fakebin:$PATH" CURATION_NOW=2026-06-13 \
        CURATION_GH_RETRIES=1 CURATION_GH_BACKOFF=0 CURATION_THRESHOLDS="$TEST_DIR/th.json" \
        bash "$WATCH" --registry "$TEST_DIR/registry.json" --presets-dir "$TEST_DIR/presets" \
        --emit-pr --draft --digest-dir "$TEST_DIR/digest"
    [ "$status" -eq 0 ]
    grep -q '⚠️' "$TEST_DIR/digest/digest.md"
}

@test "watch: --dry-run --emit-pr previews the lock instead of the misleading normal night" {
    # The lookup is a READ, so a preview can consult it. Without this, the one
    # command a maintainer runs to inspect a suspicious digest by hand returns
    # exactly the pre-fix digest that hid the lock (review finding, 2026-09-06).
    setup_emit_fakes
    drifting_target
    export FAKE_REPIN_ROWS="$(lock_rows 12 2026-06-06T09:00:00Z)"
    run_watch --emit-pr --draft --dry-run --digest-dir "$TEST_DIR/digest"
    [ "$status" -eq 0 ]
    grep -q '#12' "$TEST_DIR/digest/digest.md"
    grep -q '⚠️' "$TEST_DIR/digest/digest.md"
    # still a preview: no PR, no pin bump
    [ "$(grep -c 'pr create' "$TEST_DIR/gh.log")" -eq 0 ]
    [ "$(jq -r '.records[0].pinnedRef' "$TEST_DIR/registry.json")" = "v1.0.0" ]
}

@test "watch: the digest survives a lock it cannot fold into the JSON" {
    # Regression for an inverted guard: `digest=$(… ) || :` assigns the EMPTY
    # output first and only then swallows the status, so a jq failure blanked
    # the entire digest — the guard destroyed what it meant to protect.
    setup_emit_fakes
    drifting_target
    export FAKE_REPIN_ROWS="$(lock_rows 12 2026-06-06T09:00:00Z)"
    export CURATION_LOCK_MERGE_FILTER='this is not a jq program'
    run_watch --emit-pr --draft --digest-dir "$TEST_DIR/digest"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.generatedAt' "$TEST_DIR/digest/digest.json")" = "2026-06-13" ]
    [ "$(jq -r '.findings | length' "$TEST_DIR/digest/digest.json")" -eq 1 ]
}

@test "watch: an unlocked night's digest carries NO lock notice" {
    setup_emit_fakes
    drifting_target
    run_watch --emit-pr --draft --digest-dir "$TEST_DIR/digest"
    [ "$status" -eq 0 ]
    # Counted, not `! grep`: bash never applies `set -e` to a `!`-inverted
    # command, so a non-final `! grep -q` assertion can never fail a bats test.
    [ "$(grep -ci 'locked' "$TEST_DIR/digest/digest.md")" -eq 0 ]
    [ "$(jq -r '.repinLock // "none"' "$TEST_DIR/digest/digest.json")" = "none" ]
}

@test "watch: digest.json records the lock for machine consumers" {
    setup_emit_fakes
    drifting_target
    export FAKE_REPIN_ROWS="$(lock_rows 12 2026-06-06T09:00:00Z)"
    run_watch --emit-pr --draft --digest-dir "$TEST_DIR/digest"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.repinLock.number' "$TEST_DIR/digest/digest.json")" = "12" ]
    [ "$(jq -r '.repinLock.ageDays' "$TEST_DIR/digest/digest.json")" = "7" ]
    [ "$(jq -r '.repinLock.stale' "$TEST_DIR/digest/digest.json")" = "true" ]
}

@test "watch: the emitted ISSUE body carries the lock notice too (the visible channel)" {
    setup_emit_fakes
    drifting_target
    export FAKE_REPIN_ROWS="$(lock_rows 12 2026-06-06T09:00:00Z)"
    run_watch --emit-pr --draft --emit-issue
    [ "$status" -eq 0 ]
    grep -q '#12' "$TEST_DIR/body.cap"
    grep -q '⚠️' "$TEST_DIR/body.cap"
}

@test "watch: a stale lock is escalated on stderr for the systemd journal" {
    setup_emit_fakes
    drifting_target
    export FAKE_REPIN_ROWS="$(lock_rows 12 2026-06-06T09:00:00Z)"
    run_watch --emit-pr --draft
    [ "$status" -eq 0 ]
    [[ "$output" == *"#12"* ]]
    [[ "$output" == *"7 day"* ]]
}

@test "watch: --dry-run suppresses all emission" {
    setup_emit_fakes
    registry_one "acme/x" "v1.0.0" authority
    gh_fixture "repos/acme/x" "$(repo_meta 82 '2026-06-12T00:00:00Z' false MIT)"
    gh_fixture "repos/acme/x/releases/latest" '{"tag_name":"v1.2.0"}'
    content_fixture acme/x v1.2.0 SKILL.md "# clean"
    run_watch --emit-issue --emit-pr --draft --dry-run
    [[ "$(grep -c 'issue create' "$TEST_DIR/gh.log")" -eq 0 ]]
    [[ "$(grep -c 'pr create' "$TEST_DIR/gh.log")" -eq 0 ]]
}

@test "watch: --emit-pr restores the original branch (never strands the invoker)" {
    setup_emit_fakes
    registry_one "acme/x" "v1.0.0" authority
    gh_fixture "repos/acme/x" "$(repo_meta 82 '2026-06-12T00:00:00Z' false MIT)"
    gh_fixture "repos/acme/x/releases/latest" '{"tag_name":"v1.2.0"}'
    content_fixture acme/x v1.2.0 SKILL.md "# clean"
    run_watch --emit-pr --draft
    grep -qE 'git (switch|checkout) main' "$TEST_DIR/git.log"
}

@test "watch: --emit-pr defaults to a DRAFT PR even without --draft" {
    setup_emit_fakes
    registry_one "acme/x" "v1.0.0" authority
    gh_fixture "repos/acme/x" "$(repo_meta 82 '2026-06-12T00:00:00Z' false MIT)"
    gh_fixture "repos/acme/x/releases/latest" '{"tag_name":"v1.2.0"}'
    content_fixture acme/x v1.2.0 SKILL.md "# clean"
    run_watch --emit-pr
    grep -q -- '--draft' "$TEST_DIR/gh.log"
}

@test "watch: --no-draft opens a ready (non-draft) PR" {
    setup_emit_fakes
    registry_one "acme/x" "v1.0.0" authority
    gh_fixture "repos/acme/x" "$(repo_meta 82 '2026-06-12T00:00:00Z' false MIT)"
    gh_fixture "repos/acme/x/releases/latest" '{"tag_name":"v1.2.0"}'
    content_fixture acme/x v1.2.0 SKILL.md "# clean"
    run_watch --emit-pr --no-draft
    [[ "$(grep -c 'pr create' "$TEST_DIR/gh.log")" -eq 1 ]]
    ! grep -q -- '--draft' "$TEST_DIR/gh.log"
}

@test "watch: re-pin does NOT touch a preset entry whose url merely contains the repo-root as a fragment" {
    setup_emit_fakes
    registry_one "acme/x" "v1.0.0" authority
    gh_fixture "repos/acme/x" "$(repo_meta 82 '2026-06-12T00:00:00Z' false MIT)"
    gh_fixture "repos/acme/x/releases/latest" '{"tag_name":"v1.2.0"}'
    content_fixture acme/x v1.2.0 SKILL.md "# clean"
    # A sibling entry whose URL CONTAINS "acme/x" as a path fragment but is a
    # different repo-root (other/acme-x-mirror) must keep its pin.
    jq -cn '{name:"p", recommendedVendorSkills:[
        {id:"other/mirror", url:"https://github.com/other/mirror/tree/acme/x", rationale:"r",
         condition:"always", pinnedRef:"v9.9.9", trustTrack:"authority", provenance:"O",
         lastVerified:"2026-01-01"}]}' > "$TEST_DIR/presets/p.json"
    run_watch --emit-pr --draft
    [[ "$(jq -r '.recommendedVendorSkills[0].pinnedRef' "$TEST_DIR/presets/p.json")" == "v9.9.9" ]]
}

@test "watch: a failed git push aborts PR creation and restores the branch (fail-safe)" {
    setup_emit_fakes
    # Override git so `push` fails; everything else succeeds.
    cat > "$TEST_DIR/fakebin/git" <<EOF
#!/usr/bin/env bash
echo "git \$*" >> "$TEST_DIR/git.log"
case "\$1" in
  rev-parse) echo main ;;
  push) exit 1 ;;
esac
exit 0
EOF
    chmod +x "$TEST_DIR/fakebin/git"
    registry_one "acme/x" "v1.0.0" authority
    gh_fixture "repos/acme/x" "$(repo_meta 82 '2026-06-12T00:00:00Z' false MIT)"
    gh_fixture "repos/acme/x/releases/latest" '{"tag_name":"v1.2.0"}'
    content_fixture acme/x v1.2.0 SKILL.md "# clean"
    run_watch --emit-pr --draft
    [[ "$status" -eq 0 ]]
    [[ "$(grep -c 'pr create' "$TEST_DIR/gh.log")" -eq 0 ]]
    grep -qE 'git (switch|checkout) main' "$TEST_DIR/git.log"
}

# =============================================================================
# _subpaths_for_repo (#384 subpath-scoping fix) — derive the '+'-joined, deduped
# subpaths the safety screen scopes to, from registry vendorIds + preset ids/urls.
# =============================================================================

EMIT_LIB="$BATS_TEST_DIRNAME/../scripts/lib/curation-emit.sh"

@test "_subpaths_for_repo: dedups + sorts subpaths from registry vendorIds and preset ids/urls" {
    cat > "$TEST_DIR/registry.json" <<'EOF'
{ "records": [
  {"vendorId":"acme/mono/cro"},
  {"vendorId":"acme/mono/analytics"},
  {"vendorId":"other/repo"}
] }
EOF
    cat > "$TEST_DIR/presets/p.json" <<'EOF'
{ "recommendedVendorSkills": [
  {"id":"acme/mono/onboarding"},
  {"url":"https://github.com/acme/mono/tree/main/landing"}
] }
EOF
    run bash -c "source '$EMIT_LIB'; _subpaths_for_repo acme/mono '$TEST_DIR/registry.json' '$TEST_DIR/presets'"
    [ "$status" -eq 0 ]
    # alphabetical, deduped, '+'-joined; the /tree/main/ infix is stripped
    [ "$output" = "analytics+cro+landing+onboarding" ]
}

@test "_subpaths_for_repo: empty for a repo-root skill (no subpath)" {
    cat > "$TEST_DIR/registry.json" <<'EOF'
{ "records": [ {"vendorId":"acme/root"} ] }
EOF
    run bash -c "source '$EMIT_LIB'; _subpaths_for_repo acme/root '$TEST_DIR/registry.json' '$TEST_DIR/presets'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "_subpaths_for_repo: only matches the requested repo-root" {
    cat > "$TEST_DIR/registry.json" <<'EOF'
{ "records": [
  {"vendorId":"acme/mono/cro"},
  {"vendorId":"acme/other/secret"}
] }
EOF
    run bash -c "source '$EMIT_LIB'; _subpaths_for_repo acme/mono '$TEST_DIR/registry.json' '$TEST_DIR/presets'"
    [ "$status" -eq 0 ]
    [ "$output" = "cro" ]
}

@test "_skills_for_repo: unions + dedups + sorts the foundation skills pinning a repo" {
    cat > "$TEST_DIR/registry.json" <<'EOF'
{ "records": [
  {"vendorId":"anthropics/skills/mcp-builder","foundationSkill":"dev-mcp"},
  {"vendorId":"anthropics/skills/claude-api","foundationSkill":"dev-ai-integration"},
  {"vendorId":"other/repo","foundationSkill":"dev-other"}
] }
EOF
    run bash -c "source '$EMIT_LIB'; _skills_for_repo anthropics/skills '$TEST_DIR/registry.json'"
    [ "$status" -eq 0 ]
    [ "$output" = "dev-ai-integration,dev-mcp" ]
}

@test "_skills_for_repo: empty when only a preset (no registry record) reaches the repo" {
    echo '{ "records": [ {"vendorId":"acme/other","foundationSkill":"x"} ] }' > "$TEST_DIR/registry.json"
    run bash -c "source '$EMIT_LIB'; _skills_for_repo acme/preset-only '$TEST_DIR/registry.json'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# =============================================================================
# watch-list license-note consistency check (awaiting-vendors.json)
# A currentBest's hand-edited license stance never passes the 4-source probe, so
# it can silently rot. These tests pin the guardrail that re-probes it.
# =============================================================================

# awaiting_one <foundationSkill> <currentBest> — a one-entry awaiting-vendors file.
awaiting_one() {
    jq -cn --arg fs "$1" --arg cb "$2" \
        '{version:"1.1.0", entries:[{foundationSkill:$fs, tech:"t",
          matchKeywords:["t"], currentBest:$cb, bar:"b"}]}' \
        > "$TEST_DIR/awaiting.json"
}

# readme_fixture <repo> <markdown> — register repos/<repo>/readme as base64 JSON.
readme_fixture() {
    local b64; b64=$(printf '%s' "$2" | base64 | tr -d '\n')
    gh_fixture "repos/$1/readme" "$(jq -cn --arg c "$b64" '{content:$c}')"
}

# run_watch_wl <currentBest> [extra args] — empty registry, isolate the awaiting check.
run_watch_wl() {
    echo '{"version":"1.0.0","records":[]}' > "$TEST_DIR/registry.json"
    awaiting_one "dev-flutter" "$1"; shift
    run env PATH="$TEST_DIR/fakebin:$PATH" CURATION_NOW=2026-06-13 \
        CURATION_GH_RETRIES=1 CURATION_GH_BACKOFF=0 CURATION_THRESHOLDS="$THRESHOLDS" \
        bash "$WATCH" --registry "$TEST_DIR/registry.json" --presets-dir "$TEST_DIR/presets" \
        --awaiting "$TEST_DIR/awaiting.json" "$@"
}

@test "watch-list: a stale 'unlicensed' note over a README-declared MIT is flagged (false negative)" {
    gh_fixture "repos/acme/x" "$(repo_meta 10 '2026-06-12T00:00:00Z' false NONE)"
    readme_fixture "acme/x" "## License"$'\n'"MIT"
    run_watch_wl "acme/x (~10 stars, unlicensed) — tiny"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.findings[0].type')" = "license-note" ]
    [ "$(printf '%s' "$output" | jq -r '.findings[0].subject')" = "acme/x" ]
    [ "$(printf '%s' "$output" | jq -r '.findings[0].forSkills')" = "dev-flutter" ]
    printf '%s' "$output" | jq -e '.findings[0].reasons[0] | test("unlicensed-but-probe-finds-license")'
}

@test "watch-list: a note claiming a license over a truly licenseless repo is flagged" {
    gh_fixture "repos/acme/x" "$(repo_meta 600 '2026-06-12T00:00:00Z' false NONE)"
    readme_fixture "acme/x" "# Title"$'\n'"no license here"
    run_watch_wl "acme/x (~600 stars, MIT) — broad"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.findings[0].type')" = "license-note" ]
    printf '%s' "$output" | jq -e '.findings[0].reasons[0] | test("claims-license-but-probe-finds-none")'
}

@test "watch-list: a note consistent with the live probe produces NO finding (no noise)" {
    gh_fixture "repos/acme/x" "$(repo_meta 10 '2026-06-12T00:00:00Z' false MIT)"
    run_watch_wl "acme/x (~10 stars, MIT declared in README — no LICENSE file) — tiny"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '[.findings[] | select(.type=="license-note")] | length')" = "0" ]
}

@test "watch-list: an entry that makes no license claim is never probed/flagged" {
    # No fixtures at all: if it probed, trust_score would error — but unknown stance skips it.
    run_watch_wl "acme/x (~10 stars, broad match) — tiny"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '[.findings[] | select(.type=="license-note")] | length')" = "0" ]
}

@test "watch-list: an entry naming no repo (NO-SUPPLY) is skipped" {
    run_watch_wl "NO-SUPPLY (2026): only MCP servers + an unstable provider; unlicensed"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '[.findings[] | select(.type=="license-note")] | length')" = "0" ]
}

@test "watch-list: a gh outage skips the entry (fail-safe, no false drift alarm)" {
    # 'unlicensed' note but NO repo fixture → trust_score errors → entry skipped.
    run_watch_wl "acme/ghost (~10 stars, unlicensed) — tiny"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '[.findings[] | select(.type=="license-note")] | length')" = "0" ]
}

@test "watch-list: the digest scope reports the watchlist size" {
    gh_fixture "repos/acme/x" "$(repo_meta 10 '2026-06-12T00:00:00Z' false MIT)"
    run_watch_wl "acme/x (~10 stars, MIT) — tiny"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.scope.watchlist')" = "1" ]
}
