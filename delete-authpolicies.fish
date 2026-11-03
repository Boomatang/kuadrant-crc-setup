#!/usr/bin/env fish

set SCRIPT_DIR (cd (dirname (status filename)); and pwd)
set -gx KUBECONFIG $SCRIPT_DIR/kubeconfig

argparse 'c/count=' 'n/namespace=' -- $argv
or begin
    echo "Usage: ./delete-authpolicies.fish [-c count] [-n namespace]"
    exit 1
end

set NS (test -n "$_flag_namespace"; and echo "$_flag_namespace"; or echo "openshift-ingress")
set COUNT (test -n "$_flag_count"; and echo "$_flag_count"; or echo "all")

if test "$COUNT" = all
    set policies (kubectl get authpolicies -n $NS -l batch=authpolicy-load --no-headers -o custom-columns=:metadata.name 2>/dev/null)
else
    set policies (kubectl get authpolicies -n $NS -l batch=authpolicy-load --no-headers -o custom-columns=:metadata.name 2>/dev/null | head -n $COUNT)
end

if test (count $policies) -eq 0
    echo "[INFO] No AuthPolicies found in $NS"
    exit 0
end

set total (count $policies)
echo "[INFO] Deleting $total AuthPolicies from $NS"

for i in (seq 1 $total)
    printf "\r[INFO] Progress: %d/%d" $i $total
    kubectl delete authpolicy -n $NS $policies[$i] >/dev/null 2>&1
end
echo ""

set remaining (kubectl get authpolicies -n $NS -l batch=authpolicy-load --no-headers 2>/dev/null | wc -l | string trim)

if test "$remaining" -eq 0
    echo "[INFO] All AuthPolicies deleted"
else
    echo "[INFO] $remaining AuthPolicies remaining in $NS"
end

echo "[INFO] Cleanup complete"
