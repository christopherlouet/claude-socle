#!/usr/bin/env bats

# Tests for emit_issue (scripts/lib/curation-emit.sh) — the idempotent digest
# emission. With a dedupe-key it must UPDATE the one rolling issue (marker in the
# body) instead of opening a duplicate every run (the digest-dup bug). Without a
# key it stays legacy create-only. Fully offline: a fake `gh` logs calls and
# returns a configurable existing-issue number.

load 'test_helper'

EMIT="$BATS_TEST_DIRNAME/../scripts/lib/curation-emit.sh"

setup() {
    setup_test_dir
    mkdir -p "$TEST_DIR/fakebin"
    export CURATION_GH_REPO="owner/repo"   # skip git-remote resolution
    cat > "$TEST_DIR/fakebin/gh" <<EOF
#!/usr/bin/env bash
echo "gh \$*" >> "$TEST_DIR/gh.log"
prev=""
for a in "\$@"; do
  [ "\$prev" = "--body-file" ] && cat "\$a" >> "$TEST_DIR/body.cap" 2>/dev/null
  prev="\$a"
done
case "\$*" in
  *"issue list"*) printf '%s' "\${FAKE_EXISTING:-}" ;;
  # The lock lookup asks for ROWS (number/createdAt/headRefName/url), not a
  # count — the digest has to name the blocking PR and say how old it is.
  # FAKE_REPIN_ROWS overrides; the default is one 2-day-old lock holder.
  *"pr list"*)
    rows="\${FAKE_REPIN_ROWS:-}"
    [ -n "\$rows" ] || rows='[{"number":7,"createdAt":"2026-07-11T09:00:00Z","headRefName":"curation/re-pin-2026-07-11","url":"https://github.com/owner/repo/pull/7"}]'
    printf '%s' "\$rows" ;;
esac
exit 0
EOF
    chmod +x "$TEST_DIR/fakebin/gh"
    printf 'digest body\n' > "$TEST_DIR/body.md"
}

# repin_findings — one drift finding the emitter would want to re-pin.
REPIN_FINDINGS='[{"subject":"acme/x","type":"drift","proposedAction":"re-pin","pinnedRef":"v1.0.0","currentRef":"v1.2.0"}]'

# run_repin <env assignments…> — emit_repin_pr against a throwaway registry with
# "today" pinned so the lock age is deterministic.
run_repin() {
    echo '{"version":"1.0.0","records":[]}' > "$TEST_DIR/registry.json"
    mkdir -p "$TEST_DIR/presets"
    run env PATH="$TEST_DIR/fakebin:$PATH" CURATION_NOW=2026-07-13 "$@" bash -c \
        "source '$EMIT'; emit_repin_pr '$REPIN_FINDINGS' '$TEST_DIR/registry.json' '$TEST_DIR/presets' true 2026-07-13"
}

# summary — the emitter's JSON summary alone. bats merges stderr into $output, so
# the warning line has to be dropped before jq sees it; the JSON is the last line.
# (Indexed the long way: bash 3.2 on the macOS runner has no ${arr[-1]}.)
summary() { printf '%s' "${lines[$(( ${#lines[@]} - 1 ))]}"; }
teardown() { teardown_test_dir; }

@test "emit_issue updates the existing rolling issue (no duplicate create)" {
    source "$EMIT"
    FAKE_EXISTING=42 PATH="$TEST_DIR/fakebin:$PATH" emit_issue "Curation digest — 2026-06-28" "$TEST_DIR/body.md" "watch-digest"
    grep -q "issue edit 42" "$TEST_DIR/gh.log"
    ! grep -q "issue create" "$TEST_DIR/gh.log"
}

@test "emit_issue creates when no rolling issue exists yet" {
    source "$EMIT"
    FAKE_EXISTING="" PATH="$TEST_DIR/fakebin:$PATH" emit_issue "Curation digest — 2026-06-28" "$TEST_DIR/body.md" "watch-digest"
    grep -q "issue create" "$TEST_DIR/gh.log"
    ! grep -q "issue edit" "$TEST_DIR/gh.log"
}

@test "emit_issue embeds the dedupe marker in the emitted body" {
    source "$EMIT"
    FAKE_EXISTING="" PATH="$TEST_DIR/fakebin:$PATH" emit_issue "t" "$TEST_DIR/body.md" "watch-digest"
    grep -q "curation-issue:watch-digest" "$TEST_DIR/body.cap"
}

@test "emit_issue without a key is create-only (legacy, no list lookup)" {
    source "$EMIT"
    PATH="$TEST_DIR/fakebin:$PATH" emit_issue "t" "$TEST_DIR/body.md"
    grep -q "issue create" "$TEST_DIR/gh.log"
    ! grep -q "issue list" "$TEST_DIR/gh.log"
}

# =============================================================================
# _repin_apply — marketplace preset entries (2026-07-12 audit, cluster C7).
# A marketplace plugin's preset copy carries a NON-github url (claude.com/...)
# that the github repo-root matcher can never match, while the pin-lockstep gate
# (validate-presets.sh) DOES couple the registry and preset pins by marketplace
# key. Without the mktkey match, every real drift of such a plugin emits a
# registry-only re-pin PR that fails its own lockstep CI — guaranteed red.
# =============================================================================

# mkt_registry <pin> — a registry whose single record is a marketplace plugin
# (vendorId subpathed under the marketplace repo, vendorUrl on claude.com).
mkt_registry() {
    jq -cn --arg p "$1" '{version:"1.0.0", records:[
        {foundationSkill:"dev-frontend-design",
         vendorId:"anthropics/claude-code/plugins/frontend-design",
         vendorUrl:"https://claude.com/plugins/frontend-design",
         pinnedRef:$p, trustTrack:"authority", trustVerdict:"pass",
         provenance:"Anthropic", adviceNeutrality:"pass",
         lastVerified:"2026-01-01", status:"candidate"}]}' \
        > "$TEST_DIR/registry.json"
}

@test "_repin_apply re-pins a marketplace preset entry via the registry marketplace key" {
    source "$EMIT"
    mkdir -p "$TEST_DIR/presets"
    mkt_registry "oldsha1111111111111111111111111111111111"
    jq -cn '{recommendedVendorSkills:[
        {id:"frontend-design@claude-plugins-official",
         url:"https://claude.com/plugins/frontend-design",
         pinnedRef:"oldsha1111111111111111111111111111111111", lastVerified:"2026-01-01"}]}' \
        > "$TEST_DIR/presets/nextjs.json"
    _repin_apply "$TEST_DIR/registry.json" "$TEST_DIR/presets" \
        "anthropics/claude-code" "newsha2222222222222222222222222222222222" "2026-07-13"
    [ "$(jq -r '.records[0].pinnedRef' "$TEST_DIR/registry.json")" = "newsha2222222222222222222222222222222222" ]
    [ "$(jq -r '.recommendedVendorSkills[0].pinnedRef' "$TEST_DIR/presets/nextjs.json")" = "newsha2222222222222222222222222222222222" ]
    [ "$(jq -r '.recommendedVendorSkills[0].lastVerified' "$TEST_DIR/presets/nextjs.json")" = "2026-07-13" ]
}

@test "_repin_apply leaves an UNRELATED marketplace entry untouched (exact key, no substring)" {
    source "$EMIT"
    mkdir -p "$TEST_DIR/presets"
    mkt_registry "oldsha"
    jq -cn '{recommendedVendorSkills:[
        {id:"frontend-design@claude-plugins-official",
         url:"https://claude.com/plugins/frontend-design",
         pinnedRef:"oldsha", lastVerified:"2026-01-01"},
        {id:"other@claude-plugins-official",
         url:"https://claude.com/plugins/frontend-design-pro",
         pinnedRef:"keepme", lastVerified:"2026-01-01"},
        {id:"acme/github-skill",
         url:"https://github.com/acme/github-skill",
         pinnedRef:"keepme", lastVerified:"2026-01-01"}]}' \
        > "$TEST_DIR/presets/mixed.json"
    _repin_apply "$TEST_DIR/registry.json" "$TEST_DIR/presets" \
        "anthropics/claude-code" "newsha" "2026-07-13"
    [ "$(jq -r '.recommendedVendorSkills[0].pinnedRef' "$TEST_DIR/presets/mixed.json")" = "newsha" ]
    [ "$(jq -r '.recommendedVendorSkills[1].pinnedRef' "$TEST_DIR/presets/mixed.json")" = "keepme" ]
    [ "$(jq -r '.recommendedVendorSkills[2].pinnedRef' "$TEST_DIR/presets/mixed.json")" = "keepme" ]
}

@test "_repin_apply still re-pins a github preset entry by repo-root (regression, registry absent)" {
    source "$EMIT"
    mkdir -p "$TEST_DIR/presets"
    jq -cn '{recommendedVendorSkills:[
        {id:"acme/skill", url:"https://github.com/acme/skill",
         pinnedRef:"v1.0.0", lastVerified:"2026-01-01"}]}' \
        > "$TEST_DIR/presets/gh.json"
    _repin_apply "$TEST_DIR/no-registry.json" "$TEST_DIR/presets" "acme/skill" "v1.2.0" "2026-07-13"
    [ "$(jq -r '.recommendedVendorSkills[0].pinnedRef' "$TEST_DIR/presets/gh.json")" = "v1.2.0" ]
}

# =============================================================================
# emit_repin_pr — open-PR lock lookup pagination (2026-07-12 audit, cluster C7).
# =============================================================================

@test "emit_repin_pr open-PR lookup passes --limit 100 (default 30 can miss the lock)" {
    # The stub default is one open lock holder, so emit_repin_pr stops right
    # after the lookup — no git/branch machinery is ever reached.
    run_repin
    [ "$status" -eq 0 ]
    [[ "$output" == *'"skipped":"open-pr"'* ]]
    grep 'pr list' "$TEST_DIR/gh.log" | grep -q -- '--limit 100'
}

# =============================================================================
# emit_repin_pr — lock staleness escalation (2026-09-06).
#
# The lock (#458) held for 7 nights on an unreviewed draft while the digest kept
# printing `re-pin` as the action for every drift — an action nobody was taking.
# The lock must therefore report WHO holds it and for HOW LONG, so the digest can
# say so and escalate. The branch filter moved OUT of gh's server-side --jq into
# local jq: as a `--jq` string it could never be exercised offline.
# =============================================================================

@test "emit_repin_pr names the blocking PR and its age when the lock is held" {
    run_repin
    [ "$status" -eq 0 ]
    [ "$(summary | jq -r '.skipped')" = "open-pr" ]
    [ "$(summary | jq -r '.lock.number')" = "7" ]
    [ "$(summary | jq -r '.lock.count')" = "1" ]
    # created 2026-07-11, "today" pinned to 2026-07-13
    [ "$(summary | jq -r '.lock.ageDays')" = "2" ]
    [ "$(summary | jq -r '.lock.url')" = "https://github.com/owner/repo/pull/7" ]
}

@test "emit_repin_pr reports the age of the OLDEST open re-pin PR, not the newest" {
    local rows='[{"number":9,"createdAt":"2026-07-12T09:00:00Z","headRefName":"curation/re-pin-2026-07-12","url":"u9"},
                 {"number":4,"createdAt":"2026-07-03T09:00:00Z","headRefName":"curation/re-pin-2026-07-03","url":"u4"}]'
    run_repin FAKE_REPIN_ROWS="$rows"
    [ "$status" -eq 0 ]
    [ "$(summary | jq -r '.lock.number')" = "4" ]
    [ "$(summary | jq -r '.lock.ageDays')" = "10" ]
    [ "$(summary | jq -r '.lock.count')" = "2" ]
}

@test "emit_repin_pr: a PR on an unrelated branch does NOT hold the lock" {
    local rows='[{"number":3,"createdAt":"2026-07-01T09:00:00Z","headRefName":"feat/something-else","url":"u3"}]'
    run_repin FAKE_REPIN_ROWS="$rows"
    [ "$status" -eq 0 ]
    [[ "$output" != *'"skipped":"open-pr"'* ]]
}

@test "emit_repin_pr: an empty open-PR list does NOT hold the lock" {
    run_repin FAKE_REPIN_ROWS='[]'
    [ "$status" -eq 0 ]
    [[ "$output" != *'"skipped":"open-pr"'* ]]
}

@test "emit_repin_pr: an unparseable lookup body proceeds (fail-open, never a missed re-pin)" {
    run_repin FAKE_REPIN_ROWS='not json at all'
    [ "$status" -eq 0 ]
    [[ "$output" != *'"skipped":"open-pr"'* ]]
}

@test "emit_repin_pr: an undatable lock still holds it, with an unknown age" {
    local rows='[{"number":5,"createdAt":"","headRefName":"curation/re-pin-x","url":"u5"}]'
    run_repin FAKE_REPIN_ROWS="$rows"
    [ "$status" -eq 0 ]
    [ "$(summary | jq -r '.skipped')" = "open-pr" ]
    [ "$(summary | jq -r '.lock.number')" = "5" ]
    [ "$(summary | jq -r '.lock.ageDays')" = "null" ]
}

@test "emit_repin_pr: an undatable PR does not hijack the report from a datable older one" {
    # A blank createdAt sorts ahead of every real timestamp, so the naive sort
    # reported the UNDATABLE row and an unknown age while a perfectly datable
    # 10-day age was available (review finding, 2026-09-06).
    local rows='[{"number":4,"createdAt":"2026-07-03T09:00:00Z","headRefName":"curation/re-pin-a","url":"u4"},
                 {"number":8,"createdAt":"","headRefName":"curation/re-pin-b","url":"u8"}]'
    run_repin FAKE_REPIN_ROWS="$rows"
    [ "$status" -eq 0 ]
    [ "$(summary | jq -r '.lock.number')" = "4" ]
    [ "$(summary | jq -r '.lock.ageDays')" = "10" ]
}

@test "emit_repin_pr: a clock skew never reports a NEGATIVE lock age" {
    # curation_days_since subtracts against the BOX clock, so a host running a
    # day behind makes a fresh PR look future-dated. Report it as just-opened,
    # never as "-1 day(s)" — and never let skew fake a staleness escalation.
    local rows='[{"number":6,"createdAt":"2026-07-20T09:00:00Z","headRefName":"curation/re-pin-c","url":"u6"}]'
    run_repin FAKE_REPIN_ROWS="$rows" CURATION_NOW=2026-07-13
    [ "$status" -eq 0 ]
    [ "$(summary | jq -r '.lock.ageDays')" = "0" ]
}
