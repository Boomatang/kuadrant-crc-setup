#!/usr/bin/env fish

set SCRIPT_DIR (cd (dirname (status filename)); and pwd)
set -gx KUBECONFIG $SCRIPT_DIR/kubeconfig

argparse 'c/count=' 'n/namespace=' -- $argv
or begin
    echo "Usage: ./delete-serviceaccounts.fish [-c count] [-n namespace]"
    exit 1
end

set NS (test -n "$_flag_namespace"; and echo "$_flag_namespace"; or echo "sa-load-test")
set COUNT (test -n "$_flag_count"; and echo "$_flag_count"; or echo "all")

if test "$COUNT" = all
    set accounts (kubectl get serviceaccounts -n $NS -l batch=sa-load --no-headers -o custom-columns=:metadata.name 2>/dev/null)
else
    set accounts (kubectl get serviceaccounts -n $NS -l batch=sa-load --no-headers -o custom-columns=:metadata.name 2>/dev/null | head -n $COUNT)
end

set total (count $accounts)
if test $total -eq 0
    echo "[INFO] No load-test ServiceAccounts found in $NS"
    exit 0
end

echo "[INFO] Triggering deletion of $total ServiceAccounts from $NS"
for i in (seq 1 $total)
    printf "\r[INFO] Triggering: %d/%d" $i $total
    kubectl delete serviceaccount -n $NS $accounts[$i] --wait=false >/dev/null 2>&1
end
echo ""

echo "[INFO] Waiting for ServiceAccounts to terminate..."
for i in (seq 1 $total)
    printf "\r[INFO] Waiting: %d/%d remaining" (math $total - $i + 1) $total
    kubectl wait --for=delete serviceaccount/$accounts[$i] -n $NS --timeout=300s >/dev/null 2>&1
end
echo ""

set remaining (kubectl get serviceaccounts -n $NS -l batch=sa-load --no-headers 2>/dev/null | wc -l | string trim)

if test "$remaining" -eq 0
    echo "[INFO] All load-test ServiceAccounts deleted, deleting namespace $NS"
    kubectl delete namespace $NS
else
    echo "[WARN] $remaining ServiceAccounts still remaining in $NS"
end

echo "[INFO] Cleanup complete"
