#!/usr/bin/env fish

set SCRIPT_DIR (cd (dirname (status filename)); and pwd)
set CONFIG_FILE $SCRIPT_DIR/config.json

# Tee all output to a timestamped log file
if not set -q _DEPLOY_LOGGING
    set -l LOG_DIR $SCRIPT_DIR/logs
    mkdir -p $LOG_DIR
    set -l LOG_FILE $LOG_DIR/deploy-(date +%Y%m%d-%H%M%S).log
    set -x _DEPLOY_LOGGING 1
    fish (status filename) $argv 2>&1 | tee $LOG_FILE
    set -l rc $pipestatus[1]
    if test $rc -eq 0
        echo "[INFO]  Log saved to $LOG_FILE"
    else
        echo "[ERROR] Deploy failed. Log saved to $LOG_FILE"
    end
    exit $rc
end

if not test -f $CONFIG_FILE
    echo "[ERROR] config.json not found at $CONFIG_FILE" >&2
    exit 1
end

# Use a dedicated kubeconfig so other cluster contexts don't interfere
set -gx KUBECONFIG $SCRIPT_DIR/kubeconfig
if not test -f $KUBECONFIG
    if test -f ~/.crc/machines/crc/kubeconfig
        cp ~/.crc/machines/crc/kubeconfig $KUBECONFIG
        echo "[INFO]  Copied CRC kubeconfig to $KUBECONFIG"
    else
        echo "[ERROR] No kubeconfig found at $KUBECONFIG" >&2
        echo "[ERROR] Start CRC first with ./start-crc.fish, or copy your kubeconfig to $KUBECONFIG" >&2
        exit 1
    end
end

set GATEWAY_PROVIDER (jq -r '.gateway_provider' $CONFIG_FILE)
set KUADRANT_NS (jq -r '.kuadrant_namespace' $CONFIG_FILE)
set TOYSTORE_NS (jq -r '.toystore_namespace' $CONFIG_FILE)
set CONTAINER_ENGINE (jq -r '.container_engine' $CONFIG_FILE)
set CRC_REGISTRY (jq -r '.crc_registry' $CONFIG_FILE)
set CONSOLE_PLUGIN_IMAGE (jq -r '.console_plugin_image // ""' $CONFIG_FILE)

function info
    echo "[INFO]  $argv"
end

function warn
    echo "[WARN]  $argv" >&2
end

function error
    echo "[ERROR] $argv" >&2
end

function abort
    error $argv
    exit 1
end

function crc_check
    command -v crc >/dev/null 2>&1
    or abort "crc not found. Install from: https://console.redhat.com/openshift/create/local"

    crc status 2>/dev/null | grep -q Running
    or abort "CRC is not running. Start it with: ./start-crc.fish"

    kubectl cluster-info >/dev/null 2>&1
    or abort "Cannot reach CRC cluster. Run: eval (crc oc-env)"

    command -v $CONTAINER_ENGINE >/dev/null 2>&1
    or abort "$CONTAINER_ENGINE not found. Install it or update container_engine in config.json"

    command -v skopeo >/dev/null 2>&1
    or abort "skopeo not found. Install it with: sudo dnf install skopeo"

    info "CRC is running, cluster reachable"
end

function ensure_tools
    info "Ensuring kustomize and helm are available..."
    make -C $REPO_PATH kustomize helm >/dev/null 2>&1
    or abort "Failed to download kustomize/helm"
end

function env_setup
    info "Creating namespace $KUADRANT_NS..."
    kubectl create namespace $KUADRANT_NS --dry-run=client -o yaml | kubectl apply -f -
    or abort "Failed to create namespace $KUADRANT_NS"

    info "Installing cert-manager..."
    make -C $REPO_PATH install-cert-manager
    or abort "Failed to install cert-manager"

    info "Generating and applying dependency manifests..."
    make -C $REPO_PATH dependencies-manifests
    or abort "Failed to generate dependency manifests"
    if not $REPO_PATH/bin/kustomize build $REPO_PATH/config/dependencies | kubectl apply --server-side --force-conflicts -f -
        warn "Dependency apply had issues"
    end

    if kubectl -n $KUADRANT_NS get deployments --no-headers 2>/dev/null | grep -q .
        info "Waiting for deployments in $KUADRANT_NS..."
        kubectl -n $KUADRANT_NS wait --timeout=300s --for=condition=Available deployments --all
        or abort "Timed out waiting for deployments in $KUADRANT_NS"
    else
        info "No deployments in $KUADRANT_NS yet, continuing..."
    end

    info "Installing CRDs..."
    make -C $REPO_PATH install
    or abort "Failed to install CRDs"

    switch $GATEWAY_PROVIDER
        case istio
            istio_env_setup
        case envoygateway
            envoygateway_env_setup
        case '*'
            info "No gateway provider configured, skipping gateway setup"
    end
end

function istio_env_setup
    if helm status sail-operator -n istio-system >/dev/null 2>&1
        info "Sail operator already installed, skipping"
    else
        info "Installing Istio via Sail..."
        make -C $REPO_PATH istio-install ISTIO_INSTALL_SAIL=true
        or abort "Failed to install Istio"
    end

    info "Waiting for Istio CRD to be established..."
    kubectl wait --for=condition=Established crd/istios.sailoperator.io --timeout=300s
    or abort "Timed out waiting for Istio CRD"

    info "Deploying Istio gateway..."
    make -C $REPO_PATH deploy-istio-gateway
    or abort "Failed to deploy Istio gateway"

    info "Setting gateway to ClusterIP..."
    kubectl annotate gateway kuadrant-ingressgateway -n gateway-system \
        networking.istio.io/service-type=ClusterIP --overwrite
    or abort "Failed to annotate gateway"
end

function envoygateway_env_setup
    if helm status eg -n envoy-gateway-system >/dev/null 2>&1
        info "Envoy Gateway already installed, skipping"
    else
        info "Installing Envoy Gateway..."
        make -C $REPO_PATH envoy-gateway-install
        or abort "Failed to install Envoy Gateway"
    end

    info "Deploying Envoy Gateway gateway..."
    make -C $REPO_PATH deploy-eg-gateway
    or abort "Failed to deploy Envoy Gateway gateway"
end

function deploy_operator
    set -l CRC_IMG "$CRC_REGISTRY/$KUADRANT_NS/kuadrant-operator:dev"

    info "Building operator image..."
    make -C $REPO_PATH docker-build IMG=$CRC_IMG CONTAINER_ENGINE=$CONTAINER_ENGINE
    or abort "Failed to build operator image"

    info "Pushing image to CRC registry..."
    if not oc whoami -t >/dev/null 2>&1
        set -l crc_pass (crc console --credentials 2>/dev/null | grep kubeadmin | sed 's/.*-p //' | sed 's/ .*//')
        oc login -u kubeadmin -p $crc_pass https://api.crc.testing:6443 --insecure-skip-tls-verify >/dev/null
        or abort "Failed to login to CRC cluster for registry access"
    end
    set -l token (oc whoami -t)
    skopeo copy --dest-tls-verify=false --dest-creds=kubeadmin:$token containers-storage:$CRC_IMG docker://$CRC_IMG
    or abort "Failed to push image to CRC registry"

    info "Deploying operator..."
    make -C $REPO_PATH deploy IMG=$CRC_IMG
    or abort "Failed to deploy operator"

    info "Waiting for operator deployments..."
    kubectl -n $KUADRANT_NS wait --timeout=300s --for=condition=Available deployments --all
    or abort "Timed out waiting for operator deployments"

    info "Enabling Kuadrant console plugin..."
    if oc get consoles.operator.openshift.io cluster -o jsonpath='{.spec.plugins}' 2>/dev/null | grep -q kuadrant-console-plugin
        info "Console plugin already enabled"
    else
        oc patch consoles.operator.openshift.io cluster --type json \
            --patch '[{"op":"add","path":"/spec/plugins/-","value":"kuadrant-console-plugin"}]' 2>/dev/null
        or warn "Could not enable console plugin (OpenShift consoles API not available)"
    end

    if test -n "$CONSOLE_PLUGIN_IMAGE"
        info "Overriding console plugin image to $CONSOLE_PLUGIN_IMAGE..."
        kubectl set image -n $KUADRANT_NS deployment/kuadrant-console-plugin \
            kuadrant-console-plugin=$CONSOLE_PLUGIN_IMAGE
        or warn "Could not override console plugin image"
        kubectl -n $KUADRANT_NS rollout status deployment/kuadrant-console-plugin --timeout=120s
        or warn "Console plugin rollout did not complete"
    end
end

function deploy_observability
    info "Enabling user workload monitoring..."
    kubectl apply -f $SCRIPT_DIR/config/observability/user-workload-monitoring.yaml 2>/dev/null
    or warn "Could not enable user workload monitoring (openshift-monitoring namespace not found)"

    kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

    info "Generating custom-resource-state ConfigMap for kube-state-metrics..."
    $REPO_PATH/bin/kustomize build "github.com/Kuadrant/gateway-api-state-metrics/config/kuadrant?ref=0.7.0" | kubectl apply -f -
    or warn "Could not apply gateway-api-state-metrics"

    info "Deploying kube-state-metrics for Kuadrant CRDs..."
    kubectl apply -f $REPO_PATH/config/observability/openshift/kube-state-metrics.yaml
    or warn "Could not deploy kube-state-metrics"

    info "Deploying Istio telemetry for Prometheus metrics..."
    kubectl apply -f $REPO_PATH/config/observability/openshift/telemetry.yaml 2>/dev/null; or true

    info "Installing Grafana Operator via OLM..."
    if not kubectl apply -f $REPO_PATH/config/observability/openshift/grafana/subscription.yaml 2>/dev/null
        warn "Could not create Grafana subscription (OLM not available). Skipping Grafana setup."
    else
        info "Waiting for OLM to install Grafana operator..."
        set -l grafana_ready false
        for i in (seq 1 60)
            if kubectl get crd grafanas.grafana.integreatly.org >/dev/null 2>&1
                set grafana_ready true
                break
            end
            sleep 5
        end

        if test $grafana_ready = true
            kubectl wait --for=condition=Established crd/grafanas.grafana.integreatly.org --timeout=300s
            kubectl wait --for=condition=Established crd/grafanadatasources.grafana.integreatly.org --timeout=60s
            kubectl wait --for=condition=Established crd/grafanadashboards.grafana.integreatly.org --timeout=60s

            info "Deploying Grafana service account and RBAC..."
            kubectl apply -f $SCRIPT_DIR/config/observability/grafana-sa.yaml

            info "Deploying Grafana instance..."
            kubectl apply -n monitoring -f $REPO_PATH/config/observability/openshift/grafana/grafana.yaml

            info "Deploying Grafana datasource (CRC-local Thanos)..."
            kubectl apply -f $SCRIPT_DIR/config/observability/grafana-datasource.yaml

            info "Deploying dashboard ConfigMaps..."
            $REPO_PATH/bin/kustomize build $REPO_PATH/examples/dashboards | kubectl apply -f -

            info "Creating pod-resources dashboard ConfigMap..."
            kubectl create configmap grafana-kuadrant-pod-resources \
                --from-file=kuadrant-pod-resources.json=$SCRIPT_DIR/dashboards/kuadrant-pod-resources.json \
                -n $KUADRANT_NS --dry-run=client -o yaml | kubectl apply -f -

            info "Deploying GrafanaDashboard resources..."
            kubectl apply -n monitoring -f $REPO_PATH/config/observability/openshift/grafana/dashboards.yaml
            kubectl apply -f $SCRIPT_DIR/config/observability/pod-resources-dashboard.yaml
        else
            warn "Grafana CRDs never appeared. Skipping Grafana setup."
        end
    end

    info "Installing Jaeger..."
    kubectl create namespace observability --dry-run=client -o yaml | kubectl apply -f -
    $REPO_PATH/bin/helm repo add jaegertracing https://jaegertracing.github.io/helm-charts 2>/dev/null; or true
    $REPO_PATH/bin/helm repo update jaegertracing
    $REPO_PATH/bin/helm upgrade --install jaeger jaegertracing/jaeger \
        --namespace observability \
        -f $SCRIPT_DIR/config/observability/jaeger-values.yaml \
        --wait
    or abort "Failed to install Jaeger"

    kubectl apply -f $SCRIPT_DIR/config/observability/jaeger-route.yaml 2>/dev/null
    or warn "Could not create Jaeger route (OpenShift Route API not available)"

    info "Deploying tracing configurations..."
    make -C $REPO_PATH deploy-tracing 2>/dev/null
    or warn "deploy-tracing had errors (non-fatal)"

    info "Patching operator deployments with OTEL env vars..."
    kubectl patch deployment kuadrant-operator-controller-manager -n $KUADRANT_NS --type strategic \
        -p '{"spec":{"template":{"spec":{"containers":[{"name":"manager","env":[{"name":"OTEL_EXPORTER_OTLP_ENDPOINT","value":"rpc://jaeger.observability.svc.cluster.local:4317"},{"name":"OTEL_EXPORTER_OTLP_INSECURE","value":"true"}]}]}}}}'
    or warn "Could not patch kuadrant-operator with OTEL env vars"
    kubectl patch deployment limitador-operator-controller-manager -n $KUADRANT_NS --type strategic \
        -p '{"spec":{"template":{"spec":{"containers":[{"name":"manager","env":[{"name":"OTEL_EXPORTER_OTLP_ENDPOINT","value":"rpc://jaeger.observability.svc.cluster.local:4317"},{"name":"OTEL_EXPORTER_OTLP_INSECURE","value":"true"}]}]}}}}'
    or warn "Could not patch limitador-operator with OTEL env vars"

    info "Observability stack deployed."
end

function deploy_sample
    kubectl create namespace $TOYSTORE_NS --dry-run=client -o yaml | kubectl apply -f -

    set -l existing_ns (kubectl get kuadrant -A --no-headers 2>/dev/null | head -1 | awk '{print $1}')
    if test -n "$existing_ns"
        info "Kuadrant CR already exists in $existing_ns, waiting for Ready..."
        kubectl -n $existing_ns wait --timeout=300s --for=condition=Ready kuadrant/kuadrant
        or abort "Timed out waiting for Kuadrant CR to be Ready"
    else
        info "Deploying Kuadrant CR to $KUADRANT_NS..."
        kubectl apply -f $REPO_PATH/config/install/configure/standard/kuadrant.yaml
        or abort "Failed to apply Kuadrant CR"
        kubectl -n $KUADRANT_NS wait --timeout=300s --for=condition=Ready kuadrant/kuadrant
        or abort "Timed out waiting for Kuadrant CR to be Ready"
    end

    info "Deploying toystore sample application..."
    kubectl apply -n $TOYSTORE_NS -f $REPO_PATH/examples/toystore/toystore.yaml
    or abort "Failed to deploy toystore"
    kubectl -n $TOYSTORE_NS wait --timeout=120s --for=condition=Available deployment/toystore
    or abort "Timed out waiting for toystore deployment"

    info "Deploying API key secrets..."
    kubectl apply -n $TOYSTORE_NS -f $REPO_PATH/examples/toystore/alice-api-key-secret.yaml
    kubectl apply -n $TOYSTORE_NS -f $REPO_PATH/examples/toystore/bob-api-key-secret.yaml
    kubectl apply -n $TOYSTORE_NS -f $REPO_PATH/examples/toystore/admin-key-secret.yaml

    info "Deploying HTTPRoute (CRC)..."
    kubectl apply -n $TOYSTORE_NS -f $SCRIPT_DIR/config/toystore/httproute.yaml
    or abort "Failed to apply HTTPRoute"

    info "Deploying AuthPolicy..."
    kubectl apply -n $TOYSTORE_NS -f $SCRIPT_DIR/config/toystore/authpolicy.yaml
    or abort "Failed to apply AuthPolicy"

    info "Deploying RateLimitPolicy..."
    kubectl apply -n $TOYSTORE_NS -f $REPO_PATH/examples/toystore/ratelimitpolicy_httproute.yaml
    or abort "Failed to apply RateLimitPolicy"

    info "Creating OpenShift Route for toystore..."
    kubectl apply -n gateway-system -f $SCRIPT_DIR/config/toystore/route.yaml 2>/dev/null
    or warn "Could not create toystore route (OpenShift Route API not available)"

    echo ""
    echo "=== CRC Setup Complete ==="
    echo ""
    echo "Dashboards:"
    echo "  Console:  https://console-openshift-console.apps-crc.testing  (kubeadmin / "(crc console --credentials 2>/dev/null | grep kubeadmin | sed 's/.*-p //' | sed 's/ .*//')")"
    set -l grafana_host (oc get route -n monitoring grafana-route -o jsonpath='{.spec.host}' 2>/dev/null)
    if test -n "$grafana_host"
        echo "  Grafana:  https://$grafana_host  (root / secret)"
    end
    set -l jaeger_host (oc get route -n observability jaeger -o jsonpath='{.spec.host}' 2>/dev/null)
    if test -n "$jaeger_host"
        echo "  Jaeger:   https://$jaeger_host"
    end
    echo ""
    echo "Toystore sample app:"
    echo "  URL:      https://toystore.apps-crc.testing"
    echo ""
    echo "  Test authenticated request:"
    echo "    curl -sk https://toystore.apps-crc.testing/toy -H 'Authorization: APIKEY ALICEKEYFORDEMO'"
    echo ""
    echo "  Test unauthenticated request (should return 401):"
    echo "    curl -sk https://toystore.apps-crc.testing/toy"
    echo ""
    echo "  Test rate limiting (send requests until you see 429):"
    echo '    for i in (seq 1 7); curl -sk -o /dev/null -w "%{http_code}\n" https://toystore.apps-crc.testing/toy -H "Authorization: APIKEY ALICEKEYFORDEMO"; end'
    echo ""
end

function do_deploy
    crc_check
    ensure_tools
    env_setup
    deploy_operator
    deploy_observability
    deploy_sample
end

function do_redeploy
    set -l CRC_IMG "$CRC_REGISTRY/$KUADRANT_NS/kuadrant-operator:dev"

    crc_check

    info "Building operator image..."
    make -C $REPO_PATH docker-build IMG=$CRC_IMG CONTAINER_ENGINE=$CONTAINER_ENGINE
    or abort "Failed to build operator image"

    info "Pushing image to CRC registry..."
    if not oc whoami -t >/dev/null 2>&1
        set -l crc_pass (crc console --credentials 2>/dev/null | grep kubeadmin | sed 's/.*-p //' | sed 's/ .*//')
        oc login -u kubeadmin -p $crc_pass https://api.crc.testing:6443 --insecure-skip-tls-verify >/dev/null
        or abort "Failed to login to CRC cluster for registry access"
    end
    set -l token (oc whoami -t)
    skopeo copy --dest-tls-verify=false --dest-creds=kubeadmin:$token containers-storage:$CRC_IMG docker://$CRC_IMG
    or abort "Failed to push image to CRC registry"

    info "Deploying operator..."
    make -C $REPO_PATH deploy IMG=$CRC_IMG
    or abort "Failed to deploy operator"

    info "Waiting for operator deployments..."
    kubectl -n $KUADRANT_NS wait --timeout=300s --for=condition=Available deployments --all
    or abort "Timed out waiting for operator deployments"

    if test -n "$CONSOLE_PLUGIN_IMAGE"
        info "Overriding console plugin image to $CONSOLE_PLUGIN_IMAGE..."
        kubectl set image -n $KUADRANT_NS deployment/kuadrant-console-plugin \
            kuadrant-console-plugin=$CONSOLE_PLUGIN_IMAGE
        or warn "Could not override console plugin image"
        kubectl -n $KUADRANT_NS rollout status deployment/kuadrant-console-plugin --timeout=120s
        or warn "Console plugin rollout did not complete"
    end

    info "Redeploy complete."
end

# --- Main ---

set SUBCOMMAND ""
set REPO_PATH ""

switch (count $argv)
    case 1
        set REPO_PATH $argv[1]
        set SUBCOMMAND deploy
    case 2
        set SUBCOMMAND $argv[1]
        set REPO_PATH $argv[2]
    case '*'
        echo "Usage: deploy.fish [deploy|redeploy] <path/to/kuadrant-operator>"
        exit 1
end

set REPO_PATH (realpath $REPO_PATH 2>/dev/null)
if not test -d "$REPO_PATH"
    error "Repository path not found: $argv[-1]"
    exit 1
end

if not test -f "$REPO_PATH/Makefile"
    error "No Makefile found in $REPO_PATH — is this a kuadrant-operator checkout?"
    exit 1
end

switch $SUBCOMMAND
    case deploy ''
        do_deploy
    case redeploy
        do_redeploy
    case '*'
        error "Unknown subcommand: $SUBCOMMAND"
        echo "Usage: deploy.fish [deploy|redeploy] <path/to/kuadrant-operator>"
        exit 1
end
