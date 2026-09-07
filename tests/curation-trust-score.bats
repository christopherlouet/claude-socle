#!/usr/bin/env bats

# =============================================================================
# Tests for scripts/lib/trust-score.sh + scripts/lib/curation-common.sh
# (Slice 2, specs/marketplace-curation-engine).
#
# Fully OFFLINE and DETERMINISTIC: `gh` is replaced by a fake binary on PATH that
# emits a canned repo JSON (no network), and `CURATION_NOW` pins "today" so the
# recency math is stable. No LLM, no real gh, no clock dependence.
# =============================================================================

load 'test_helper'

TRUST_LIB="$BATS_TEST_DIRNAME/../scripts/lib/trust-score.sh"
COMMON_LIB="$BATS_TEST_DIRNAME/../scripts/lib/curation-common.sh"

setup() {
    setup_test_dir
    mkdir -p "$TEST_DIR/fakebin"
}

teardown() {
    teardown_test_dir
}

# fake_gh_returns <json> — install a fake `gh` that prints <json> ONLY for a
# `gh api repos/...` call. Path-aware on purpose: a regression that queried the
# wrong endpoint (users/, /forks, …) makes the fake fail, so tests catch it.
fake_gh_returns() {
    printf '%s' "$1" > "$TEST_DIR/repo.json"
    cat > "$TEST_DIR/fakebin/gh" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "api" ] && [[ "\$2" == repos/* ]]; then
    cat "$TEST_DIR/repo.json"
else
    echo "fake gh: unexpected call: \$*" >&2
    exit 1
fi
EOF
    chmod +x "$TEST_DIR/fakebin/gh"
}

# fake_gh_with_contents <repo-json> <contents-json> — install a path-aware fake
# `gh`: the repo metadata call (`repos/<repo>`) returns <repo-json>, the root
# contents listing (`repos/<repo>/contents`) returns <contents-json>. Lets a test
# exercise the license-file fallback that fires when the SPDX id is missing.
fake_gh_with_contents() {
    printf '%s' "$1" > "$TEST_DIR/repo.json"
    printf '%s' "$2" > "$TEST_DIR/contents.json"
    cat > "$TEST_DIR/fakebin/gh" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "api" ] && [[ "\$2" == repos/*/contents* ]]; then
    cat "$TEST_DIR/contents.json"
elif [ "\$1" = "api" ] && [[ "\$2" == repos/* ]]; then
    cat "$TEST_DIR/repo.json"
else
    echo "fake gh: unexpected call: \$*" >&2
    exit 1
fi
EOF
    chmod +x "$TEST_DIR/fakebin/gh"
}

# fake_gh_with_readme <repo-json> <contents-json> [readme] [plugin-json] [pkg-json]
# Flexible path-aware fake `gh`. Serves, by exact path, the manifest endpoints
# (`.claude-plugin/plugin.json`, `package.json`), the README, the root contents
# listing, then the repo metadata. An omitted/empty optional source makes that
# endpoint 404 (exit 1) so the probe falls through — exactly like the real API.
# Branch order is specific-before-generic so the right fixture wins.
fake_gh_with_readme() {
    printf '%s' "$1" > "$TEST_DIR/repo.json"
    printf '%s' "$2" > "$TEST_DIR/contents.json"
    [ -n "${3:-}" ] && jq -cn --arg c "$(printf '%s' "$3" | base64)" '{content:$c}' > "$TEST_DIR/readme.json"
    [ -n "${4:-}" ] && jq -cn --arg c "$(printf '%s' "$4" | base64)" '{content:$c}' > "$TEST_DIR/plugin.json"
    [ -n "${5:-}" ] && jq -cn --arg c "$(printf '%s' "$5" | base64)" '{content:$c}' > "$TEST_DIR/pkg.json"
    cat > "$TEST_DIR/fakebin/gh" <<EOF
#!/usr/bin/env bash
serve() { if [ -f "\$1" ]; then cat "\$1"; exit 0; else echo "fake gh 404: \$2" >&2; exit 1; fi; }
if [ "\$1" = "api" ]; then
  case "\$2" in
    repos/*/contents/.claude-plugin/plugin.json*) serve "$TEST_DIR/plugin.json" "\$2" ;;
    repos/*/contents/package.json*)               serve "$TEST_DIR/pkg.json" "\$2" ;;
    repos/*/readme*)                              serve "$TEST_DIR/readme.json" "\$2" ;;
    repos/*/contents*)                            serve "$TEST_DIR/contents.json" "\$2" ;;
    repos/*)                                      serve "$TEST_DIR/repo.json" "\$2" ;;
  esac
fi
echo "fake gh: unexpected call: \$*" >&2; exit 1
EOF
    chmod +x "$TEST_DIR/fakebin/gh"
}

# fake_gh_errors — install a fake `gh` that always fails (simulates API/network
# error or rate-limit exhaustion).
fake_gh_errors() {
    cat > "$TEST_DIR/fakebin/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh: HTTP 503" >&2
exit 1
EOF
    chmod +x "$TEST_DIR/fakebin/gh"
}

# fake_gh_subpaths <repo-json> <root-contents-json> [<subpath> <contents-json>]...
# Path-aware fake `gh` that serves a DISTINCT contents listing per subpath, so a
# test can give the repo ROOT no license while a skill SUBPATH ships its own
# (the anthropics/skills convention). A subpath with no fixture 404s (exit 1)
# exactly like the real API. The manifest and README endpoints always 404 here,
# so the subpath arm is the only fallback under test.
fake_gh_subpaths() {
    printf '%s' "$1" > "$TEST_DIR/repo.json"
    printf '%s' "$2" > "$TEST_DIR/root-contents.json"
    shift 2
    while [ "$#" -ge 2 ]; do
        printf '%s' "$2" > "$TEST_DIR/sub-$(printf '%s' "$1" | tr '/' '_').json"
        shift 2
    done
    cat > "$TEST_DIR/fakebin/gh" <<EOF
#!/usr/bin/env bash
serve() { if [ -f "\$1" ]; then cat "\$1"; exit 0; else echo "fake gh 404: \$2" >&2; exit 1; fi; }
if [ "\$1" = "api" ]; then
  case "\$2" in
    repos/*/contents/.claude-plugin/plugin.json*) exit 1 ;;
    repos/*/contents/package.json*)               exit 1 ;;
    repos/*/readme*)                              exit 1 ;;
    repos/*/contents)                             serve "$TEST_DIR/root-contents.json" "\$2" ;;
    repos/*/contents/*)
        p="\${2#*/contents/}"; p="\${p%%\\?*}"
        serve "$TEST_DIR/sub-\$(printf '%s' "\$p" | tr '/' '_').json" "\$2" ;;
    repos/*)                                      serve "$TEST_DIR/repo.json" "\$2" ;;
  esac
fi
echo "fake gh: unexpected call: \$*" >&2; exit 1
EOF
    chmod +x "$TEST_DIR/fakebin/gh"
}

# repo_json — build a GitHub repo JSON with overridable fields.
# Args: stars forks pushed_at archived spdx_id
repo_json() {
    jq -cn \
        --argjson stars "$1" --argjson forks "$2" \
        --arg pushed "$3" --argjson archived "$4" --arg lic "$5" \
        '{stargazers_count:$stars, forks_count:$forks, pushed_at:$pushed,
          archived:$archived, license:{spdx_id:$lic}}'
}

# score <repo> <track> — run trust_score with the fake gh on PATH, "now" pinned,
# and gh retries collapsed so the test never sleeps. Operational logging goes to
# stderr (not under test here); discard it so $output is the pure JSON verdict.
score() {
    run env PATH="$TEST_DIR/fakebin:$PATH" CURATION_NOW=2026-06-13 \
        CURATION_GH_RETRIES=1 CURATION_GH_BACKOFF=0 \
        bash -c "source '$TRUST_LIB'; trust_score '$1' '$2' '${3:-}' 2>/dev/null"
}

verdict_of() { printf '%s' "$1" | jq -r '.verdict'; }

# =============================================================================
# curation-common — pure-bash date math (portable, no `date` dependency)
# =============================================================================

@test "curation_days_since computes whole days between two dates" {
    run env CURATION_NOW=2026-06-13 bash -c "source '$COMMON_LIB'; curation_days_since '2026-04-28T07:24:36Z'"
    [[ "$status" -eq 0 ]]
    [[ "$output" -eq 46 ]]
}

@test "curation_days_since handles a leap day correctly" {
    run env CURATION_NOW=2024-03-01 bash -c "source '$COMMON_LIB'; curation_days_since '2024-02-28'"
    [[ "$status" -eq 0 ]]
    [[ "$output" -eq 2 ]]   # 2024 is a leap year: 28 -> 29 -> 01 = 2 days
}

@test "curation_days_since returns same-day as 0" {
    run env CURATION_NOW=2026-06-13 bash -c "source '$COMMON_LIB'; curation_days_since '2026-06-13T23:59:59Z'"
    [[ "$status" -eq 0 ]]
    [[ "$output" -eq 0 ]]
}

@test "curation_days_since rejects an unparseable date" {
    run bash -c "source '$COMMON_LIB'; curation_days_since 'not-a-date'"
    [[ "$status" -ne 0 ]]
}

@test "curation_days_since does not read leading-zero months as octal" {
    # 08/09 would be invalid octal — must be parsed base-10.
    run env CURATION_NOW=2026-09-10 bash -c "source '$COMMON_LIB'; curation_days_since '2026-08-31'"
    [[ "$status" -eq 0 ]]
    [[ "$output" -eq 10 ]]
}

# =============================================================================
# trust_score — authority track (no popularity bar, EF-003)
# =============================================================================

@test "trust_score: authority track passes a low-star but maintained repo" {
    fake_gh_returns "$(repo_json 7 1 '2026-06-10T00:00:00Z' false MIT)"
    score "vendor/own-skill" authority
    [[ "$status" -eq 0 ]]
    [[ "$(verdict_of "$output")" == "pass" ]]
}

@test "trust_score: authority track does NOT apply the popularity bar" {
    fake_gh_returns "$(repo_json 3 0 '2026-06-01T00:00:00Z' false Apache-2.0)"
    score "vendor/tiny" authority
    [[ "$(verdict_of "$output")" == "pass" ]]
}

# =============================================================================
# trust_score — community track (high popularity bar)
# =============================================================================

@test "trust_score: community track passes above the popularity bar" {
    fake_gh_returns "$(repo_json 2012 100 '2026-06-03T00:00:00Z' false MIT)"
    score "person/skill" community
    [[ "$(verdict_of "$output")" == "pass" ]]
}

@test "trust_score: community track FAILS below the popularity bar" {
    fake_gh_returns "$(repo_json 100 5 '2026-06-03T00:00:00Z' false MIT)"
    score "person/small" community
    [[ "$status" -eq 0 ]]
    [[ "$(verdict_of "$output")" == "fail" ]]
    [[ "$output" == *"below-popularity-bar"* ]]
}

# =============================================================================
# trust_score — archive / recency / license
# =============================================================================

@test "trust_score: an archived repo fails regardless of track" {
    fake_gh_returns "$(repo_json 5000 200 '2026-06-10T00:00:00Z' true MIT)"
    score "vendor/dead" authority
    [[ "$(verdict_of "$output")" == "fail" ]]
    [[ "$output" == *"archived"* ]]
}

@test "trust_score: an abandoned (stale) repo fails" {
    fake_gh_returns "$(repo_json 5000 200 '2024-01-01T00:00:00Z' false MIT)"
    score "vendor/stale" authority
    [[ "$(verdict_of "$output")" == "fail" ]]
    [[ "$output" == *"stale:"* ]]
}

@test "trust_score: a repo pushed exactly at the staleness boundary still passes" {
    # maxStaleDays = 365; 2025-06-13 is exactly 365 days before 2026-06-13.
    fake_gh_returns "$(repo_json 5000 200 '2025-06-13T00:00:00Z' false MIT)"
    score "vendor/edge" authority
    [[ "$(verdict_of "$output")" == "pass" ]]
}

@test "trust_score: a missing license flags (soft), never fails" {
    fake_gh_returns "$(repo_json 5000 200 '2026-06-10T00:00:00Z' false NONE)"
    score "vendor/nolicense" authority
    [[ "$(verdict_of "$output")" == "flag" ]]
    [[ "$output" == *"missing-license"* ]]
}

@test "trust_score: NOASSERTION license is treated as present (passes)" {
    fake_gh_returns "$(repo_json 2012 100 '2026-06-03T00:00:00Z' false NOASSERTION)"
    score "person/skill" community
    [[ "$(verdict_of "$output")" == "pass" ]]
}

@test "trust_score: missing SPDX but a LICENSE file present is a soft note, passes (re-pinnable)" {
    # A custom/non-OSS license (e.g. anthropics/claude-code) yields spdx_id=null
    # even though a LICENSE file exists. The file-presence fallback downgrades the
    # blocking missing-license flag to a soft, non-blocking unrecognized-license.
    fake_gh_with_contents \
        "$(repo_json 5000 200 '2026-06-10T00:00:00Z' false NONE)" \
        '[{"name":"LICENSE.md","type":"file"},{"name":"README.md","type":"file"}]'
    score "anthropics/claude-code" authority
    [[ "$status" -eq 0 ]]
    [[ "$(verdict_of "$output")" == "pass" ]]
    [[ "$output" == *"unrecognized-license"* ]]
    [[ "$output" != *'"missing-license"'* ]]
}

@test "trust_score: license-file probe is case-insensitive and matches COPYING" {
    fake_gh_with_contents \
        "$(repo_json 5000 200 '2026-06-10T00:00:00Z' false NONE)" \
        '[{"name":"copying","type":"file"}]'
    score "vendor/copying" community
    [[ "$(verdict_of "$output")" == "pass" ]]
    [[ "$output" == *"unrecognized-license"* ]]
}

@test "trust_score: missing SPDX and NO license file still flags missing-license" {
    fake_gh_with_contents \
        "$(repo_json 5000 200 '2026-06-10T00:00:00Z' false NONE)" \
        '[{"name":"README.md","type":"file"},{"name":"src","type":"dir"}]'
    score "vendor/nolicense" authority
    [[ "$(verdict_of "$output")" == "flag" ]]
    [[ "$output" == *"missing-license"* ]]
    [[ "$output" != *"unrecognized-license"* ]]
}

@test "trust_score: missing SPDX + no LICENSE file but a README License section passes (soft note)" {
    # vercel-labs/agent-skills (28k stars): no LICENSE file, GitHub spdx_id=null,
    # but the README declares "## License / MIT". The README probe recognizes the
    # declaration and downgrades the blocking missing-license to a soft note.
    fake_gh_with_readme \
        "$(repo_json 28000 500 '2026-06-10T00:00:00Z' false NONE)" \
        '[{"name":"README.md","type":"file"},{"name":"src","type":"dir"}]' \
        '# agent-skills

## License

MIT'
    score "vercel-labs/agent-skills" authority
    [[ "$status" -eq 0 ]]
    [[ "$(verdict_of "$output")" == "pass" ]]
    [[ "$output" == *"readme-declared-license"* ]]
    [[ "$output" != *'"missing-license"'* ]]
}

@test "trust_score: a LICENSE file takes precedence over the README probe" {
    # File present -> unrecognized-license, the README is never consulted.
    fake_gh_with_readme \
        "$(repo_json 5000 200 '2026-06-10T00:00:00Z' false NONE)" \
        '[{"name":"LICENSE","type":"file"}]' \
        '## License

MIT'
    score "vendor/file-wins" authority
    [[ "$(verdict_of "$output")" == "pass" ]]
    [[ "$output" == *"unrecognized-license"* ]]
    [[ "$output" != *"readme-declared-license"* ]]
}

@test "trust_score: license in .claude-plugin/plugin.json passes (manifest probe)" {
    # langchain-ai/langchain-skills: spdx null, no LICENSE file, no README License
    # section — but the Claude plugin manifest declares "license": "MIT". For a
    # Claude-skill repo the manifest is the canonical license source.
    fake_gh_with_readme \
        "$(repo_json 819 30 '2026-06-10T00:00:00Z' false NONE)" \
        '[{"name":"README.md","type":"file"},{"name":".claude-plugin","type":"dir"}]' \
        '# langchain-skills

Build RAG apps.' \
        '{"name":"langchain","license":"MIT"}'
    score "langchain-ai/langchain-skills" authority
    [[ "$status" -eq 0 ]]
    [[ "$(verdict_of "$output")" == "pass" ]]
    [[ "$output" == *"manifest-declared-license"* ]]
    [[ "$output" != *'"missing-license"'* ]]
}

@test "trust_score: license in package.json passes (manifest probe)" {
    fake_gh_with_readme \
        "$(repo_json 900 40 '2026-06-10T00:00:00Z' false NONE)" \
        '[{"name":"package.json","type":"file"}]' \
        '' '' '{"name":"x","license":"Apache-2.0"}'
    score "vendor/npm-pkg" authority
    [[ "$(verdict_of "$output")" == "pass" ]]
    [[ "$output" == *"manifest-declared-license"* ]]
}

@test "trust_score: manifest UNLICENSED (npm proprietary) is NOT a license" {
    # npm's "UNLICENSED" means proprietary -> must stay flagged, not pass.
    fake_gh_with_readme \
        "$(repo_json 900 40 '2026-06-10T00:00:00Z' false NONE)" \
        '[{"name":"package.json","type":"file"}]' \
        '' '' '{"name":"x","license":"UNLICENSED"}'
    score "vendor/proprietary" authority
    [[ "$(verdict_of "$output")" == "flag" ]]
    [[ "$output" == *"missing-license"* ]]
    [[ "$output" != *"manifest-declared-license"* ]]
}

@test "trust_score: the manifest probe takes precedence over the README probe" {
    fake_gh_with_readme \
        "$(repo_json 5000 200 '2026-06-10T00:00:00Z' false NONE)" \
        '[{"name":".claude-plugin","type":"dir"},{"name":"README.md","type":"file"}]' \
        '## License

MIT' \
        '{"license":"MIT"}'
    score "vendor/both" authority
    [[ "$(verdict_of "$output")" == "pass" ]]
    [[ "$output" == *"manifest-declared-license"* ]]
    [[ "$output" != *"readme-declared-license"* ]]
}

@test "trust_score: no SPDX, no file, no manifest, no README section flags missing-license" {
    # Genuine true-negative: none of the four sources declares a license.
    fake_gh_with_readme \
        "$(repo_json 800 30 '2026-06-10T00:00:00Z' false NONE)" \
        '[{"name":"README.md","type":"file"},{"name":"src","type":"dir"}]' \
        '# tool

No licensing information anywhere here.'
    score "vendor/genuinely-bare" authority
    [[ "$(verdict_of "$output")" == "flag" ]]
    [[ "$output" == *"missing-license"* ]]
    [[ "$output" != *"manifest-declared-license"* ]]
    [[ "$output" != *"readme-declared-license"* ]]
}

@test "trust_score: an incidental SPDX mention (no License heading) is NOT a declaration" {
    # "MIT-licensed dependencies" in prose must not be read as the repo's license.
    fake_gh_with_readme \
        "$(repo_json 800 30 '2026-06-10T00:00:00Z' false NONE)" \
        '[{"name":"README.md","type":"file"}]' \
        '# tool

This works great with MIT-licensed dependencies and Apache projects.'
    score "vendor/incidental" authority
    [[ "$(verdict_of "$output")" == "flag" ]]
    [[ "$output" == *"missing-license"* ]]
    [[ "$output" != *"readme-declared-license"* ]]
}

@test "trust_score: a directory named LICENSES does not count as a license file" {
    fake_gh_with_contents \
        "$(repo_json 5000 200 '2026-06-10T00:00:00Z' false NONE)" \
        '[{"name":"LICENSES","type":"dir"},{"name":"README.md","type":"file"}]'
    score "vendor/licenses-dir" authority
    [[ "$(verdict_of "$output")" == "flag" ]]
    [[ "$output" == *"missing-license"* ]]
}

@test "trust_score: license-file probe failing falls back to missing-license (fail-safe)" {
    # Repo metadata resolves (NONE license) but the contents listing errors — we
    # cannot confirm a license file, so we keep the conservative blocking flag.
    cat > "$TEST_DIR/fakebin/gh" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "api" ] && [[ "\$2" == repos/*/contents* ]]; then
    echo "gh: HTTP 503" >&2; exit 1
elif [ "\$1" = "api" ] && [[ "\$2" == repos/* ]]; then
    cat <<'JSON'
$(repo_json 5000 200 '2026-06-10T00:00:00Z' false NONE)
JSON
fi
EOF
    chmod +x "$TEST_DIR/fakebin/gh"
    score "vendor/probe-fails" authority
    [[ "$(verdict_of "$output")" == "flag" ]]
    [[ "$output" == *"missing-license"* ]]
}

@test "trust_score: reports ALL failing reasons, not just the first" {
    fake_gh_returns "$(repo_json 100 5 '2024-01-01T00:00:00Z' true MIT)"
    score "person/multi" community
    [[ "$(verdict_of "$output")" == "fail" ]]
    [[ "$output" == *"archived"* ]]
    [[ "$output" == *"stale:"* ]]
    [[ "$output" == *"below-popularity-bar"* ]]
}

# =============================================================================
# License probe — SUBPATH-scoped license file
# =============================================================================

@test "trust_score: no root license but every consumed subpath ships one passes" {
    # anthropics/skills has NEVER had a root LICENSE; each skill carries its own
    # Apache-2.0 LICENSE.txt (verified: claude-api since 2026-03, mcp-builder too).
    # A root-only probe therefore called a first-party, fully licensed repo
    # "missing-license" and pinned it to propose-only forever.
    fake_gh_subpaths \
        "$(repo_json 9000 400 '2026-06-10T00:00:00Z' false NONE)" \
        '[{"name":"README.md","type":"file"},{"name":"skills","type":"dir"}]' \
        'skills/claude-api'  '[{"name":"LICENSE.txt","type":"file"},{"name":"SKILL.md","type":"file"}]' \
        'skills/mcp-builder' '[{"name":"LICENSE.txt","type":"file"},{"name":"SKILL.md","type":"file"}]'
    score "anthropics/skills" authority "skills/claude-api+skills/mcp-builder"
    [[ "$status" -eq 0 ]]
    [[ "$(verdict_of "$output")" == "pass" ]]
    [[ "$output" == *"subpath-license"* ]]
    [[ "$output" != *'"missing-license"'* ]]
}

@test "trust_score: ONE unlicensed subpath keeps the missing-license flag" {
    # EVERY consumed subpath must carry its own license. Waving the repo through
    # on the licensed one would license a skill that is NOT licensed — the arm
    # must not become a way to smuggle an unlicensed subpath past the gate.
    fake_gh_subpaths \
        "$(repo_json 9000 400 '2026-06-10T00:00:00Z' false NONE)" \
        '[{"name":"README.md","type":"file"}]' \
        'skills/licensed'   '[{"name":"LICENSE.txt","type":"file"}]' \
        'skills/unlicensed' '[{"name":"SKILL.md","type":"file"}]'
    score "vendor/partly" authority "skills/licensed+skills/unlicensed"
    [[ "$(verdict_of "$output")" == "flag" ]]
    [[ "$output" == *"missing-license"* ]]
    [[ "$output" != *"subpath-license"* ]]
}

@test "trust_score: an unfetchable subpath fails SAFE to missing-license" {
    # EF-012: anything that cannot be confirmed licensed stays flagged.
    fake_gh_subpaths \
        "$(repo_json 9000 400 '2026-06-10T00:00:00Z' false NONE)" \
        '[{"name":"README.md","type":"file"}]'
    score "vendor/gone" authority "skills/vanished"
    [[ "$(verdict_of "$output")" == "flag" ]]
    [[ "$output" == *"missing-license"* ]]
    [[ "$output" != *"subpath-license"* ]]
}

@test "trust_score: a subpath that resolves to a FILE fails SAFE, never passes" {
    # The contents endpoint returns an OBJECT for a file path and an ARRAY for a
    # directory. A malformed registry entry naming a file must not be read as a
    # licensed directory — the probe must fall through to missing-license.
    fake_gh_subpaths \
        "$(repo_json 9000 400 '2026-06-10T00:00:00Z' false NONE)" \
        '[{"name":"README.md","type":"file"}]' \
        'skills/a/LICENSE.txt' '{"name":"LICENSE.txt","type":"file","path":"skills/a/LICENSE.txt"}'
    score "vendor/filepath" authority "skills/a/LICENSE.txt"
    [[ "$(verdict_of "$output")" == "flag" ]]
    [[ "$output" == *"missing-license"* ]]
    [[ "$output" != *"subpath-license"* ]]
}

@test "trust_score: a ROOT license file still wins over the subpath probe" {
    # Precedence is unchanged for every repo that already passes at the root, so
    # the new arm can neither alter an existing verdict nor its reason string.
    fake_gh_subpaths \
        "$(repo_json 9000 400 '2026-06-10T00:00:00Z' false NONE)" \
        '[{"name":"LICENSE","type":"file"}]' \
        'skills/a' '[{"name":"LICENSE.txt","type":"file"}]'
    score "vendor/rooted" authority "skills/a"
    [[ "$(verdict_of "$output")" == "pass" ]]
    [[ "$output" == *"unrecognized-license"* ]]
    [[ "$output" != *"subpath-license"* ]]
}

@test "trust_score: with NO subpath argument the verdict is exactly today's" {
    # Zero-delta guard. Widening a license gate must stay INERT for every
    # root-scoped record; only a caller that knows the skill lives in a subpath
    # may opt in. Measured on the real registry: 2 records change, 18 do not.
    fake_gh_subpaths \
        "$(repo_json 9000 400 '2026-06-10T00:00:00Z' false NONE)" \
        '[{"name":"README.md","type":"file"}]' \
        'skills/a' '[{"name":"LICENSE.txt","type":"file"}]'
    score "vendor/rootscoped" authority
    [[ "$(verdict_of "$output")" == "flag" ]]
    [[ "$output" == *"missing-license"* ]]
    [[ "$output" != *"subpath-license"* ]]
}

# =============================================================================
# trust_score — emitted signals + fail-safe + usage
# =============================================================================

@test "trust_score: emits the captured public signals" {
    fake_gh_returns "$(repo_json 82 3 '2026-06-12T17:14:23Z' false MIT)"
    score "apollographql/skills" authority
    [[ "$(printf '%s' "$output" | jq -r '.stars')" -eq 82 ]]
    [[ "$(printf '%s' "$output" | jq -r '.forks')" -eq 3 ]]
    [[ "$(printf '%s' "$output" | jq -r '.license')" == "MIT" ]]
    [[ "$(printf '%s' "$output" | jq -r '.ageDays')" -eq 1 ]]
}

@test "trust_score: community track passes at exactly the popularity bar (>= boundary)" {
    # minStars=500; `-lt 500` is false at 500 → 500 passes.
    fake_gh_returns "$(repo_json 500 10 '2026-06-10T00:00:00Z' false MIT)"
    score "person/exactly-bar" community
    [[ "$(verdict_of "$output")" == "pass" ]]
}

@test "trust_score: a future pushed_at (clock skew) is NOT flagged and clamps ageDays to 0" {
    fake_gh_returns "$(repo_json 5000 200 '2026-06-14T00:00:00Z' false MIT)"
    score "vendor/fresh-mirror" authority
    [[ "$(verdict_of "$output")" == "pass" ]]
    [[ "$(printf '%s' "$output" | jq -r '.ageDays')" -eq 0 ]]
    [[ "$output" != *"unknown-recency"* ]]
}

@test "trust_score: an unparseable pushed_at flags bad-date (distinct from a future push)" {
    fake_gh_returns '{"stargazers_count":5000,"forks_count":1,"pushed_at":"garbage","archived":false,"license":{"spdx_id":"MIT"}}'
    score "vendor/baddate" authority
    [[ "$(verdict_of "$output")" == "flag" ]]
    [[ "$output" == *"bad-date"* ]]
}

@test "trust_score: a malformed (non-numeric) star count fails CLOSED, never empty/exit-0" {
    fake_gh_returns '{"stargazers_count":"lots","forks_count":5,"pushed_at":"2026-06-10T00:00:00Z","archived":false,"license":{"spdx_id":"MIT"}}'
    score "person/garbled" community
    [[ "$status" -eq 0 ]]
    [[ -n "$output" ]]
    # coerced to 0 stars → below the community bar → fail (closed), not silent.
    [[ "$(verdict_of "$output")" == "fail" ]]
    [[ "$(printf '%s' "$output" | jq -r '.stars')" -eq 0 ]]
}

@test "trust_score: returns 3 when the thresholds file is missing (operational error)" {
    fake_gh_returns "$(repo_json 100 5 '2026-06-10T00:00:00Z' false MIT)"
    run env PATH="$TEST_DIR/fakebin:$PATH" CURATION_NOW=2026-06-13 \
        CURATION_GH_RETRIES=1 CURATION_GH_BACKOFF=0 \
        CURATION_THRESHOLDS="$TEST_DIR/does-not-exist.json" \
        bash -c "source '$TRUST_LIB'; trust_score 'vendor/x' authority 2>/dev/null"
    [[ "$status" -eq 3 ]]
}

# =============================================================================
# CLI entrypoint (trust-score.sh run as an executable)
# =============================================================================

@test "trust_score CLI: prints a verdict for <repo> <track>" {
    fake_gh_returns "$(repo_json 82 3 '2026-06-12T00:00:00Z' false MIT)"
    run env PATH="$TEST_DIR/fakebin:$PATH" CURATION_NOW=2026-06-13 \
        CURATION_GH_RETRIES=1 CURATION_GH_BACKOFF=0 \
        bash "$TRUST_LIB" apollographql/skills authority
    [[ "$status" -eq 0 ]]
    [[ "$(printf '%s' "$output" | jq -r '.verdict')" == "pass" ]]
}

@test "trust_score CLI: exits 2 on wrong argument count" {
    run bash "$TRUST_LIB" only-one-arg
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"Usage:"* ]]
    run bash "$TRUST_LIB" a b c d
    [[ "$status" -eq 2 ]]
}

@test "trust_score CLI: accepts the optional subpaths argument" {
    # The 3-arg form is how a caller opts a subpath-scoped record into the
    # subpath license arm; the CLI must not reject it as a wrong arg count.
    fake_gh_subpaths \
        "$(repo_json 9000 400 '2026-06-10T00:00:00Z' false NONE)" \
        '[{"name":"README.md","type":"file"}]' \
        'skills/claude-api' '[{"name":"LICENSE.txt","type":"file"}]'
    run env PATH="$TEST_DIR/fakebin:$PATH" CURATION_NOW=2026-06-13 \
        CURATION_GH_RETRIES=1 CURATION_GH_BACKOFF=0 \
        bash "$TRUST_LIB" anthropics/skills authority skills/claude-api
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"subpath-license"* ]]
}

@test "trust_score: FAILS SAFE on gh error (verdict=error, exit 3)" {
    fake_gh_errors
    score "vendor/x" authority
    [[ "$status" -eq 3 ]]
    [[ "$(verdict_of "$output")" == "error" ]]
    [[ "$output" == *"gh-unavailable"* ]]
}

@test "trust_score: rejects an unknown track (exit 2)" {
    fake_gh_returns "$(repo_json 100 5 '2026-06-10T00:00:00Z' false MIT)"
    score "vendor/x" vendor
    [[ "$status" -eq 2 ]]
}
