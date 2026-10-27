#!/usr/bin/env fish

set SCRIPT_DIR (cd (dirname (status filename)); and pwd)
set -gx KUBECONFIG $SCRIPT_DIR/kubeconfig

set COUNT (test (count $argv) -gt 0; and echo $argv[1]; or echo 100)
set NS "netpol-load-test"

echo "[INFO] Creating namespace $NS"
kubectl create namespace $NS --dry-run=client -o yaml | kubectl apply -f -

echo "[INFO] Creating $COUNT NetworkPolicies in $NS"

for i in (seq 1 $COUNT)
    printf "\r[INFO] Progress: %d/%d  " $i $COUNT
    set uid (uuidgen | string lower | string sub -l 8)
    set octet (math "$i % 256")
    echo "---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: netpol-$uid
  namespace: $NS
  labels:
    app: load-test
    batch: netpol-load
spec:
  podSelector:
    matchLabels:
      app: target-$uid
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          team: vendor-$uid
    - podSelector:
        matchLabels:
          role: client-$uid
    ports:
    - protocol: TCP
      port: 8080
  egress:
  - to:
    - ipBlock:
        cidr: 10.$octet.0.0/16
    ports:
    - protocol: TCP
      port: 443
" | kubectl apply -f -
end

echo ""
echo ""
echo "[INFO] Created $COUNT NetworkPolicies in namespace $NS"
echo "[INFO] To verify: kubectl get networkpolicies -n $NS --no-headers | wc -l"
echo "[INFO] To delete: ./delete-networkpolicies.fish"
