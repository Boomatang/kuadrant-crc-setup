#!/usr/bin/env fish

set SCRIPT_DIR (cd (dirname (status filename)); and pwd)
set -gx KUBECONFIG $SCRIPT_DIR/kubeconfig

argparse 'c/count=' -- $argv
or begin
    echo "Usage: ./delete-namespaces.fish [-c count]"
    exit 1
end

set COUNT (test -n "$_flag_count"; and echo "$_flag_count"; or echo "all")

if test "$COUNT" = all
    set namespaces (kubectl get namespaces -l batch=namespace-load --no-headers -o custom-columns=:metadata.name 2>/dev/null)
else
    set namespaces (kubectl get namespaces -l batch=namespace-load --no-headers -o custom-columns=:metadata.name 2>/dev/null | head -n $COUNT)
end

set total (count $namespaces)
if test $total -eq 0
    echo "[INFO] No load-test namespaces found"
    exit 0
end

echo "[INFO] Triggering deletion of $total namespaces"
for i in (seq 1 $total)
    printf "\r[INFO] Triggering: %d/%d" $i $total
    kubectl delete namespace $namespaces[$i] --wait=false >/dev/null 2>&1
end
echo ""

echo "[INFO] Waiting for namespaces to terminate..."
for i in (seq 1 $total)
    printf "\r[INFO] Waiting: %d/%d remaining" (math $total - $i + 1) $total
    kubectl wait --for=delete namespace/$namespaces[$i] --timeout=300s >/dev/null 2>&1
end
echo ""

set remaining (kubectl get namespaces -l batch=namespace-load --no-headers 2>/dev/null | wc -l | string trim)

if test "$remaining" -eq 0
    echo "[INFO] All load-test namespaces deleted"
else
    echo "[WARN] $remaining namespaces still remaining in $NS"
end

echo "[INFO] Cleanup complete"
