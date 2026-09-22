#!/usr/bin/env fish

set SCRIPT_DIR (cd (dirname (status filename)); and pwd)
set CONFIG_FILE $SCRIPT_DIR/config.json

# Tee all output to a timestamped log file
if not set -q _DEPLOY_LOGGING
    set -l LOG_DIR $SCRIPT_DIR/logs
    mkdir -p $LOG_DIR
    set -l LOG_FILE $LOG_DIR/start-crc-(date +%Y%m%d-%H%M%S).log
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

set CRC_CPUS (jq -r '.crc_cpus' $CONFIG_FILE)
set CRC_MEMORY (jq -r '.crc_memory' $CONFIG_FILE)
set CRC_DISK (jq -r '.crc_disk' $CONFIG_FILE)
set CRC_PULL_SECRET (jq -r '.crc_pull_secret' $CONFIG_FILE)

# Expand ~ in pull secret path
set CRC_PULL_SECRET (string replace '~' $HOME $CRC_PULL_SECRET)

function info
    echo "[INFO]  $argv"
end

function error
    echo "[ERROR] $argv" >&2
end

if not command -v crc >/dev/null 2>&1
    error "crc not found. Install it from: https://console.redhat.com/openshift/create/local"
    exit 1
end

set ACTION (test (count $argv) -gt 0; and echo $argv[1]; or echo start)

switch $ACTION
    case stop
        info "Stopping CRC..."
        crc stop
        info "CRC stopped."
        exit 0

    case status
        crc status
        exit 0

    case start
        # continue below

    case '*'
        error "Unknown action: $ACTION. Use: start, stop, status"
        exit 1
end

set CRC_KUBECONFIG $SCRIPT_DIR/kubeconfig

function copy_kubeconfig
    if test -f ~/.crc/machines/crc/kubeconfig
        cp ~/.crc/machines/crc/kubeconfig $CRC_KUBECONFIG
        info "Kubeconfig copied to $CRC_KUBECONFIG"
    else
        error "CRC kubeconfig not found at ~/.crc/machines/crc/kubeconfig"
    end
end

if crc status 2>/dev/null | grep -q Running
    info "CRC is already running."
    crc status
    copy_kubeconfig
    echo ""
    exit 0
end

info "Configuring CRC: $CRC_CPUS CPUs, $CRC_MEMORY MB RAM, $CRC_DISK GB disk, monitoring enabled"
crc config set cpus $CRC_CPUS
crc config set memory $CRC_MEMORY
crc config set disk-size $CRC_DISK
crc config set enable-cluster-monitoring true

if not test -f $CRC_PULL_SECRET
    error "Pull secret not found at: $CRC_PULL_SECRET"
    error "Download from: https://console.redhat.com/openshift/create/local"
    error "Save to ~/.crc/pull-secret or update crc_pull_secret in config.json"
    exit 1
end

info "Starting CRC..."
crc start --pull-secret-file $CRC_PULL_SECRET

copy_kubeconfig

echo ""
info "CRC is running."
info ""
info "  Console:     crc console"
info "  Credentials: crc console --credentials"
info ""
info "  Then run:    ./deploy.fish <path/to/kuadrant-operator>"
