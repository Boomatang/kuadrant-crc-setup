#!/usr/bin/env fish

set SCRIPT_DIR (cd (dirname (status filename)); and pwd)
set -gx KUBECONFIG $SCRIPT_DIR/kubeconfig

argparse 'c/count=!_validate_int --min 1' 'g/gateway=' 'n/namespace=' -- $argv
or begin
    echo "Usage: ./create-authpolicies.fish -g <gateway-name> [-c count] [-n namespace]"
    exit 1
end

set COUNT (test -n "$_flag_count"; and echo "$_flag_count"; or echo 10)
set GATEWAY $_flag_gateway
set NS (test -n "$_flag_namespace"; and echo "$_flag_namespace"; or echo "openshift-ingress")

if test -z "$GATEWAY"
    echo "[ERROR] Gateway name is required (-g/--gateway)"
    echo "Usage: ./create-authpolicies.fish -g <gateway-name> [-c count] [-n namespace]"
    exit 1
end

echo "[INFO] Creating $COUNT AuthPolicies targeting gateway $GATEWAY in $NS"

set errors 0
for i in (seq 1 $COUNT)
    printf "\r[INFO] Progress: %d/%d  " $i $COUNT
    set uid (uuidgen | string lower | string sub -l 8)
    echo "---
apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata:
  name: authpolicy-$uid
  namespace: $NS
  labels:
    app: load-test
    batch: authpolicy-load
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: Gateway
    name: $GATEWAY
  rules:
    authentication:
      \"auth-$uid\":
        apiKey:
          selector:
            matchLabels:
              app: load-test-$uid
        credentials:
          authorizationHeader:
            prefix: APIKEY
" | kubectl create -f -
    or set errors (math $errors + 1)
end

echo ""
echo ""
if test $errors -gt 0
    echo "[WARN] $errors/$COUNT AuthPolicies failed to create"
else
    echo "[INFO] Created $COUNT AuthPolicies in namespace $NS"
end
echo "[INFO] To verify: kubectl get authpolicies -n $NS -l batch=authpolicy-load --no-headers | wc -l"
echo "[INFO] To delete: ./delete-authpolicies.fish"
