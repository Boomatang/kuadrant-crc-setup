#!/usr/bin/env fish

set SCRIPT_DIR (cd (dirname (status filename)); and pwd)
set -gx KUBECONFIG $SCRIPT_DIR/kubeconfig

set NS "configmap-load-test"
set COUNT (test (count $argv) -gt 0; and echo $argv[1]; or echo "all")

if test "$COUNT" = all
    set configmaps (kubectl get configmaps -n $NS -l batch=configmap-load --no-headers -o custom-columns=:metadata.name 2>/dev/null)
else
    set configmaps (kubectl get configmaps -n $NS -l batch=configmap-load --no-headers -o custom-columns=:metadata.name 2>/dev/null | head -n $COUNT)
end

if test (count $configmaps) -eq 0
    echo "[INFO] No ConfigMaps found in $NS"
    exit 0
end

set total (count $configmaps)
echo "[INFO] Deleting $total ConfigMaps from $NS"

for i in (seq 1 $total)
    printf "\r[INFO] Progress: %d/%d" $i $total
    kubectl delete configmap -n $NS $configmaps[$i] >/dev/null 2>&1
end
echo ""

set remaining (kubectl get configmaps -n $NS -l batch=configmap-load --no-headers 2>/dev/null | wc -l | string trim)

if test "$remaining" -eq 0
    echo "[INFO] No ConfigMaps remaining, deleting namespace $NS"
    kubectl delete namespace $NS
else
    echo "[INFO] $remaining ConfigMaps remaining in $NS"
end

echo "[INFO] Cleanup complete"
