#!/usr/bin/env fish

set SCRIPT_DIR (cd (dirname (status filename)); and pwd)
set -gx KUBECONFIG $SCRIPT_DIR/kubeconfig

argparse 'c/count=!_validate_int --min 1' 'g/gateway=' 'n/namespace=' 't/target=' -- $argv
or begin
    echo "Usage: ./create-tokenratelimitpolicies.fish -g <gateway-name> [-c count] [-n namespace] [-t gateway|route]"
    exit 1
end

set COUNT (test -n "$_flag_count"; and echo "$_flag_count"; or echo 10)
set GATEWAY $_flag_gateway
set NS (test -n "$_flag_namespace"; and echo "$_flag_namespace"; or echo "openshift-ingress")
set TARGET (test -n "$_flag_target"; and echo "$_flag_target"; or echo "gateway")

if test -z "$GATEWAY"
    echo "[ERROR] Gateway name is required (-g/--gateway)"
    echo "Usage: ./create-tokenratelimitpolicies.fish -g <gateway-name> [-c count] [-n namespace] [-t gateway|route]"
    exit 1
end

if test "$TARGET" != gateway -a "$TARGET" != route
    echo "[ERROR] Target must be 'gateway' or 'route' (got '$TARGET')"
    exit 1
end

if test "$TARGET" = route
    echo "[INFO] Creating $COUNT HTTPRoutes + TokenRateLimitPolicies (targeting routes) in $NS"
else
    echo "[INFO] Creating $COUNT TokenRateLimitPolicies targeting gateway $GATEWAY in $NS"
end

set route_errors 0
set trlp_errors 0
for i in (seq 1 $COUNT)
    printf "\r[INFO] Progress: %d/%d  " $i $COUNT
    set uid (uuidgen | string lower | string sub -l 8)

    if test "$TARGET" = route
        echo "---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: route-$uid
  namespace: $NS
  labels:
    app: load-test
    batch: trlp-load
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: $GATEWAY
  hostnames:
    - \"$uid.load-test.example.com\"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: load-test-$uid
          port: 8080
" | kubectl create -f -
        or set route_errors (math $route_errors + 1)
    end

    if test "$TARGET" = route
        set ref_kind HTTPRoute
        set ref_name route-$uid
    else
        set ref_kind Gateway
        set ref_name $GATEWAY
    end

    echo "---
apiVersion: kuadrant.io/v1alpha1
kind: TokenRateLimitPolicy
metadata:
  name: trlp-$uid
  namespace: $NS
  labels:
    app: load-test
    batch: trlp-load
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: $ref_kind
    name: $ref_name
  limits:
    \"limit-$uid\":
      rates:
        - limit: 1000
          window: 60s
" | kubectl create -f -
    or set trlp_errors (math $trlp_errors + 1)
end

echo ""
echo ""
if test "$TARGET" = route
    if test $route_errors -gt 0
        echo "[WARN] $route_errors/$COUNT HTTPRoutes failed to create"
    else
        echo "[INFO] Created $COUNT HTTPRoutes in namespace $NS"
    end
end
if test $trlp_errors -gt 0
    echo "[WARN] $trlp_errors/$COUNT TokenRateLimitPolicies failed to create"
else
    echo "[INFO] Created $COUNT TokenRateLimitPolicies in namespace $NS"
end
echo "[INFO] To verify:"
test "$TARGET" = route; and echo "  kubectl get httproutes -n $NS -l batch=trlp-load --no-headers | wc -l"
echo "  kubectl get tokenratelimitpolicies -n $NS -l batch=trlp-load --no-headers | wc -l"
echo "[INFO] To delete: ./delete-tokenratelimitpolicies.fish [-n $NS]"
