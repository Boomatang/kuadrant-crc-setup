#!/usr/bin/env fish

set SCRIPT_DIR (cd (dirname (status filename)); and pwd)
set -gx KUBECONFIG $SCRIPT_DIR/kubeconfig

set COUNT (test (count $argv) -gt 0; and echo $argv[1]; or echo 20)

for i in (seq -w 1 $COUNT)
    set NS "gw-test-$i"
    echo "[INFO] Deleting namespace $NS"
    kubectl delete namespace $NS --wait=false
end

echo ""
echo "[INFO] Deletion of $COUNT gateway namespaces initiated"
