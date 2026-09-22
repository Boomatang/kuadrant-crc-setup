#!/usr/bin/env fish

set SCRIPT_DIR (cd (dirname (status filename)); and pwd)
set CONFIG_FILE $SCRIPT_DIR/config.json

if not command -v crc >/dev/null 2>&1
    echo "[ERROR] crc not found" >&2
    exit 1
end

if not crc status 2>/dev/null | grep -q Running
    echo "[ERROR] CRC is not running. Start it with: ./start-crc.fish" >&2
    exit 1
end

set -l crc_pass (crc console --credentials 2>/dev/null | grep kubeadmin | sed 's/.*-p //' | sed 's/ .*//')

echo ""
echo "CRC Cluster"
echo ""
echo "  Console:   https://console-openshift-console.apps-crc.testing"
echo "  API:       https://api.crc.testing:6443"
echo "  Username:  kubeadmin"
echo "  Password:  $crc_pass"

set -gx KUBECONFIG $SCRIPT_DIR/kubeconfig
if test -f $KUBECONFIG
    set -l grafana_host (oc get route -n monitoring grafana-route -o jsonpath='{.spec.host}' 2>/dev/null)
    set -l jaeger_host (oc get route -n observability jaeger -o jsonpath='{.spec.host}' 2>/dev/null)
    set -l toystore_host (oc get route -n gateway-system toystore -o jsonpath='{.spec.host}' 2>/dev/null)

    if test -n "$grafana_host" -o -n "$jaeger_host" -o -n "$toystore_host"
        echo ""
        echo "Services"
        echo ""
        if test -n "$grafana_host"
            echo "  Grafana:   https://$grafana_host  (root / secret)"
        end
        if test -n "$jaeger_host"
            echo "  Jaeger:    https://$jaeger_host"
        end
        if test -n "$toystore_host"
            echo "  Toystore:  https://$toystore_host"
        end
    end
end

echo ""
echo "Login"
echo ""
echo "  oc login -u kubeadmin -p $crc_pass https://api.crc.testing:6443 --insecure-skip-tls-verify"
echo ""
