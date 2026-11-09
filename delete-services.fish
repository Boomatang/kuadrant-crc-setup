#!/usr/bin/env fish

set SCRIPT_DIR (cd (dirname (status filename)); and pwd)
set -gx KUBECONFIG $SCRIPT_DIR/kubeconfig

argparse 'c/count=' 'n/namespace=' 'b/batch-size=!_validate_int --min 1' -- $argv
or begin
    echo "Usage: ./delete-services.fish [-c count] [-n namespace] [-b batch-size]"
    exit 1
end

set NS (test -n "$_flag_namespace"; and echo "$_flag_namespace"; or echo "service-load-test")
set COUNT (test -n "$_flag_count"; and echo "$_flag_count"; or echo "all")
set BATCH_SIZE (test -n "$_flag_batch_size"; and echo "$_flag_batch_size"; or echo 500)

if test "$COUNT" = all
    set services (kubectl get services -n $NS -l batch=service-load --no-headers -o custom-columns=:metadata.name 2>/dev/null)
else
    set services (kubectl get services -n $NS -l batch=service-load --no-headers -o custom-columns=:metadata.name 2>/dev/null | head -n $COUNT)
end

set total (count $services)
if test $total -eq 0
    echo "[INFO] No load-test Services found in $NS"
    exit 0
end

if test "$COUNT" = all
    echo "[INFO] Triggering deletion of $total Services from $NS"
    kubectl delete services -n $NS -l batch=service-load --wait=false >/dev/null 2>&1
else
    echo "[INFO] Triggering deletion of $total Services from $NS (batch size: $BATCH_SIZE)"
    for i in (seq 1 $BATCH_SIZE $total)
        set batch_end (math "min($i + $BATCH_SIZE - 1, $total)")
        printf "\r[INFO] Triggering: %d/%d  " $batch_end $total
        kubectl delete service -n $NS --wait=false $services[$i..$batch_end] >/dev/null 2>&1
    end
    echo ""
end

echo "[INFO] Waiting for Services to terminate..."
set timeout 300
set elapsed 0
while test $elapsed -lt $timeout
    set remaining (kubectl get services -n $NS -l batch=service-load --no-headers 2>/dev/null | wc -l | string trim)
    if test "$remaining" -eq 0
        break
    end
    printf "\r[INFO] Waiting: %d remaining  " $remaining
    sleep 2
    set elapsed (math $elapsed + 2)
end
echo ""

if test "$remaining" -eq 0
    echo "[INFO] All load-test Services deleted, deleting namespace $NS"
    kubectl delete namespace $NS
else
    echo "[WARN] $remaining Services still remaining in $NS"
end

echo "[INFO] Cleanup complete"
