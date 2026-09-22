#!/usr/bin/env fish

set SCRIPT_DIR (cd (dirname (status filename)); and pwd)
set CONFIG_FILE $SCRIPT_DIR/config.json

# Tee all output to a timestamped log file
if not set -q _DEPLOY_LOGGING
    set -l LOG_DIR $SCRIPT_DIR/logs
    mkdir -p $LOG_DIR
    set -l LOG_FILE $LOG_DIR/cleanup-(date +%Y%m%d-%H%M%S).log
    set -x _DEPLOY_LOGGING 1
    fish (status filename) $argv 2>&1 | tee $LOG_FILE
    set -l rc $pipestatus[1]
    if test $rc -eq 0
        echo "[INFO]  Log saved to $LOG_FILE"
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
    echo "[ERROR] No kubeconfig found at $KUBECONFIG" >&2
    echo "[ERROR] Start CRC first with ./start-crc.fish, or copy your kubeconfig to $KUBECONFIG" >&2
    exit 1
end

set GATEWAY_PROVIDER (jq -r '.gateway_provider' $CONFIG_FILE)
set KUADRANT_NS (jq -r '.kuadrant_namespace' $CONFIG_FILE)
set TOYSTORE_NS (jq -r '.toystore_namespace' $CONFIG_FILE)

function info
    echo "[INFO]  $argv"
end

function error
    echo "[ERROR] $argv" >&2
end

function cleanup_sample
    info "Removing toystore sample app..."
    kubectl delete -n gateway-system -f $SCRIPT_DIR/config/toystore/route.yaml 2>/dev/null; or true
    kubectl delete -n $TOYSTORE_NS -f $REPO_PATH/examples/toystore/ratelimitpolicy_httproute.yaml 2>/dev/null; or true
    kubectl delete -n $TOYSTORE_NS -f $SCRIPT_DIR/config/toystore/authpolicy.yaml 2>/dev/null; or true
    kubectl delete -n $TOYSTORE_NS -f $SCRIPT_DIR/config/toystore/httproute.yaml 2>/dev/null; or true
    kubectl delete -n $TOYSTORE_NS -f $REPO_PATH/examples/toystore/admin-key-secret.yaml 2>/dev/null; or true
    kubectl delete -n $TOYSTORE_NS -f $REPO_PATH/examples/toystore/bob-api-key-secret.yaml 2>/dev/null; or true
    kubectl delete -n $TOYSTORE_NS -f $REPO_PATH/examples/toystore/alice-api-key-secret.yaml 2>/dev/null; or true
    kubectl delete -n $TOYSTORE_NS -f $REPO_PATH/examples/toystore/toystore.yaml 2>/dev/null; or true
    kubectl -n $TOYSTORE_NS delete kuadrant/kuadrant 2>/dev/null; or true
    kubectl delete namespace $TOYSTORE_NS 2>/dev/null; or true
    info "Sample app removed."
end

function cleanup_observability
    info "Removing observability stack..."

    info "Removing tracing patches..."
    kubectl patch deployment kuadrant-operator-controller-manager -n $KUADRANT_NS --type json \
        -p '[{"op":"remove","path":"/spec/template/spec/containers/0/env"}]' 2>/dev/null; or true
    kubectl patch deployment limitador-operator-controller-manager -n $KUADRANT_NS --type json \
        -p '[{"op":"remove","path":"/spec/template/spec/containers/0/env"}]' 2>/dev/null; or true

    info "Removing tracing configurations..."
    make -C $REPO_PATH kustomize 2>/dev/null; or true
    $REPO_PATH/bin/kustomize build $REPO_PATH/config/observability/tracing 2>/dev/null | kubectl delete -f - 2>/dev/null; or true

    info "Removing Jaeger..."
    make -C $REPO_PATH uninstall-jaeger 2>/dev/null; or true
    kubectl delete -f $SCRIPT_DIR/config/observability/jaeger-route.yaml 2>/dev/null; or true

    info "Removing Grafana dashboards and resources..."
    kubectl delete -f $SCRIPT_DIR/config/observability/pod-resources-dashboard.yaml 2>/dev/null; or true
    kubectl delete -n monitoring -f $REPO_PATH/config/observability/openshift/grafana/dashboards.yaml 2>/dev/null; or true
    kubectl delete configmap grafana-kuadrant-pod-resources -n $KUADRANT_NS 2>/dev/null; or true
    $REPO_PATH/bin/kustomize build $REPO_PATH/examples/dashboards 2>/dev/null | kubectl delete -f - 2>/dev/null; or true

    info "Removing Grafana datasource..."
    kubectl delete -f $SCRIPT_DIR/config/observability/grafana-datasource.yaml 2>/dev/null; or true

    info "Removing Grafana instance..."
    kubectl delete -n monitoring -f $REPO_PATH/config/observability/openshift/grafana/grafana.yaml 2>/dev/null; or true

    info "Removing Grafana service account and RBAC..."
    kubectl delete -f $SCRIPT_DIR/config/observability/grafana-sa.yaml 2>/dev/null; or true

    info "Removing Grafana Operator..."
    kubectl delete -f $REPO_PATH/config/observability/openshift/grafana/subscription.yaml 2>/dev/null; or true
    kubectl delete csv -n monitoring -l operators.coreos.com/grafana-operator.monitoring 2>/dev/null; or true

    info "Removing Istio telemetry..."
    kubectl delete -f $REPO_PATH/config/observability/openshift/telemetry.yaml 2>/dev/null; or true

    info "Removing kube-state-metrics..."
    kubectl delete -f $REPO_PATH/config/observability/openshift/kube-state-metrics.yaml 2>/dev/null; or true
    $REPO_PATH/bin/kustomize build "github.com/Kuadrant/gateway-api-state-metrics/config/kuadrant?ref=0.7.0" 2>/dev/null | kubectl delete -f - 2>/dev/null; or true

    info "Removing user workload monitoring config..."
    kubectl delete -f $SCRIPT_DIR/config/observability/user-workload-monitoring.yaml 2>/dev/null; or true

    kubectl delete namespace monitoring 2>/dev/null; or true
    kubectl delete namespace observability 2>/dev/null; or true

    info "Observability stack removed."
end

function cleanup_operator
    info "Removing Kuadrant operator..."

    info "Disabling console plugin..."
    set -l plugins (oc get consoles.operator.openshift.io cluster -o jsonpath='{.spec.plugins}' 2>/dev/null)
    if echo $plugins | grep -q kuadrant-console-plugin
        set -l idx (oc get consoles.operator.openshift.io cluster -o json 2>/dev/null | jq '.spec.plugins | to_entries[] | select(.value == "kuadrant-console-plugin") | .key')
        if test -n "$idx"
            oc patch consoles.operator.openshift.io cluster --type json \
                --patch "[{\"op\":\"remove\",\"path\":\"/spec/plugins/$idx\"}]" 2>/dev/null; or true
        end
    end

    info "Undeploying operator..."
    make -C $REPO_PATH undeploy 2>/dev/null; or true

    info "Uninstalling CRDs..."
    make -C $REPO_PATH uninstall 2>/dev/null; or true

    info "Operator removed."
end

function cleanup_gateway
    switch $GATEWAY_PROVIDER
        case istio
            info "Removing Istio gateway and Sail operator..."
            kubectl delete gateway kuadrant-ingressgateway -n gateway-system 2>/dev/null; or true
            helm uninstall sail-operator -n istio-system 2>/dev/null; or true
            kubectl delete namespace istio-system 2>/dev/null; or true
            kubectl delete namespace gateway-system 2>/dev/null; or true
        case envoygateway
            info "Removing Envoy Gateway..."
            kubectl delete gateway eg -n envoy-gateway-system 2>/dev/null; or true
            helm uninstall eg -n envoy-gateway-system 2>/dev/null; or true
            kubectl delete namespace envoy-gateway-system 2>/dev/null; or true
            kubectl delete namespace gateway-system 2>/dev/null; or true
    end
    info "Gateway provider removed."
end

function cleanup_dependencies
    info "Removing dependencies..."
    $REPO_PATH/bin/kustomize build $REPO_PATH/config/dependencies 2>/dev/null | kubectl delete -f - 2>/dev/null; or true
    info "Dependencies removed."

    info "Removing cert-manager..."
    $REPO_PATH/bin/kustomize build $REPO_PATH/config/dependencies/cert-manager 2>/dev/null | kubectl delete -f - 2>/dev/null; or true
    info "Cert-manager removed."

    info "Removing namespace $KUADRANT_NS..."
    kubectl delete namespace $KUADRANT_NS 2>/dev/null; or true
end

# --- Main ---

if test (count $argv) -ne 1
    echo "Usage: cleanup.fish <path/to/kuadrant-operator>"
    exit 1
end

set REPO_PATH (realpath $argv[1] 2>/dev/null)
if not test -d "$REPO_PATH"
    error "Repository path not found: $argv[1]"
    exit 1
end

if not test -f "$REPO_PATH/Makefile"
    error "No Makefile found in $REPO_PATH — is this a kuadrant-operator checkout?"
    exit 1
end

info "Cleaning up CRC cluster (reversing deploy)..."
echo ""

cleanup_sample
cleanup_observability
cleanup_operator
cleanup_gateway
cleanup_dependencies

echo ""
info "CRC cluster cleaned up."
