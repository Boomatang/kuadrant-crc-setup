#!/usr/bin/env fish

set SCRIPT_DIR (cd (dirname (status filename)); and pwd)
set CONFIG_FILE $SCRIPT_DIR/config.json

if not test -f $CONFIG_FILE
    echo "[ERROR] config.json not found at $CONFIG_FILE" >&2
    exit 1
end

# Use a dedicated kubeconfig so other cluster contexts don't interfere
set -gx KUBECONFIG $SCRIPT_DIR/kubeconfig
if not test -f $KUBECONFIG
    echo "[ERROR] No kubeconfig found at $KUBECONFIG" >&2
    echo "[ERROR] Start CRC first with ./start-crc.fish, or copy your kubeconfig to $KUBECONFIG" >&2
    exit 1
end

set TOYSTORE_NS (jq -r '.toystore_namespace' $CONFIG_FILE)
set TOYSTORE_URL "https://toystore.apps-crc.testing"
set RLP_NAME "toystore-httproute"

set PASS 0
set FAIL 0

function pass
    echo "  PASS: $argv"
    set -g PASS (math $PASS + 1)
end

function fail
    echo "  FAIL: $argv[1] (expected $argv[2], got $argv[3])"
    set -g FAIL (math $FAIL + 1)
end

function assert_status
    set -l desc $argv[1]
    set -l expected $argv[2]
    set -l actual $argv[3]
    if test "$actual" = "$expected"
        pass $desc
    else
        fail $desc $expected $actual
    end
end

function request
    set -l method (test (count $argv) -ge 1; and echo $argv[1]; or echo GET)
    set -l path (test (count $argv) -ge 2; and echo $argv[2]; or echo /toy)
    set -l key (test (count $argv) -ge 3; and echo $argv[3]; or echo "")

    set -l args -X $method
    if test -n "$key"
        set -a args -H "Authorization: APIKEY $key"
    end
    curl -sk --connect-timeout 5 -o /dev/null -w '%{http_code}' $args "$TOYSTORE_URL$path"
end

function window_seconds
    set -l w $argv[1]
    if string match -rq '^([0-9]+)s$' -- $w
        echo (string match -r '^([0-9]+)s$' -- $w)[2]
    else if string match -rq '^([0-9]+)m$' -- $w
        echo (math (string match -r '^([0-9]+)m$' -- $w)[2] '*' 60)
    else
        echo 60
    end
end

# --- Auth Tests ---

function test_auth
    echo ""
    echo "=== Authentication Tests ==="
    echo ""

    echo "-- Unauthenticated requests should be rejected --"
    assert_status "GET /toy without key returns 401" \
        401 (request GET /toy)
    assert_status "POST /admin/toy without key returns 401" \
        401 (request POST /admin/toy)
    assert_status "DELETE /admin/toy without key returns 401" \
        401 (request DELETE /admin/toy)

    echo ""
    echo "-- Invalid key should be rejected --"
    assert_status "GET /toy with wrong key returns 401" \
        401 (request GET /toy INVALIDKEY)

    echo ""
    echo "-- Valid keys should be accepted --"
    assert_status "GET /toy with Alice key returns 200" \
        200 (request GET /toy ALICEKEYFORDEMO)
    assert_status "GET /toy with Bob key returns 200" \
        200 (request GET /toy BOBKEYFORDEMO)
    assert_status "GET /toy with Admin key returns 200" \
        200 (request GET /toy IAMADMIN)
end

# --- Rate Limit Tests ---

function test_rate_limit
    set -l rlp (kubectl get ratelimitpolicy $RLP_NAME -n $TOYSTORE_NS -o json 2>/dev/null)
    if test $status -ne 0
        echo "[WARN] Could not read RateLimitPolicy $RLP_NAME in $TOYSTORE_NS, using defaults"
        set GET_TOY_LIMIT 5
        set GET_TOY_WINDOW "1m"
        set GLOBAL_LIMIT 6
        set GLOBAL_WINDOW "30s"
    else
        set GET_TOY_LIMIT (echo $rlp | jq -r '.spec.limits["get-toy"].rates[0].limit // 5')
        set GET_TOY_WINDOW (echo $rlp | jq -r '.spec.limits["get-toy"].rates[0].window // "1m"')
        set GLOBAL_LIMIT (echo $rlp | jq -r '.spec.limits["global"].rates[0].limit // 6')
        set GLOBAL_WINDOW (echo $rlp | jq -r '.spec.limits["global"].rates[0].window // "30s"')
    end

    set -l effective_limit $GET_TOY_LIMIT
    if test $GLOBAL_LIMIT -lt $effective_limit
        set effective_limit $GLOBAL_LIMIT
    end

    set -l total_requests (math $effective_limit + 2)

    set -l get_toy_secs (window_seconds $GET_TOY_WINDOW)
    set -l global_secs (window_seconds $GLOBAL_WINDOW)
    set -l wait_secs $get_toy_secs
    if test $global_secs -gt $wait_secs
        set wait_secs $global_secs
    end

    echo ""
    echo "=== Rate Limit Tests ==="
    echo ""
    echo "  Cluster config: get-toy=$GET_TOY_LIMIT/$GET_TOY_WINDOW, global=$GLOBAL_LIMIT/$GLOBAL_WINDOW"
    echo "  Effective limit for GET /toy: $effective_limit (sending $total_requests requests)"

    echo ""
    echo "-- GET /toy rate limit: $effective_limit requests --"
    set -l sleep_time (math $wait_secs + 2)
    echo ""
    echo "  (waiting {$sleep_time}s for rate limit window to reset...)"
    sleep $sleep_time

    set -l codes
    for i in (seq 1 $total_requests)
        set -a codes (request GET /toy ALICEKEYFORDEMO)
    end

    set -l ok 0
    set -l limited 0
    for c in $codes
        if test "$c" = 200
            set ok (math $ok + 1)
        end
        if test "$c" = 429
            set limited (math $limited + 1)
        end
    end

    echo "  Results: $ok x 200, $limited x 429 (out of $total_requests requests)"

    set -l min_ok (math "max(1, $effective_limit - 1)")
    set -l max_ok (math $effective_limit + 1)

    if test $ok -ge $min_ok; and test $ok -le $max_ok; and test $limited -ge 1
        pass "Rate limiting engaged around $effective_limit requests (got $ok ok)"
    else
        fail "Rate limiting" "$min_ok-$max_ok ok, 1+ limited" "$ok ok, $limited limited"
    end
end

# --- Main ---

set SUITE (test (count $argv) -gt 0; and echo $argv[1]; or echo all)

echo "Toystore Policy Smoke Tests"
echo "URL: $TOYSTORE_URL"

switch $SUITE
    case auth
        test_auth
    case rate
        test_rate_limit
    case all
        test_auth
        test_rate_limit
    case '*'
        echo "Usage: test-toystore.fish [auth|rate|all]"
        exit 1
end

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Results: $PASS passed, $FAIL failed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

test $FAIL -eq 0
