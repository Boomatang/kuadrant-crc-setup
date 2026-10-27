#!/usr/bin/env fish

set SCRIPT_DIR (cd (dirname (status filename)); and pwd)
set -gx KUBECONFIG $SCRIPT_DIR/kubeconfig

set NS "netpol-load-test"
set COUNT (test (count $argv) -gt 0; and echo $argv[1]; or echo "all")

if test "$COUNT" = all
    set policies (kubectl get networkpolicies -n $NS -l batch=netpol-load --no-headers -o custom-columns=:metadata.name 2>/dev/null)
else
    set policies (kubectl get networkpolicies -n $NS -l batch=netpol-load --no-headers -o custom-columns=:metadata.name 2>/dev/null | head -n $COUNT)
end

if test (count $policies) -eq 0
    echo "[INFO] No NetworkPolicies found in $NS"
    exit 0
end

set total (count $policies)
echo "[INFO] Deleting $total NetworkPolicies from $NS"

for i in (seq 1 $total)
    printf "\r[INFO] Progress: %d/%d" $i $total
    kubectl delete networkpolicy -n $NS $policies[$i] >/dev/null 2>&1
end
echo ""

set remaining (kubectl get networkpolicies -n $NS --no-headers 2>/dev/null | wc -l | string trim)

if test "$remaining" -eq 0
    echo "[INFO] No policies remaining, deleting namespace $NS"
    kubectl delete namespace $NS
else
    echo "[INFO] $remaining NetworkPolicies remaining in $NS"
end

echo "[INFO] Cleanup complete"
