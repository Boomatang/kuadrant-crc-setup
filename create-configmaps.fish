#!/usr/bin/env fish

set SCRIPT_DIR (cd (dirname (status filename)); and pwd)
set -gx KUBECONFIG $SCRIPT_DIR/kubeconfig

set COUNT (test (count $argv) -gt 0; and echo $argv[1]; or echo 100)
set NS "configmap-load-test"
set DATA_SIZE_KB 512

echo "[INFO] Creating namespace $NS"
kubectl create namespace $NS --dry-run=client -o yaml | kubectl apply -f -

echo "[INFO] Creating $COUNT ConfigMaps (~"$DATA_SIZE_KB"KB each) in $NS"

for i in (seq 1 $COUNT)
    printf "\r[INFO] Progress: %d/%d  " $i $COUNT
    set uid (uuidgen | string lower | string sub -l 8)
    set payload (dd if=/dev/urandom bs=1024 count=$DATA_SIZE_KB 2>/dev/null | base64 -w 0)
    echo "---
apiVersion: v1
kind: ConfigMap
metadata:
  name: configmap-$uid
  namespace: $NS
  labels:
    app: load-test
    batch: configmap-load
data:
  payload.dat: |
    $payload
" | kubectl create -f -
end

echo ""
echo ""
echo "[INFO] Created $COUNT ConfigMaps in namespace $NS"
echo "[INFO] To verify: kubectl get configmaps -n $NS --no-headers | wc -l"
echo "[INFO] To delete: ./delete-configmaps.fish"
