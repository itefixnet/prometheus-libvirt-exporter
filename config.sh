#!/bin/bash
#
# Libvirt Prometheus Exporter Configuration
# Source this file to configure the exporter settings
#

# Libvirt Configuration
export VIRSH_COMMAND="${VIRSH_COMMAND:-virsh}"
export LIBVIRT_URI="${LIBVIRT_URI:-qemu:///system}"

# Prometheus Exporter Configuration
export METRICS_PREFIX="${METRICS_PREFIX:-libvirt}"

# HTTP Server Configuration
export LISTEN_PORT="${LISTEN_PORT:-9179}"
export LISTEN_ADDRESS="${LISTEN_ADDRESS:-0.0.0.0}"
export MAX_CONNECTIONS="${MAX_CONNECTIONS:-10}"
export TIMEOUT="${TIMEOUT:-30}"

# Logging Configuration
export LOG_LEVEL="${LOG_LEVEL:-info}"

# Performance Configuration
export CACHE_TTL="${CACHE_TTL:-5}"  # seconds to cache metrics (not implemented yet)

# Advanced Configuration
export ENABLE_DOMAIN_METRICS="${ENABLE_DOMAIN_METRICS:-true}"
export ENABLE_STORAGE_METRICS="${ENABLE_STORAGE_METRICS:-true}"
export ENABLE_NETWORK_METRICS="${ENABLE_NETWORK_METRICS:-true}"
export ENABLE_HOST_METRICS="${ENABLE_HOST_METRICS:-true}"

# Remote Libvirt Support (if connecting to remote hypervisor)
# For SSH connections: export LIBVIRT_URI="qemu+ssh://user@remote-host/system"
# For TLS connections: export LIBVIRT_URI="qemu+tls://remote-host/system"
# For authenticated local: export LIBVIRT_URI="qemu:///session"

# Security Configuration
export LIBVIRT_CERT="${LIBVIRT_CERT:-}"
export LIBVIRT_KEY="${LIBVIRT_KEY:-}"
export LIBVIRT_CA="${LIBVIRT_CA:-}"

# Domain filtering (space-separated list of domain names to monitor)
# Leave empty to monitor all domains
export MONITOR_DOMAINS="${MONITOR_DOMAINS:-}"

# Storage pool filtering (space-separated list of pool names to monitor)
# Leave empty to monitor all pools
export MONITOR_POOLS="${MONITOR_POOLS:-}"

# Network filtering (space-separated list of network names to monitor)
# Leave empty to monitor all networks
export MONITOR_NETWORKS="${MONITOR_NETWORKS:-}"