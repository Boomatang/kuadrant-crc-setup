#!/usr/bin/env fish

set SCRIPT_DIR (cd (dirname (status filename)); and pwd)
set -gx KUBECONFIG $SCRIPT_DIR/kubeconfig

argparse 'c/count=' 'n/namespace=' -- $argv
or begin
    echo "Usage: ./delete-routes.fish [-c count] [-n namespace]"
    exit 1
end

set NS (test -n "$_flag_namespace"; and echo "$_flag_namespace"; or echo "openshift-ingress")
set COUNT (test -n "$_flag_count"; and echo "$_flag_count"; or echo "all")

if test "$COUNT" = all
    set routes (kubectl get httproutes -n $NS -l batch=route-load --no-headers -o custom-columns=:metadata.name 2>/dev/null)
else
    set routes (kubectl get httproutes -n $NS -l batch=route-load --no-headers -o custom-columns=:metadata.name 2>/dev/null | head -n $COUNT)
end

if test (count $routes) -eq 0
    echo "[INFO] No HTTPRoutes found in $NS"
    exit 0
end

set total (count $routes)
echo "[INFO] Deleting $total HTTPRoutes from $NS"

for i in (seq 1 $total)
    printf "\r[INFO] Progress: %d/%d" $i $total
    kubectl delete httproute -n $NS $routes[$i] >/dev/null 2>&1
end
echo ""

set remaining (kubectl get httproutes -n $NS -l batch=route-load --no-headers 2>/dev/null | wc -l | string trim)

if test "$remaining" -eq 0
    echo "[INFO] All HTTPRoutes deleted"
else
    echo "[INFO] $remaining HTTPRoutes remaining in $NS"
end

echo "[INFO] Cleanup complete"
