#!/usr/bin/env fish

set SCRIPT_DIR (cd (dirname (status filename)); and pwd)
set -gx KUBECONFIG $SCRIPT_DIR/kubeconfig

set COUNT (test (count $argv) -gt 0; and echo $argv[1]; or echo 20)

for i in (seq -w 1 $COUNT)
    set NS "gw-test-$i"
    set GW "gateway-$i"
    set HOST "app-$i.apps-crc.testing"

    echo "[INFO] Creating gateway $GW in namespace $NS"

    echo "---
apiVersion: v1
kind: Namespace
metadata:
  name: $NS
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: $GW
  namespace: $NS
spec:
  gatewayClassName: istio
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    hostname: \"$HOST\"
    allowedRoutes:
      namespaces:
        from: Same
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: toystore
  namespace: $NS
  labels:
    app: toystore
spec:
  replicas: 1
  selector:
    matchLabels:
      app: toystore
  template:
    metadata:
      labels:
        app: toystore
    spec:
      containers:
      - name: toystore
        image: quay.io/kuadrant/authorino-examples:talker-api
        ports:
        - containerPort: 3000
---
apiVersion: v1
kind: Service
metadata:
  name: toystore
  namespace: $NS
spec:
  selector:
    app: toystore
  ports:
  - port: 80
    targetPort: 3000
---
apiVersion: v1
kind: Secret
metadata:
  name: api-key
  namespace: $NS
  labels:
    app: toystore
    authorino.kuadrant.io/managed-by: authorino
  annotations:
    secret.kuadrant.io/user-id: \"user-$i\"
type: Opaque
stringData:
  api_key: \"KEY$i\"
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: route-$i
  namespace: $NS
spec:
  parentRefs:
  - name: $GW
    namespace: $NS
  hostnames:
  - \"$HOST\"
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: toystore
      port: 80
---
apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata:
  name: auth-$i
  namespace: $NS
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: route-$i
  rules:
    authentication:
      apikey:
        apiKey:
          selector:
            matchLabels:
              app: toystore
        credentials:
          authorizationHeader:
            prefix: APIKEY
" | kubectl apply -f -
end

echo ""
echo "[INFO] Created $COUNT gateway setups"
echo "[INFO] To delete: ./delete-test-gateways.fish $COUNT"
