#!/usr/bin/env fish

set SCRIPT_DIR (cd (dirname (status filename)); and pwd)
set -gx KUBECONFIG $SCRIPT_DIR/kubeconfig

# ── Target counts ──────────────────────────────────────────────
# Adjust these to control how many of each resource to create.
# The script is idempotent: it checks existing counts and only
# creates the difference.

set TARGET_NAMESPACES      200
set TARGET_DEPLOYMENTS     200
set TARGET_SERVICES        200
set TARGET_SERVICEACCOUNTS 200
set TARGET_CONFIGMAPS      200
set TARGET_NETWORKPOLICIES 200

# ───────────────────────────────────────────────────────────────

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

function create_if_needed
    set -l name $argv[1]
    set -l target $argv[2]
    set -l existing $argv[3]
    set -l cmd $argv[4..-1]

    if test $existing -ge $target
        info "$name: $existing already exist (target: $target), skipping"
        return
    end

    set -l needed (math $target - $existing)
    info "$name: $existing exist, creating $needed more (target: $target)"
    eval $cmd
end

info "Checking existing resource counts..."
echo ""

set existing_namespaces      (get_count namespaces       batch=namespace-load)
set existing_deployments     (get_count deployments      batch=deployment-load    deployment-load-test)
set existing_services        (get_count services         batch=service-load       service-load-test)
set existing_serviceaccounts (get_count serviceaccounts  batch=sa-load            sa-load-test)
set existing_configmaps      (get_count configmaps       batch=configmap-load     configmap-load-test)
set existing_networkpolicies (get_count networkpolicies  batch=netpol-load        netpol-load-test)

printf "  %-20s %6s / %s\n" "Namespaces"      $existing_namespaces      $TARGET_NAMESPACES
printf "  %-20s %6s / %s\n" "Deployments"      $existing_deployments     $TARGET_DEPLOYMENTS
printf "  %-20s %6s / %s\n" "Services"         $existing_services        $TARGET_SERVICES
printf "  %-20s %6s / %s\n" "ServiceAccounts"  $existing_serviceaccounts $TARGET_SERVICEACCOUNTS
printf "  %-20s %6s / %s\n" "ConfigMaps"       $existing_configmaps      $TARGET_CONFIGMAPS
printf "  %-20s %6s / %s\n" "NetworkPolicies"  $existing_networkpolicies $TARGET_NETWORKPOLICIES
echo ""

create_if_needed "Namespaces" $TARGET_NAMESPACES $existing_namespaces \
    "$SCRIPT_DIR/create-namespaces.fish -c "(math $TARGET_NAMESPACES - $existing_namespaces)

create_if_needed "Deployments" $TARGET_DEPLOYMENTS $existing_deployments \
    "$SCRIPT_DIR/create-deployments.fish -c "(math $TARGET_DEPLOYMENTS - $existing_deployments)

create_if_needed "Services" $TARGET_SERVICES $existing_services \
    "$SCRIPT_DIR/create-services.fish -c "(math $TARGET_SERVICES - $existing_services)

create_if_needed "ServiceAccounts" $TARGET_SERVICEACCOUNTS $existing_serviceaccounts \
    "$SCRIPT_DIR/create-serviceaccounts.fish -c "(math $TARGET_SERVICEACCOUNTS - $existing_serviceaccounts)

create_if_needed "ConfigMaps" $TARGET_CONFIGMAPS $existing_configmaps \
    "$SCRIPT_DIR/create-configmaps.fish "(math $TARGET_CONFIGMAPS - $existing_configmaps)

create_if_needed "NetworkPolicies" $TARGET_NETWORKPOLICIES $existing_networkpolicies \
    "$SCRIPT_DIR/create-networkpolicies.fish "(math $TARGET_NETWORKPOLICIES - $existing_networkpolicies)

echo ""
info "Load test setup complete. Final counts:"
echo ""
printf "  %-20s %s\n" "Namespaces"      (get_count namespaces       batch=namespace-load)
printf "  %-20s %s\n" "Deployments"     (get_count deployments      batch=deployment-load    deployment-load-test)
printf "  %-20s %s\n" "Services"        (get_count services         batch=service-load       service-load-test)
printf "  %-20s %s\n" "ServiceAccounts" (get_count serviceaccounts  batch=sa-load            sa-load-test)
printf "  %-20s %s\n" "ConfigMaps"      (get_count configmaps       batch=configmap-load     configmap-load-test)
printf "  %-20s %s\n" "NetworkPolicies" (get_count networkpolicies  batch=netpol-load        netpol-load-test)
