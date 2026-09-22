# Kuadrant CRC Setup

Scripts for deploying the [Kuadrant operator](https://github.com/Kuadrant/kuadrant-operator) on a local [CRC (CodeReady Containers)](https://console.redhat.com/openshift/create/local) OpenShift cluster, with a full observability stack and a sample application for testing.

## Prerequisites

- **CRC** installed ([download](https://console.redhat.com/openshift/create/local))
- **podman** and **skopeo** installed
- **jq** installed
- A **Red Hat pull secret** saved to `~/.crc/pull-secret` ([download](https://console.redhat.com/openshift/create/local))
- A local checkout of the **kuadrant-operator** repository

## Quick start

```fish
# 1. Start the CRC cluster
./start-crc.fish

# 2. Deploy everything (operator, observability, sample app)
./deploy.fish /path/to/kuadrant-operator

# 3. Run smoke tests
./test-toystore.fish
```

## Scripts

### `start-crc.fish`

Configures and starts the CRC virtual machine.

```fish
./start-crc.fish          # start CRC (or confirm it's already running)
./start-crc.fish stop     # stop the CRC VM
./start-crc.fish status   # show CRC status
```

### `deploy.fish`

Builds the operator from source, pushes it to CRC's internal registry, and deploys the full stack.

```fish
# Full deploy (dependencies, gateway, operator, observability, sample app)
./deploy.fish /path/to/kuadrant-operator

# Redeploy operator only (after code changes - skips environment setup)
./deploy.fish redeploy /path/to/kuadrant-operator
```

The full deploy installs:

- **cert-manager** and Kuadrant CRDs
- **Istio** (via Sail operator) or **Envoy Gateway**, depending on `config.json`
- The **Kuadrant operator** (built from your local checkout)
- **Observability stack**: Prometheus (user workload monitoring), Grafana with dashboards, Jaeger for tracing
- **Toystore** sample application with AuthPolicy and RateLimitPolicy

On completion, the script prints URLs and credentials for the OpenShift console, Grafana, Jaeger, and the toystore app.

### `test-toystore.fish`

Runs smoke tests against the deployed toystore application.

```fish
./test-toystore.fish          # run all tests
./test-toystore.fish auth     # authentication tests only
./test-toystore.fish rate     # rate limiting tests only
```

**Auth tests** verify:
- Unauthenticated requests return 401
- Invalid API keys return 401
- Valid API keys (Alice, Bob, Admin) return 200

**Rate limit tests** read the RateLimitPolicy from the cluster, send requests beyond the limit, and verify 429 responses appear.

### `creds.fish`

Prints cluster credentials, service URLs, and a ready-to-paste `oc login` command.

```fish
./creds.fish
```

### `cleanup.fish`

Tears down everything `deploy.fish` installed, in reverse order.

```fish
./cleanup.fish /path/to/kuadrant-operator
```

## Configuration

Edit `config.json` to customize the deployment:

```json
{
  "gateway_provider": "istio",
  "kuadrant_namespace": "kuadrant-system",
  "toystore_namespace": "toystore",
  "container_engine": "podman",
  "crc_registry": "default-route-openshift-image-registry.apps-crc.testing",
  "crc_cpus": 8,
  "crc_memory": 20480,
  "crc_disk": 100,
  "crc_pull_secret": "~/.crc/pull-secret",
  "console_plugin_image": ""
}
```

| Field | Description |
|-------|-------------|
| `gateway_provider` | `istio` or `envoygateway` |
| `kuadrant_namespace` | Namespace for the Kuadrant operator |
| `toystore_namespace` | Namespace for the sample application |
| `container_engine` | `podman` or `docker` |
| `crc_cpus` | CPU cores allocated to the CRC VM |
| `crc_memory` | Memory in MB allocated to the CRC VM |
| `crc_disk` | Disk size in GB for the CRC VM |
| `crc_pull_secret` | Path to your Red Hat pull secret |
| `console_plugin_image` | Override the console plugin image (empty = use operator default) |

## Project layout

```
.
├── config.json                  # deployment configuration
├── start-crc.fish               # start/stop/status for CRC
├── deploy.fish                  # full deploy and redeploy
├── creds.fish                   # show cluster credentials and URLs
├── test-toystore.fish           # smoke tests
├── cleanup.fish                 # tear down everything
├── kubeconfig                   # dedicated kubeconfig (created by start-crc.fish)
├── config/
│   ├── toystore/                # CRC-specific HTTPRoute, AuthPolicy, OpenShift Route
│   └── observability/           # Grafana SA/datasource, Jaeger values/route, monitoring config
├── dashboards/
│   └── kuadrant-pod-resources.json
└── logs/                        # timestamped logs from each script run
```

## Typical workflow

1. **Start CRC** once with `./start-crc.fish`
2. **Deploy** with `./deploy.fish /path/to/kuadrant-operator`
3. **Make code changes** to the operator
4. **Redeploy** with `./deploy.fish redeploy /path/to/kuadrant-operator` (rebuilds and pushes only the operator image)
5. **Test** with `./test-toystore.fish`
6. Repeat steps 3-5
7. **Clean up** with `./cleanup.fish /path/to/kuadrant-operator` when done

## Notes

- All scripts use a dedicated `kubeconfig` file in this directory so they don't interfere with your other cluster contexts.
- All script runs are logged to `logs/` with timestamps.
- The CRC VM needs roughly 8 CPUs, 20 GB RAM, and 100 GB disk by default. Adjust in `config.json` if needed.
