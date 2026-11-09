#!/usr/bin/env fish

set SCRIPT_DIR (cd (dirname (status filename)); and pwd)
set -gx KUBECONFIG $SCRIPT_DIR/kubeconfig

function info
    echo "[INFO]  $argv"
end

function get_count
    set -l resource $argv[1]
    set -l label $argv[2]
    set -l ns $argv[3]

    if test -n "$ns"
        kubectl get $resource -n $ns -l $label --no-headers 2>/dev/null | wc -l | string trim
    else
        kubectl get $resource -l $label --no-headers 2>/dev/null | wc -l | string trim
    end
end

info "Current load test resources:"
echo ""
printf "  %-20s %s\n" "Namespaces"      (get_count namespaces       batch=namespace-load)
printf "  %-20s %s\n" "Deployments"     (get_count deployments      batch=deployment-load    deployment-load-test)
printf "  %-20s %s\n" "Services"        (get_count services         batch=service-load       service-load-test)
printf "  %-20s %s\n" "ServiceAccounts" (get_count serviceaccounts  batch=sa-load            sa-load-test)
printf "  %-20s %s\n" "ConfigMaps"      (get_count configmaps       batch=configmap-load     configmap-load-test)
printf "  %-20s %s\n" "NetworkPolicies" (get_count networkpolicies  batch=netpol-load        netpol-load-test)
echo ""

info "Cleaning up load test resources..."
echo ""

info "Deleting NetworkPolicies..."
$SCRIPT_DIR/delete-networkpolicies.fish

info "Deleting ConfigMaps..."
$SCRIPT_DIR/delete-configmaps.fish

info "Deleting ServiceAccounts..."
$SCRIPT_DIR/delete-serviceaccounts.fish

info "Deleting Services..."
$SCRIPT_DIR/delete-services.fish

info "Deleting Deployments..."
$SCRIPT_DIR/delete-deployments.fish

info "Deleting Namespaces..."
$SCRIPT_DIR/delete-namespaces.fish

echo ""
info "Load test cleanup complete. Remaining:"
echo ""
printf "  %-20s %s\n" "Namespaces"      (get_count namespaces       batch=namespace-load)
printf "  %-20s %s\n" "Deployments"     (get_count deployments      batch=deployment-load    deployment-load-test)
printf "  %-20s %s\n" "Services"        (get_count services         batch=service-load       service-load-test)
printf "  %-20s %s\n" "ServiceAccounts" (get_count serviceaccounts  batch=sa-load            sa-load-test)
printf "  %-20s %s\n" "ConfigMaps"      (get_count configmaps       batch=configmap-load     configmap-load-test)
printf "  %-20s %s\n" "NetworkPolicies" (get_count networkpolicies  batch=netpol-load        netpol-load-test)
