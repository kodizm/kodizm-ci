#!/usr/bin/env bash
# Checks ci-job's pure helpers without network or root: resolve_dir must
# refuse every way out of the checkout, the summariser must turn a
# `flutter test --file-reporter json:` log into the results payload, and pr
# mode must stage the base commit's scope script, never the head's. Then the
# token response features (git through the Worker, log upload), the failure
# tail, the flutter reporter fix and sync-neutral-images' dry run.
#
# usage: bash scripts/test/ci-job.test.sh   (macOS or Linux; needs php, jq, git, curl, gzip)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

pass() {
    echo "ok: $1"
}

# shellcheck source=scripts/ci-job
source "$here/../ci-job"

# Sourcing defines the functions and runs nothing; the globals they read are
# pointed at the scratch directory, and fd 3 (the public log) at nowhere.
exec 3>/dev/null
tree="$work/tree"
state="$work/state"
mkdir -p "$state" "$tree/backend/app" "$work/outside"
ln -s "$tree/backend" "$tree/link"
ln -s "$work/outside" "$tree/escape"
real_tree="$(realpath "$tree")"

expect_resolves() {
    local dir="$1"
    local expected="$2"
    local actual

    if ! actual="$(resolve_dir "$tree" "$dir")"; then
        fail "resolve_dir refused '$dir'"
    fi
    if [ "$actual" != "$expected" ]; then
        fail "resolve_dir '$dir' gave '$actual', expected '$expected'"
    fi
    pass "resolve_dir accepts '$dir'"
}

expect_refused() {
    local dir="$1"
    local label="$2"

    if resolve_dir "$tree" "$dir" >/dev/null; then
        fail "resolve_dir accepted $label"
    fi
    pass "resolve_dir refuses $label"
}

# 1. Directory resolution.
expect_resolves . "$real_tree"
expect_resolves backend "$real_tree/backend"
expect_resolves backend/app "$real_tree/backend/app"
expect_refused ../outside 'a parent-relative path'
expect_refused backend/../../outside 'a path climbing out through ..'
expect_refused "$tree/backend" 'an absolute path'
expect_refused / 'the filesystem root'
expect_refused link 'a symlink inside the tree'
expect_refused link/app 'a symlinked component'
expect_refused escape 'a symlink leading outside'
expect_refused missing 'a missing directory'
expect_refused $'backend\napp' 'a newline'
expect_refused '' 'an empty path'

# 2. Flutter's JSON reporter, as `flutter test --file-reporter json:` writes
#    it: one event per line. Hidden passing load tests are not tests; a
#    failing load test (a compile error) is an error with no line.
report="$work/flutter.json"
cat >"$report" <<JSON
{"protocolVersion":"0.1.1","runnerVersion":null,"pid":42,"type":"start","time":0}
{"suite":{"id":0,"platform":"vm","path":"$tree/test/widget_test.dart"},"type":"suite","time":0}
{"test":{"id":1,"name":"loading $tree/test/widget_test.dart","suiteID":0,"groupIDs":[],"metadata":{"skip":false,"skipReason":null},"line":null,"column":null,"url":null},"type":"testStart","time":1}
{"testID":1,"result":"success","skipped":false,"hidden":true,"type":"testDone","time":90}
{"group":{"id":2,"suiteID":0,"parentID":null,"name":"","metadata":{"skip":false,"skipReason":null},"testCount":4,"line":null,"column":null,"url":null},"type":"group","time":91}
{"test":{"id":3,"name":"counter increments","suiteID":0,"groupIDs":[2],"metadata":{"skip":false,"skipReason":null},"line":10,"column":3,"url":"file://$tree/test/widget_test.dart"},"type":"testStart","time":92}
{"testID":3,"messageType":"print","message":"tapped","type":"print","time":95}
{"testID":3,"result":"success","skipped":false,"hidden":false,"type":"testDone","time":100}
{"test":{"id":4,"name":"counter starts at zero","suiteID":0,"groupIDs":[2],"metadata":{"skip":false,"skipReason":null},"line":20,"column":3,"url":"file://$tree/test/widget_test.dart"},"type":"testStart","time":101}
{"testID":4,"error":"Expected: <0>\n  Actual: <1>","stackTrace":"package:app/main_test.dart 21:5","isFailure":true,"type":"error","time":110}
{"testID":4,"result":"failure","skipped":false,"hidden":false,"type":"testDone","time":111}
{"test":{"id":5,"name":"pending feature","suiteID":0,"groupIDs":[2],"metadata":{"skip":true,"skipReason":"later"},"line":30,"column":3,"url":"file://$tree/test/widget_test.dart"},"type":"testStart","time":112}
{"testID":5,"result":"success","skipped":true,"hidden":false,"type":"testDone","time":113}
{"test":{"id":6,"name":"shared helper throws","suiteID":0,"groupIDs":[2],"metadata":{"skip":false,"skipReason":null},"line":40,"column":5,"url":"file://$tree/test/helpers/shared.dart","root_line":33,"root_column":3,"root_url":"file://$tree/test/widget_test.dart"},"type":"testStart","time":114}
{"testID":6,"error":"Bad state: no element","stackTrace":"dart:core Iterable.first","isFailure":false,"type":"error","time":120}
{"testID":6,"result":"error","skipped":false,"hidden":false,"type":"testDone","time":121}
not a json line
{"suite":{"id":7,"platform":"vm","path":"$tree/test/broken_test.dart"},"type":"suite","time":122}
{"test":{"id":8,"name":"loading $tree/test/broken_test.dart","suiteID":7,"groupIDs":[],"metadata":{"skip":false,"skipReason":null},"line":null,"column":null,"url":null},"type":"testStart","time":123}
{"testID":8,"error":"Failed to load: compilation failed","stackTrace":"","isFailure":false,"type":"error","time":130}
{"testID":8,"result":"error","skipped":false,"hidden":false,"type":"testDone","time":131}
{"success":false,"type":"done","time":140}
JSON

CI_RUN_ID=01234567-89ab-cdef-0123-456789abcdef
status=failed
last_log='test'

if ! summarise flutter "$report"; then
    fail 'summarise flutter exited non-zero'
fi
build_payload
results="$state/results.json"

counts="$(jq -c '.counts' "$results")"
if [ "$counts" != '{"tests":5,"failures":1,"errors":2,"skipped":1}' ]; then
    fail "flutter counts are $counts"
fi
pass 'flutter counts: 5 tests, 1 failure, 2 errors, 1 skipped'

failures="$(jq -c '[.failures[] | [.file, .line, .name]]' "$results")"
expected='[["test/widget_test.dart",20,"counter starts at zero"],'
expected+='["test/widget_test.dart",33,"shared helper throws"],'
expected+='["test/broken_test.dart",0,"loading test/broken_test.dart"]]'
if [ "$failures" != "$expected" ]; then
    fail "flutter failures are $failures"
fi
pass 'flutter failures carry the repository-relative file and the root line'

if ! jq -e '.failures[0].message | contains("Expected: <0>") and contains("21:5")' "$results" >/dev/null; then
    fail 'the failure message lost the error or its stack trace'
fi
pass 'flutter failure message carries the error and the stack trace'

if ! jq -e '.ci_run_id == "01234567-89ab-cdef-0123-456789abcdef" and .status == "failed"' "$results" >/dev/null; then
    fail 'the payload lost the run id or the status'
fi
pass 'payload carries the run id and the status'

[ "$(jq -c '.slow_tests' "$state/summary.json")" = '[]' ] || fail 'a fast flutter run reported slow tests'
report="$work/flutter-slow.json"
cat >"$report" <<JSON
{"suite":{"id":0,"platform":"vm","path":"$tree/test/slow_test.dart"},"type":"suite","time":0}
{"test":{"id":1,"name":"renders the big list","suiteID":0,"groupIDs":[],"metadata":{"skip":false,"skipReason":null},"line":7,"column":3,"url":"file://$tree/test/slow_test.dart"},"type":"testStart","time":1000}
{"testID":1,"result":"success","skipped":false,"hidden":false,"type":"testDone","time":3500}
{"test":{"id":2,"name":"is quick","suiteID":0,"groupIDs":[],"metadata":{"skip":false,"skipReason":null},"line":9,"column":3,"url":"file://$tree/test/slow_test.dart"},"type":"testStart","time":3500}
{"testID":2,"result":"success","skipped":false,"hidden":false,"type":"testDone","time":3600}
JSON
summarise flutter "$report" || fail 'summarise flutter exited non-zero on the slow report'
slow="$(jq -c '.slow_tests' "$state/summary.json")"
[ "$slow" = '[{"name":"renders the big list","file":"test/slow_test.dart","line":7,"seconds":2.5}]' ] \
    || fail "flutter slow tests are $slow"
pass 'flutter slow tests come from the reporter times'

# The private log gets each test class's summed seconds, slowest first, so
# the shard split can be measured against real class durations.
report="$work/junit.xml"
cat >"$report" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="" tests="4" time="4.75">
    <testsuite name="Tests\\Unit\\FastTest" file="$tree/tests/Unit/FastTest.php" tests="1" time="0.25">
      <testcase name="test_a" class="Tests\\Unit\\FastTest" file="$tree/tests/Unit/FastTest.php" line="9" time="0.25"/>
    </testsuite>
    <testsuite name="Tests\\Feature\\SlowTest" file="$tree/tests/Feature/SlowTest.php" tests="2" time="3.5">
      <testcase name="test_b" class="Tests\\Feature\\SlowTest" file="$tree/tests/Feature/SlowTest.php" line="9" time="1.5"/>
      <testcase name="test_c" class="Tests\\Feature\\SlowTest" file="$tree/tests/Feature/SlowTest.php" line="19" time="2"/>
    </testsuite>
    <testsuite name="Tests\\Unit\\MidTest" file="$tree/tests/Unit/MidTest.php" tests="1" time="1">
      <testcase name="test_d" class="Tests\\Unit\\MidTest" file="$tree/tests/Unit/MidTest.php" line="9" time="1"/>
    </testsuite>
  </testsuite>
</testsuites>
XML

rm -f "$state/timings.log"
class_timings "$report"
expected=$'3.500 Tests\\Feature\\SlowTest\n1.000 Tests\\Unit\\MidTest\n0.250 Tests\\Unit\\FastTest'
if [ "$(cat "$state/timings.log")" != "$expected" ]; then
    fail "class timings are $(cat "$state/timings.log")"
fi
pass 'class timings sum each class, slowest first'

printf 'not xml' >"$report"
rm -f "$state/timings.log"
class_timings "$report"
if [ -e "$state/timings.log" ]; then
    fail 'an unreadable report left a timings log'
fi
pass 'an unreadable report leaves no timings log'

# The results carry the slowest test cases (2 s and up) and the summed seconds
# of every class, so the server can warn about slow tests and split the next
# run's shards by duration.
report="$work/junit-times.xml"
cat >"$report" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="" tests="3" time="4.5">
    <testsuite name="Tests\\Feature\\SlowTest" file="$tree/tests/Feature/SlowTest.php" tests="2" time="3.5">
      <testcase name="test_b" class="Tests\\Feature\\SlowTest" file="$tree/tests/Feature/SlowTest.php" line="9" time="1.5"/>
      <testcase name="test_c" class="Tests\\Feature\\SlowTest" file="$tree/tests/Feature/SlowTest.php" line="19" time="2.25"/>
    </testsuite>
    <testsuite name="Tests\\Unit\\MidTest" file="$tree/tests/Unit/MidTest.php" tests="1" time="1">
      <testcase name="test_d" class="Tests\\Unit\\MidTest" file="$tree/tests/Unit/MidTest.php" line="9" time="1"/>
    </testsuite>
  </testsuite>
</testsuites>
XML

if ! summarise junit "$report"; then
    fail 'summarise junit exited non-zero'
fi
slow="$(jq -c '.slow_tests' "$state/summary.json")"
expected='[{"name":"Tests\\Feature\\SlowTest::test_c","file":"tests/Feature/SlowTest.php","line":19,"seconds":2.25}]'
[ "$slow" = "$expected" ] || fail "slow tests are $slow"
jq -e '.class_timings == {"Tests\\Feature\\SlowTest": 3.75, "Tests\\Unit\\MidTest": 1}' "$state/summary.json" \
    >/dev/null || fail "class timings are $(jq -c '.class_timings' "$state/summary.json")"
pass 'the junit summary carries the slow test cases and the class timings'

status=passed
last_log=''
build_payload
jq -e '.slow_tests[0].seconds == 2.25 and .class_timings["Tests\\Unit\\MidTest"] == 1' "$state/results.json" \
    >/dev/null || fail 'the results payload lost the slow tests or the class timings'
pass 'the results payload carries the slow tests and the class timings'

# A shard plan deals the classes PHPUnit lists to the shards by measured
# duration, slowest first onto the least loaded shard; a class without a
# timing counts as the median. Every shard computes the same plan.
list="$work/list-tests.txt"
cat >"$list" <<'TXT'
PHPUnit 13.4.5 by Sebastian Bergmann and contributors.

Available tests:
 - Tests\Unit\AaTest::test_one
 - Tests\Unit\AaTest::test_two with data set #0
 - Tests\Unit\BbTest::test_x
 - Tests\Feature\CcTest::test_y
 - Tests\Feature\DdTest::test_z
 - Tests\Feature\NewTest::test_new
TXT
printf '%s\n' '{"Tests\\Unit\\AaTest": 10, "Tests\\Unit\\BbTest": 6, "Tests\\Feature\\CcTest": 5,' \
    '"Tests\\Feature\\DdTest": 1, "Tests\\Feature\\GoneTest": 99}' >"$work/plan-timings.json"

first="$(plan_shard "$list" "$work/plan-timings.json" 1 2)" || fail 'plan_shard refused shard 1'
second="$(plan_shard "$list" "$work/plan-timings.json" 2 2)" || fail 'plan_shard refused shard 2'
[ "$first" = '{^(?:Tests\\Unit\\AaTest|Tests\\Feature\\CcTest)::}' ] || fail "shard 1 filter is $first"
[ "$second" = '{^(?:Tests\\Unit\\BbTest|Tests\\Feature\\NewTest|Tests\\Feature\\DdTest)::}' ] \
    || fail "shard 2 filter is $second"
pass 'plan_shard splits by duration, counts an unknown class as the median and skips a gone class'

printf 'Available tests:\n' >"$work/empty-list.txt"
if plan_shard "$work/empty-list.txt" "$work/plan-timings.json" 1 2 >/dev/null; then
    fail 'plan_shard planned an empty list'
fi
if plan_shard "$list" "$work/missing.json" 1 2 >/dev/null; then
    fail 'plan_shard planned without timings'
fi
if plan_shard "$list" "$work/plan-timings.json" 1 6 >/dev/null; then
    fail 'plan_shard planned more shards than classes'
fi
{
    printf 'Available tests:\n'
    for index in $(seq 1 3000); do
        printf ' - Tests\\Feature\\Generated\\Deeply\\Nested\\Namespace\\GeneratedNumber%04dTest::test_it\n' "$index"
    done
} >"$work/huge-list.txt"
printf '{"Tests\\\\Unit\\\\AaTest": 1}' >"$work/huge-timings.json"
for index in 1 2; do
    if plan_shard "$work/huge-list.txt" "$work/huge-timings.json" "$index" 2 >/dev/null; then
        fail "plan_shard handed shard $index a filter PCRE cannot compile"
    fi
done
pass 'plan_shard refuses an empty list, missing timings, too few classes or a filter PCRE cannot compile'

# Every sandboxed command's log ends with how long it took, and the command's
# own exit code survives the bookkeeping.
mkdir -p "$work/sandbox-shim"
cat >"$work/sandbox-shim/ci-sandbox" <<'SH'
#!/usr/bin/env bash
printf 'ran\n' >>"$1"
exit 3
SH
chmod +x "$work/sandbox-shim/ci-sandbox"
saved_sandbox_path="$PATH"
PATH="$work/sandbox-shim:$PATH"
code=0
sandboxed demo "$work" -- true || code=$?
PATH="$saved_sandbox_path"
[ "$code" = 3 ] || fail "sandboxed returned $code, not the command's 3"
[ "$(cat "$state/demo.log")" = 'ran' ] || fail 'the command log holds more than the command output'
grep -qE '^demo took [0-9]+\.[0-9] s$' "$state/durations.log" || fail 'the durations log has no line for demo'
pass 'a sandboxed command gets a durations line, its own log stays untouched and the exit code is kept'

# 3. The scope script in pr mode is the base commit's, never the head's: a
#    pull request must not be able to rewrite the rules that judge it.
tree="$work/repo"
scope_file="$work/scope-script"
stack=laravel
mkdir -p "$tree/.github/scripts"
printf '{"scope_script": ".github/scripts/ci-scope.sh"}\n' >"$state/stack.json"

commit_all() {
    git -C "$tree" add -A
    GIT_AUTHOR_NAME=ci GIT_AUTHOR_EMAIL=ci@example.invalid \
        GIT_COMMITTER_NAME=ci GIT_COMMITTER_EMAIL=ci@example.invalid \
        git -C "$tree" -c commit.gpgsign=false commit --quiet -m "$1"
    git -C "$tree" rev-parse HEAD
}

git init --quiet "$tree"
printf 'echo php=full\n' >"$tree/.github/scripts/ci-scope.sh"
base_sha="$(commit_all base)"
printf 'echo php=none\n' >"$tree/.github/scripts/ci-scope.sh"
head_sha="$(commit_all head)"

mode='pr'
stage_scope_script
if [ "$(cat "$scope_file" 2>/dev/null)" != 'echo php=full' ]; then
    fail 'pr mode did not stage the base commit scope script'
fi
pass 'pr mode stages the base commit scope script'

mode=main
stage_scope_script
if [ -e "$scope_file" ]; then
    fail 'main mode staged a scope script'
fi
pass 'main mode leaves the head scope script in place'

mode='pr'
base_sha=''
stage_scope_script
if [ -e "$scope_file" ]; then
    fail 'pr mode without a base staged a scope script'
fi
pass 'pr mode without a base stages nothing'

git -C "$tree" rm --quiet .github/scripts/ci-scope.sh
base_sha="$(commit_all without-script)"
stage_scope_script
if [ -e "$scope_file" ]; then
    fail 'pr mode staged a scope script the base does not have'
fi
pass 'pr mode stages nothing when the base has no scope script'

# 4. The API host and both audiences have no default: every pool names its
#    own, so a missing one stops the job before anything touches the network.
expect_unset_refused() {
    local missing="$1"
    local names=(CI_API CI_TOKEN_AUDIENCE CI_RESULTS_AUDIENCE)
    local env_args=(
        CI_RUN_ID=01234567-89ab-cdef-0123-456789abcdef
        CI_JOB_NAME=lint
    )
    local name
    local code=0
    local stderr_file="$work/unset.stderr"

    for name in "${names[@]}"; do
        if [ "$name" != "$missing" ]; then
            env_args+=("$name=https://example.invalid")
        fi
    done

    env -i PATH="$PATH" "${env_args[@]}" bash "$here/../ci-job" prepare 2>"$stderr_file" || code=$?

    [ "$code" -eq 2 ] || fail "ci-job exited $code without $missing, expected 2"
    grep -qF "ci: $missing is not set" "$stderr_file" || fail "ci-job did not name $missing as missing"
    pass "ci-job refuses to start without $missing"
}

expect_unset_refused CI_API
expect_unset_refused CI_TOKEN_AUDIENCE
expect_unset_refused CI_RESULTS_AUDIENCE

# 5. Source delivery. A git shim records every argv and, for a fetch, git's
#    environment; ci-post is a function that answers the OIDC request and the
#    token exchange from a fixture and records the revocation. Without
#    `features` the fetch is today's: github.com, askpass, api.github.com
#    revocation. With features.git_proxy it goes through the Worker's /git
#    with the ticket and Basic auth as http.extraHeader values in git's
#    environment, never in argv.
real_git="$(command -v git)"
shim="$work/shim"
secret="$work/secret"
public="$work/public.log"
mkdir -p "$shim" "$secret"

cat >"$shim/git" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$work/git.argv"
case " \$* " in
    *' fetch '*)
        env | grep '^GIT_' | sort >>"$work/git.env"
        exit 0
        ;;
    *' checkout '*) exit 0 ;;
esac
exec "$real_git" "\$@"
SH
chmod +x "$shim/git"

ci-post() {
    local method=''

    if [ "$1" = -X ]; then
        method="$2"
        shift 2
    fi
    printf '%s %s\n' "${method:-POST}" "$1" >>"$work/ci-post.argv"

    case "$1" in
        https://oidc.example.invalid/*) printf '{"value":"aaa.bbb.ccc"}' >"$3" ;;
        */api/ci/token) cp "$work/token-response.json" "$3" ;;
        *) cp "$2" "$work/revoke.curl" ;;
    esac
}

source_token='ghs_sourcetoken0123456789'
ticket="v1.eyJyIjoiYWNtZS93aWRnZXRzIiwiZSI6MTc2NzIyNTYwMH0.$(printf 'a%.0s' $(seq 1 64))"
namespace=0123456789abcdef
fetch_sha=1111111111111111111111111111111111111111
basic="$(printf 'x-access-token:%s' "$source_token" | base64 | tr -d '\n')"

# usage: token_response <extra-json>   (merged into a valid lint response)
token_response() {
    jq -n \
        --arg token "$source_token" \
        --arg sha "$fetch_sha" \
        --arg namespace "$namespace" \
        --argjson extra "$1" \
        '{
            token: $token,
            repository: "acme/widgets",
            head_sha: $sha,
            base_sha: null,
            mode: "main",
            role: "lint",
            shard: 1,
            shards: 1,
            stack: "laravel",
            cache_namespace: $namespace,
            manifest: {version: 1, stacks: {laravel: {dir: ".", setup: [], lint: ["true"], test: {shards: 1}}}},
        } + $extra' >"$work/token-response.json"
}

# usage: deliver <extra-json>   runs exchange, fetch and revocation like prepare
deliver() {
    token_response "$1"
    rm -rf "$tree" "$work/git.argv" "$work/git.env" "$work/ci-post.argv" "$work/revoke.curl" "${secret:?}"/*
    git_proxy=false
    log_upload=false
    exchange_token
    fetch_source
    revoke_token
}

saved_path="$PATH"
PATH="$shim:$PATH"
tree="$work/delivery"
api=https://edge.example.invalid
token_audience=token-audience
CI_JOB_NAME=lint
ACTIONS_ID_TOKEN_REQUEST_URL='https://oidc.example.invalid/request?x=1'
ACTIONS_ID_TOKEN_REQUEST_TOKEN=request-token
exec 3>"$public"

expected_fetch="-C $tree -c credential.helper= fetch --quiet --no-tags --depth=1 origin $fetch_sha"

deliver '{}'
[ "$("$real_git" config -f "$tree/.git/config" remote.origin.url)" = https://github.com/acme/widgets.git ] \
    || fail 'without features the remote is not github.com'
[ "$(grep ' fetch ' "$work/git.argv")" = "$expected_fetch" ] || fail 'without features the fetch argv changed'
grep -qxF "GIT_ASKPASS=$secret/askpass" "$work/git.env" || fail 'without features git lost its askpass'
if grep -q '^GIT_CONFIG_' "$work/git.env"; then
    fail 'without features git got config from the environment'
fi
grep -qxF 'DELETE https://api.github.com/installation/token' "$work/ci-post.argv" \
    || fail 'without features the token is not revoked at api.github.com'
if grep -q 'X-Ci-Ticket' "$work/revoke.curl"; then
    fail 'without features the revocation carries a ticket'
fi
[ "$git_proxy" = false ] && [ "$log_upload" = false ] || fail 'features defaulted to on'
[ ! -e "$secret/redact" ] || fail 'without features a redaction list was written'
pass 'without features the fetch and the revocation are unchanged'

deliver "$(jq -n --arg ticket "$ticket" '{features: {git_proxy: true, log_upload: true}, git_ticket: $ticket}')"
[ "$("$real_git" config -f "$tree/.git/config" remote.origin.url)" = "$api/git" ] \
    || fail 'with git_proxy the remote is not the Worker'
[ "$(grep ' fetch ' "$work/git.argv")" = "$expected_fetch" ] || fail 'with git_proxy the fetch argv changed'
for secret_value in "$source_token" "$ticket" "$basic" acme/widgets; do
    if grep -qF -- "$secret_value" "$work/git.argv"; then
        fail 'with git_proxy a secret or the repository reached git argv'
    fi
done
expected_env="$(
    printf '%s\n' \
        GIT_CONFIG_COUNT=2 \
        GIT_CONFIG_KEY_0=http.extraHeader \
        GIT_CONFIG_KEY_1=http.extraHeader \
        "GIT_CONFIG_VALUE_0=X-Ci-Ticket: $ticket" \
        "GIT_CONFIG_VALUE_1=Authorization: Basic $basic"
)"
[ "$(grep '^GIT_CONFIG_' "$work/git.env")" = "$expected_env" ] \
    || fail 'with git_proxy the ticket and Basic auth are not http.extraHeader values'
if grep -q '^GIT_ASKPASS=' "$work/git.env"; then
    fail 'with git_proxy git still got an askpass'
fi
grep -qxF "DELETE $api/gh-token" "$work/ci-post.argv" || fail 'with git_proxy the token is not revoked through the Worker'
grep -qxF "header = \"X-Ci-Ticket: $ticket\"" "$work/revoke.curl" || fail 'the Worker revocation lacks the ticket'
grep -qxF "header = \"Authorization: Bearer $source_token\"" "$work/revoke.curl" \
    || fail 'the Worker revocation lacks the token'
[ ! -e "$secret/git-ticket" ] || fail 'the ticket outlived the revocation'
[ "$log_upload" = true ] || fail 'features.log_upload was not read'
for secret_value in "$source_token" "$ticket" "$namespace"; do
    grep -qxF -- "$secret_value" "$secret/redact" || fail 'the redaction list misses a secret'
done
pass 'with git_proxy git reaches the Worker with the ticket and Basic auth in its environment only'

for broken in '{features: {git_proxy: true}}' '{features: {git_proxy: true}, git_ticket: "v1.x.y"}'; do
    token_response "$(jq -n "$broken")"
    rm -rf "$tree"
    if exchange_token; then
        fail "exchange_token accepted git_proxy with $broken"
    fi
done
grep -qF '(git_ticket)' "$public" || fail 'a missing ticket was not named'
token_response '{"features": {"git_proxy": "yes"}}'
rm -rf "$tree"
if exchange_token; then
    fail 'exchange_token accepted a non-boolean feature'
fi
grep -qF '(features)' "$public" || fail 'a malformed features object was not named'
pass 'git_proxy without a well-formed ticket, or a non-boolean feature, is refused'

# A manifest may split a stack's tests over up to eight shards.
for stack in laravel flutter; do
    for shards in 8 9; do
        token_response "$(jq -n --arg stack "$stack" --argjson shards "$shards" '{
            stack: $stack,
            role: (if $stack == "flutter" then "flutter-lint" else "lint" end),
            manifest: {version: 1, stacks: {($stack): {dir: ".", setup: [], lint: ["true"], test: {shards: $shards}}}},
        }')"
        rm -rf "$tree"
        if exchange_token; then
            accepted=yes
        else
            accepted=no
        fi
        if [ "$shards" = 8 ] && [ "$accepted" != yes ]; then
            fail "exchange_token refused a $stack manifest with 8 shards"
        fi
        if [ "$shards" = 9 ] && [ "$accepted" != no ]; then
            fail "exchange_token accepted a $stack manifest with 9 shards"
        fi
    done
done
pass 'a manifest takes 1 to 8 shards per stack'

# The token response's class timings are kept for the shard plan, minus any
# entry that is not a class name with a non-negative number.
token_response '{"class_timings": {"Tests\\Unit\\AaTest": 2.5, "../escape": 1, "Tests\\Unit\\BbTest": -1}}'
rm -rf "$tree"
exchange_token || fail 'exchange_token refused a response with class timings'
jq -e '. == {"Tests\\Unit\\AaTest": 2.5}' "$state/class-timings.json" >/dev/null \
    || fail "kept class timings are $(cat "$state/class-timings.json")"
token_response '{}'
rm -rf "$tree"
exchange_token || fail 'exchange_token refused a response without class timings'
jq -e '. == {}' "$state/class-timings.json" >/dev/null || fail 'a response without timings left some behind'
pass 'class timings from the token response are filtered and kept for the shard plan'

for secret_value in "$source_token" "$ticket" acme/widgets; do
    if grep -qF -- "$secret_value" "$public"; then
        fail 'a secret or the repository reached the public log'
    fi
done
pass 'the public log carries no token, ticket or repository name'

exec 3>/dev/null
PATH="$saved_path"
unset -f ci-post

# 6. Log upload, end to end through the real ci-post against a php -S fake
#    API: a gzip body under 8 MiB holding the tail of every phase log, with the
#    token, the ticket and the cache namespace replaced, and an upload failure
#    that leaves the job's outcome alone.
cat >"$work/api.php" <<'PHP'
<?php

$state = getenv('CI_TEST_STATE');
$path = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);
header('Content-Type: application/json');

if ($path === '/health') {
    http_response_code(204);

    return true;
}

if ($path === '/oidc') {
    echo '{"value":"aaa.bbb.ccc"}';

    return true;
}

if ($path === '/api/ci/results') {
    echo '{"ok":true}';

    return true;
}

if ($path === '/api/ci/logs') {
    file_put_contents("{$state}/logs.count", '.', FILE_APPEND);
    file_put_contents("{$state}/logs.body", file_get_contents('php://input'));
    file_put_contents("{$state}/logs.headers", json_encode([
        'authorization' => $_SERVER['HTTP_AUTHORIZATION'] ?? '',
        'content_type' => $_SERVER['CONTENT_TYPE'] ?? '',
        'content_length' => (int) ($_SERVER['CONTENT_LENGTH'] ?? -1),
        'run' => $_SERVER['HTTP_X_CI_RUN'] ?? '',
        'job' => $_SERVER['HTTP_X_CI_JOB'] ?? '',
    ]));
    $status = is_file("{$state}/logs.reply") ? (int) file_get_contents("{$state}/logs.reply") : 201;
    http_response_code($status);
    echo $status === 201 ? '{"stored":true}' : '{"error":"refused"}';

    return true;
}

http_response_code(404);

return true;
PHP

api_state="$work/api-state"
mkdir -p "$api_state"
api_pid=''
for _ in 1 2 3 4 5; do
    api_port=$((20000 + RANDOM % 20000))
    CI_TEST_STATE="$api_state" php -d post_max_size=64M -S "127.0.0.1:$api_port" "$work/api.php" \
        >"$work/api.log" 2>&1 &
    api_pid=$!
    for _ in $(seq 1 50); do
        if curl -fsS -o /dev/null "http://127.0.0.1:$api_port/health" 2>/dev/null; then
            break 2
        fi
        sleep 0.1
    done
    kill "$api_pid" 2>/dev/null || true
    api_pid=''
done
[ -n "$api_pid" ] || fail 'the fake API never started'
trap 'kill "$api_pid" 2>/dev/null || true; rm -rf "$work"' EXIT

ci-sandbox() {
    return 0
}

PATH="$here/..:$PATH"
state="$work/upload-state"
secret="$work/upload-secret"
mkdir -p "$state" "$secret"
api="http://127.0.0.1:$api_port"
results_audience='results-audience'
ACTIONS_ID_TOKEN_REQUEST_URL="$api/oidc?x=1"
ACTIONS_ID_TOKEN_REQUEST_TOKEN=request-token
CI_JOB_NAME='test (2)'
export CI_RUN_ID CI_JOB_NAME
printf '%s\n' "$source_token" "$basic" "$ticket" "$namespace" >"$secret/redact"
{
    echo "fetching with $source_token and $ticket"
    echo "cache ci-$namespace-laravel-abc"
} >"$state/prepare.log"
touch -t 202601010000 "$state/prepare.log"
{
    head -c 12582912 /dev/urandom | base64
    echo 'END-OF-TEST-LOG'
} >"$state/test.log"
write_empty_summary
status=failed
last_log='test'

# usage: run_report   prints the exit code of report, run as the job runs it
run_report() {
    local code=0

    : >"$public"
    exec 3>>"$public"
    set +e
    (
        set -e
        report
    )
    code=$?
    set -e
    exec 3>/dev/null
    echo "$code"
}

log_upload=true
[ "$(run_report)" = 0 ] || fail 'report failed with log upload on'
grep -qxF 'ci: results sent' "$public" || fail 'results were not sent before the logs'
grep -qxF 'ci: logs sent' "$public" || fail 'the logs were not reported as sent'
headers="$api_state/logs.headers"
jq -e --arg run "$CI_RUN_ID" '
    .authorization == "Bearer aaa.bbb.ccc"
    and .content_type == "application/gzip"
    and .run == $run
    and .job == "test (2)"
    and .content_length > 0 and .content_length <= 8388608
' "$headers" >/dev/null || fail "the logs request headers are $(cat "$headers")"
[ "$(wc -c <"$api_state/logs.body")" -le 8388608 ] || fail 'the logs body exceeds 8 MiB'
gzip -dc "$api_state/logs.body" >"$work/logs.txt" || fail 'the logs body is not gzip'
[ "$(tail -n 1 "$work/logs.txt")" = END-OF-TEST-LOG ] || fail 'the logs lost their tail'
if grep -qxF '== prepare ==' "$work/logs.txt"; then
    fail 'the cut kept the head of a log over the cap'
fi
for secret_value in "$source_token" "$ticket" "$namespace" "$basic"; do
    if grep -qF -- "$secret_value" "$work/logs.txt"; then
        fail 'a secret reached the uploaded logs'
    fi
done
pass 'logs go up as gzip under 8 MiB, tail kept, with the run and job headers and no secret'

echo 'short run' >"$state/test.log"
[ "$(run_report)" = 0 ] || fail 'report failed with a small log'
gzip -dc "$api_state/logs.body" >"$work/logs.txt"
grep -qxF '== prepare ==' "$work/logs.txt" || fail 'the prepare phase has no heading'
grep -qF "fetching with [redacted] and [redacted]" "$work/logs.txt" || fail 'the token and ticket were not replaced'
grep -qF 'cache ci-[redacted]-laravel-abc' "$work/logs.txt" || fail 'the cache namespace was not replaced'
[ "$(grep -n '^== ' "$work/logs.txt" | cut -d: -f2 | tr '\n' ' ')" = '== prepare == == test == ' ] \
    || fail 'the phase logs are not in the order they were written'
pass 'every phase log goes up under its own heading, oldest first, secrets replaced'

printf '413' >"$api_state/logs.reply"
[ "$(run_report)" = 0 ] || fail 'a refused log upload failed the job'
grep -qxF 'ci: logs not sent (HTTP 413)' "$public" || fail 'the refused upload was not reported'
pass 'a refused log upload leaves the job outcome alone'

uploads="$(wc -c <"$api_state/logs.count" | tr -d ' ')"
log_upload=false
[ "$(run_report)" = 0 ] || fail 'report failed with log upload off'
[ "$(wc -c <"$api_state/logs.count" | tr -d ' ')" = "$uploads" ] || fail 'logs went up with log upload off'
if grep -qF 'logs' "$public"; then
    fail 'the public log mentions logs with log upload off'
fi
pass 'without log_upload nothing is uploaded'

PATH="$saved_path"
unset -f ci-sandbox

# 7. The failure tail of a run without a parsed report centres on the failure
#    markers, so a failing test's name survives thousands of progress lines
#    (watchools PR 254: the last 2000 bytes were all noise).
state="$work/tail-state"
mkdir -p "$state"
{
    for i in $(seq 1 200); do
        echo "00:0$((i % 10)) +$i ~1: Wind alias color-$i shadows a built-in token"
    done
    echo '00:12 +4306 ~1 -1: test/cart_test.dart: cart total rounds down [E]'
    echo '  Expected: <10>'
    echo '    Actual: <11>'
    for i in $(seq 1 200); do
        echo "00:1$((i % 10)) +$i ~1 -1: Wind alias size-$i shadows a built-in token"
    done
    echo '00:14 +4306 ~1 -2: test/login_test.dart: login keeps the session [E]'
    for i in $(seq 1 200); do
        echo "00:2$((i % 10)) +$i ~1 -2: Wind alias gap-$i shadows a built-in token"
    done
} >"$state/test.log"
write_empty_summary
status=failed
last_log='test'
build_payload
message="$(jq -r '.failures[0].message' "$state/results.json")"
[[ "$message" == *'cart total rounds down [E]'* ]] || fail 'the tail lost the first failing test'
[[ "$message" == *'Expected: <10>'* ]] || fail 'the tail lost the failure detail'
[[ "$message" == *'login keeps the session [E]'* ]] || fail 'the tail lost the second failing test'
[ "${#message}" -le 2000 ] || fail 'the tail exceeds 2000 characters'
pass 'the failure tail centres on the failure markers'

seq 1 2000 >"$state/test.log"
build_payload
[ "$(jq -r '.failures[0].message' "$state/results.json")" = "$(tail -c 2000 "$state/test.log")" ] \
    || fail 'a log without markers did not fall back to its last 2000 bytes'
pass 'a log without failure markers keeps the last 2000 bytes'

# 8. A flutter test override without --file-reporter leaves the summariser
#    nothing to read, so the JSON reporter is added after `flutter test`.
flutter_command() {
    jq -n --arg command "$1" 'if $command == "" then {test: {}} else {test: {command: $command}} end' \
        >"$state/stack.json"
    flutter_test_command
}

reporter='--file-reporter "json:$CI_REPORT_DIR/flutter.json"'
[ "$(flutter_command 'flutter test --coverage')" = "flutter test $reporter --coverage" ] \
    || fail "an override without a reporter became $(flutter_command 'flutter test --coverage')"
[ "$(flutter_command 'cd app && flutter test')" = "cd app && flutter test $reporter" ] \
    || fail 'a chained override did not get the reporter'
kept='flutter test --file-reporter json:out.json'
[ "$(flutter_command "$kept")" = "$kept" ] || fail 'an override with its own reporter was changed'
[ "$(flutter_command 'melos run test')" = 'melos run test' ] || fail 'a non-flutter-test override was changed'
default='flutter test --total-shards "$CI_SHARDS" --shard-index "$((CI_SHARD - 1))" '
default+='--file-reporter "json:$CI_REPORT_DIR/flutter.json"'
[ "$(flutter_command '')" = "$default" ] || fail 'the default flutter test command changed'
pass 'a flutter test override gets the JSON file reporter when it lacks one'

# 9. sync-neutral-images: a dry run copies and checks the image sources and
#    commits once as the neutral identity without touching the network; a
#    source carrying an owner string is refused before any commit.
sync="$here/../sync-neutral-images"
code=0
"$sync" --dry-run >"$work/sync.out" 2>&1 || code=$?
[ "$code" -eq 0 ] || fail "the dry run on this repository exited $code: $(cat "$work/sync.out")"
grep -qxF 'author: multi-progs <263353081+multi-progs@users.noreply.github.com>' "$work/sync.out" \
    || fail 'the dry run did not commit as the neutral identity'
for file in Dockerfile Dockerfile.flutter scripts/ci-job scripts/ci-post .github/workflows/build.yml; do
    grep -qxF "  $file" "$work/sync.out" || fail "the dry run did not copy $file"
done
grep -qxF 'dry run: stopping before push' "$work/sync.out" || fail 'the dry run did not stop before push'
pass 'sync-neutral-images --dry-run copies the image sources and commits once as multi-progs'

source_root="$work/sync-source"
mkdir -p "$source_root/scripts" "$source_root/.github/workflows"
for file in Dockerfile Dockerfile.flutter scripts/ci-job scripts/ci-post scripts/ci-probe scripts/ci-sandbox \
    .github/workflows/build.yml; do
    cp "$here/../../$file" "$source_root/$file"
done
echo '# maintained by KODIZM' >>"$source_root/scripts/ci-post"
code=0
CI_IMAGES_SOURCE="$source_root" "$sync" --dry-run >"$work/sync.out" 2>&1 || code=$?
[ "$code" -ne 0 ] || fail 'a source with an owner string was synced'
grep -qxF '  scripts/ci-post' "$work/sync.out" || fail 'the refused file was not named'
if grep -q 'author:' "$work/sync.out"; then
    fail 'a refused sync still committed'
fi
pass 'sync-neutral-images refuses a source carrying an owner string'

# 10. A fetch that meets a transient refusal (a 429 or a 5xx from GitHub or the
# Worker) is tried again after a growing pause, three tries in all; a refusal
# that lasts fails the job.
fetch_attempts="$work/fetch-attempts"
fetch_failures=2
git_with_token() {
    echo "$*" >>"$fetch_attempts"
    [ "$(wc -l <"$fetch_attempts")" -gt "$fetch_failures" ]
}
sleep() {
    echo "$1" >>"$work/slept"
}
fetch_commit "$(printf 'a%.0s' {1..40})" || fail 'a fetch that fails twice then succeeds was given up'
[ "$(wc -l <"$fetch_attempts")" -eq 3 ] || fail "the fetch ran $(wc -l <"$fetch_attempts") times, not 3"
[ "$(paste -sd, "$work/slept")" = "$((CI_FETCH_BACKOFF_SECONDS)),$((CI_FETCH_BACKOFF_SECONDS * 2))" ] \
    || fail "the pauses were $(paste -sd, "$work/slept")"
grep -q -- '--depth=1 origin a\{40\}$' "$fetch_attempts" || fail 'the retried fetch lost its arguments'
pass 'a transient fetch failure is retried with a growing pause'

rm -f "$fetch_attempts" "$work/slept"
fetch_failures=9
if fetch_commit "$(printf 'b%.0s' {1..40})"; then
    fail 'a fetch that keeps failing succeeded'
fi
[ "$(wc -l <"$fetch_attempts")" -eq 3 ] || fail 'a lasting refusal was tried more than three times'
pass 'a lasting fetch failure gives up after three tries'
unset -f git_with_token sleep

echo 'PASS ci-job.test.sh'
