#!/usr/bin/env fish

set SCRIPT_DIR (cd (dirname (status filename)); and pwd)
set -gx KUBECONFIG $SCRIPT_DIR/kubeconfig

argparse 'c/count=' 'n/namespace=' -- $argv
or begin
    echo "Usage: ./delete-tokenratelimitpolicies.fish [-c count] [-n namespace]"
    exit 1
end

set NS (test -n "$_flag_namespace"; and echo "$_flag_namespace"; or echo "openshift-ingress")
set COUNT (test -n "$_flag_count"; and echo "$_flag_count"; or echo "all")

if test "$COUNT" = all
    set policies (kubectl get tokenratelimitpolicies -n $NS -l batch=trlp-load --no-headers -o custom-columns=:metadata.name 2>/dev/null)
else
    set policies (kubectl get tokenratelimitpolicies -n $NS -l batch=trlp-load --no-headers -o custom-columns=:metadata.name 2>/dev/null | head -n $COUNT)
end

set total_policies (count $policies)
if test $total_policies -gt 0
    echo "[INFO] Deleting $total_policies TokenRateLimitPolicies from $NS"
    for i in (seq 1 $total_policies)
        printf "\r[INFO] Progress (TRLPs): %d/%d" $i $total_policies
        kubectl delete tokenratelimitpolicy -n $NS $policies[$i] >/dev/null 2>&1
    end
    echo ""
else
    echo "[INFO] No TokenRateLimitPolicies found in $NS"
end

if test "$COUNT" = all
    set routes (kubectl get httproutes -n $NS -l batch=trlp-load --no-headers -o custom-columns=:metadata.name 2>/dev/null)
else
    set routes (kubectl get httproutes -n $NS -l batch=trlp-load --no-headers -o custom-columns=:metadata.name 2>/dev/null | head -n $COUNT)
end

set total_routes (count $routes)
if test $total_routes -gt 0
    echo "[INFO] Deleting $total_routes HTTPRoutes from $NS"
    for i in (seq 1 $total_routes)
        printf "\r[INFO] Progress (routes): %d/%d" $i $total_routes
        kubectl delete httproute -n $NS $routes[$i] >/dev/null 2>&1
    end
    echo ""
else
    echo "[INFO] No HTTPRoutes found in $NS"
end

set remaining_policies (kubectl get tokenratelimitpolicies -n $NS -l batch=trlp-load --no-headers 2>/dev/null | wc -l | string trim)
set remaining_routes (kubectl get httproutes -n $NS -l batch=trlp-load --no-headers 2>/dev/null | wc -l | string trim)

if test "$remaining_policies" -eq 0 -a "$remaining_routes" -eq 0
    echo "[INFO] All TokenRateLimitPolicies and HTTPRoutes deleted"
else
    test "$remaining_policies" -gt 0; and echo "[INFO] $remaining_policies TokenRateLimitPolicies remaining in $NS"
    test "$remaining_routes" -gt 0; and echo "[INFO] $remaining_routes HTTPRoutes remaining in $NS"
end

echo "[INFO] Cleanup complete"
