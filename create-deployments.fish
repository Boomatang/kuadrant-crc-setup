#!/usr/bin/env fish

set SCRIPT_DIR (cd (dirname (status filename)); and pwd)
set -gx KUBECONFIG $SCRIPT_DIR/kubeconfig

argparse 'c/count=!_validate_int --min 1' 'n/namespace=' 'b/batch-size=!_validate_int --min 1' 's/size=!_validate_int --min 0' -- $argv
or begin
    echo "Usage: ./create-deployments.fish [-c count] [-n namespace] [-b batch-size] [-s size-kb]"
    exit 1
end

set COUNT (test -n "$_flag_count"; and echo "$_flag_count"; or echo 10)
set NS (test -n "$_flag_namespace"; and echo "$_flag_namespace"; or echo "deployment-load-test")
set SIZE_KB (test -n "$_flag_size"; and echo "$_flag_size"; or echo 190)
set BATCH_SIZE (test -n "$_flag_batch_size"; and echo "$_flag_batch_size"; or echo 10)

echo "[INFO] Creating namespace $NS"
kubectl create namespace $NS --dry-run=client -o yaml | kubectl apply -f -

if test $SIZE_KB -gt 0
    echo "[INFO] Creating $COUNT Deployments (~"$SIZE_KB"KB each, 0 replicas) in $NS (batch size: $BATCH_SIZE)"
    echo "[INFO] Generating payload..."
    set PAYLOAD (dd if=/dev/urandom bs=1024 count=$SIZE_KB 2>/dev/null | base64 -w 0)
else
    echo "[INFO] Creating $COUNT Deployments (0 replicas) in $NS (batch size: $BATCH_SIZE)"
end

set batch_errors 0
set tmpfile (mktemp)

for i in (seq 1 $COUNT)
    set uid (uuidgen | string lower | string sub -l 8)
    if test $SIZE_KB -gt 0
        echo "---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: deploy-$uid
  namespace: $NS
  labels:
    app: load-test
    batch: deployment-load
    app.kubernetes.io/managed-by: kuadrant-crc-setup
  annotations:
    load-test/payload: \"$PAYLOAD\"
spec:
  replicas: 0
  selector:
    matchLabels:
      app: load-test
      instance: deploy-$uid
  template:
    metadata:
      labels:
        app: load-test
        instance: deploy-$uid
    spec:
      containers:
        - name: pause
          image: registry.k8s.io/pause:3.9" >> $tmpfile
    else
        echo "---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: deploy-$uid
  namespace: $NS
  labels:
    app: load-test
    batch: deployment-load
    app.kubernetes.io/managed-by: kuadrant-crc-setup
spec:
  replicas: 0
  selector:
    matchLabels:
      app: load-test
      instance: deploy-$uid
  template:
    metadata:
      labels:
        app: load-test
        instance: deploy-$uid
    spec:
      containers:
        - name: pause
          image: registry.k8s.io/pause:3.9" >> $tmpfile
    end

    if test (math $i % $BATCH_SIZE) -eq 0 -o $i -eq $COUNT
        printf "\r[INFO] Applying batch: %d/%d  " $i $COUNT
        kubectl create -f $tmpfile >/dev/null 2>&1
        or set batch_errors (math $batch_errors + 1)
        true > $tmpfile
    end
end

rm -f $tmpfile

echo ""
echo ""
set actual (kubectl get deployments -n $NS -l batch=deployment-load --no-headers 2>/dev/null | wc -l | string trim)
if test $batch_errors -gt 0
    echo "[WARN] $batch_errors batch(es) had errors"
end
echo "[INFO] $actual Deployments now in namespace $NS"
echo "[INFO] To delete: ./delete-deployments.fish [-n $NS]"
