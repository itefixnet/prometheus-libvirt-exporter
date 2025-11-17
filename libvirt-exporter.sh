#!/bin/bash
#
# Libvirt Prometheus Exporter
# A bash-based exporter for libvirt hypervisor statistics
#

# Set strict error handling
set -euo pipefail

# Source configuration if available
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.sh"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

# Default configuration
VIRSH_COMMAND="${VIRSH_COMMAND:-virsh}"
LIBVIRT_URI="${LIBVIRT_URI:-qemu:///system}"
METRICS_PREFIX="${METRICS_PREFIX:-libvirt}"

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

# Function to execute virsh commands
virsh_cmd() {
    local cmd="$1"
    timeout 30 "${VIRSH_COMMAND}" -c "${LIBVIRT_URI}" "$cmd" 2>/dev/null || echo ""
}

# Function to format Prometheus metric
format_metric() {
    local metric_name="$1"
    local value="$2"
    local labels="$3"
    local help="$4"
    local type="${5:-gauge}"
    
    echo "# HELP ${METRICS_PREFIX}_${metric_name} ${help}"
    echo "# TYPE ${METRICS_PREFIX}_${metric_name} ${type}"
    if [[ -n "$labels" ]]; then
        echo "${METRICS_PREFIX}_${metric_name}{${labels}} ${value}"
    else
        echo "${METRICS_PREFIX}_${metric_name} ${value}"
    fi
}

# Function to extract numeric value from output
extract_value() {
    local line="$1"
    echo "$line" | grep -oE '[0-9]+(\.[0-9]+)?' | head -1 || echo "0"
}

# Function to get hypervisor information
get_hypervisor_info() {
    local nodeinfo
    nodeinfo=$(virsh_cmd "nodeinfo")
    
    if [[ -n "$nodeinfo" ]]; then
        local model cpu_speed cpus cpu_sockets cores_per_socket threads_per_core memory_kb
        
        model=$(echo "$nodeinfo" | grep "CPU model:" | sed 's/CPU model:[[:space:]]*//')
        cpu_speed=$(echo "$nodeinfo" | grep "CPU frequency:" | grep -oE '[0-9]+')
        cpus=$(echo "$nodeinfo" | grep "CPU(s):" | grep -oE '[0-9]+')
        cpu_sockets=$(echo "$nodeinfo" | grep "CPU socket(s):" | grep -oE '[0-9]+')
        cores_per_socket=$(echo "$nodeinfo" | grep "Core(s) per socket:" | grep -oE '[0-9]+')
        threads_per_core=$(echo "$nodeinfo" | grep "Thread(s) per core:" | grep -oE '[0-9]+')
        memory_kb=$(echo "$nodeinfo" | grep "Memory size:" | grep -oE '[0-9]+')
        
        [[ -n "$cpu_speed" ]] && format_metric "host_cpu_frequency_mhz" "$cpu_speed" "" "Host CPU frequency in MHz"
        [[ -n "$cpus" ]] && format_metric "host_cpu_total" "$cpus" "" "Total number of host CPUs"
        [[ -n "$cpu_sockets" ]] && format_metric "host_cpu_sockets" "$cpu_sockets" "" "Number of CPU sockets"
        [[ -n "$cores_per_socket" ]] && format_metric "host_cores_per_socket" "$cores_per_socket" "" "CPU cores per socket"
        [[ -n "$threads_per_core" ]] && format_metric "host_threads_per_core" "$threads_per_core" "" "Threads per CPU core"
        [[ -n "$memory_kb" ]] && format_metric "host_memory_total_bytes" "$((memory_kb * 1024))" "" "Total host memory in bytes"
    fi
}

# Function to get host memory usage
get_host_memory_usage() {
    local meminfo
    meminfo=$(virsh_cmd "freecell --all")
    
    if [[ -n "$meminfo" ]]; then
        while IFS= read -r line; do
            if [[ "$line" =~ ^[[:space:]]*([0-9]+):[[:space:]]*([0-9]+) ]]; then
                local node="${BASH_REMATCH[1]}"
                local free_kb="${BASH_REMATCH[2]}"
                format_metric "host_memory_free_bytes" "$((free_kb * 1024))" "numa_node=\"$node\"" "Free memory per NUMA node in bytes"
            fi
        done <<< "$meminfo"
    fi
}

# Function to get domain list and basic stats
get_domain_stats() {
    local domains
    domains=$(virsh_cmd "list --all")
    
    local running_count=0
    local shutoff_count=0
    local paused_count=0
    local other_count=0
    
    while IFS= read -r line; do
        # Skip header lines
        [[ "$line" =~ ^[[:space:]]*Id || "$line" =~ ^[[:space:]]*-- ]] && continue
        
        if [[ "$line" =~ ^[[:space:]]*-?[[:space:]]*([^[:space:]]+)[[:space:]]+(.+)$ ]]; then
            local domain_name="${BASH_REMATCH[1]}"
            local state="${BASH_REMATCH[2]}"
            
            case "$state" in
                "running")
                    running_count=$((running_count + 1))
                    format_metric "domain_state" "1" "domain=\"$domain_name\",state=\"running\"" "Domain state (1=active, 0=inactive)"
                    ;;
                "shut off")
                    shutoff_count=$((shutoff_count + 1))
                    format_metric "domain_state" "0" "domain=\"$domain_name\",state=\"shutoff\"" "Domain state (1=active, 0=inactive)"
                    ;;
                "paused")
                    paused_count=$((paused_count + 1))
                    format_metric "domain_state" "0" "domain=\"$domain_name\",state=\"paused\"" "Domain state (1=active, 0=inactive)"
                    ;;
                *)
                    other_count=$((other_count + 1))
                    format_metric "domain_state" "0" "domain=\"$domain_name\",state=\"other\"" "Domain state (1=active, 0=inactive)"
                    ;;
            esac
        fi
    done <<< "$domains"
    
    format_metric "domains_total" "$running_count" "state=\"running\"" "Total number of domains by state" "counter"
    format_metric "domains_total" "$shutoff_count" "state=\"shutoff\"" "Total number of domains by state" "counter"
    format_metric "domains_total" "$paused_count" "state=\"paused\"" "Total number of domains by state" "counter"
    format_metric "domains_total" "$other_count" "state=\"other\"" "Total number of domains by state" "counter"
}

# Function to get detailed domain metrics for running domains
get_running_domain_metrics() {
    local running_domains
    running_domains=$(virsh_cmd "list --state-running --name")
    
    while IFS= read -r domain; do
        [[ -z "$domain" ]] && continue
        
        # Get domain info
        local dominfo
        dominfo=$(virsh_cmd "dominfo $domain")
        
        if [[ -n "$dominfo" ]]; then
            local max_mem used_mem cpus cpu_time
            max_mem=$(echo "$dominfo" | grep "Max memory:" | grep -oE '[0-9]+')
            used_mem=$(echo "$dominfo" | grep "Used memory:" | grep -oE '[0-9]+')
            cpus=$(echo "$dominfo" | grep "CPU(s):" | grep -oE '[0-9]+')
            
            [[ -n "$max_mem" ]] && format_metric "domain_memory_max_bytes" "$((max_mem * 1024))" "domain=\"$domain\"" "Maximum memory for domain in bytes"
            [[ -n "$used_mem" ]] && format_metric "domain_memory_used_bytes" "$((used_mem * 1024))" "domain=\"$domain\"" "Used memory for domain in bytes"
            [[ -n "$cpus" ]] && format_metric "domain_vcpu_total" "$cpus" "domain=\"$domain\"" "Number of virtual CPUs for domain"
        fi
        
        # Get CPU stats
        local cpu_stats
        cpu_stats=$(virsh_cmd "cpu-stats $domain --total")
        
        if [[ -n "$cpu_stats" ]]; then
            while IFS= read -r line; do
                if [[ "$line" =~ cpu_time[[:space:]]+([0-9]+\.[0-9]+) ]]; then
                    local cpu_time="${BASH_REMATCH[1]}"
                    # Convert nanoseconds to seconds
                    cpu_time=$(echo "scale=6; $cpu_time / 1000000000" | bc -l 2>/dev/null || echo "$cpu_time")
                    format_metric "domain_cpu_time_seconds_total" "$cpu_time" "domain=\"$domain\"" "Total CPU time used by domain in seconds" "counter"
                fi
            done <<< "$cpu_stats"
        fi
        
        # Get memory stats
        local mem_stats
        mem_stats=$(virsh_cmd "dommemstat $domain")
        
        if [[ -n "$mem_stats" ]]; then
            while IFS= read -r line; do
                if [[ "$line" =~ ^([^[:space:]]+)[[:space:]]+([0-9]+)$ ]]; then
                    local stat_name="${BASH_REMATCH[1]}"
                    local stat_value="${BASH_REMATCH[2]}"
                    
                    case "$stat_name" in
                        "actual")
                            format_metric "domain_memory_actual_bytes" "$((stat_value * 1024))" "domain=\"$domain\"" "Actual memory used by domain in bytes"
                            ;;
                        "swap_in")
                            format_metric "domain_memory_swap_in_bytes" "$((stat_value * 1024))" "domain=\"$domain\"" "Memory swapped in for domain in bytes"
                            ;;
                        "swap_out")
                            format_metric "domain_memory_swap_out_bytes" "$((stat_value * 1024))" "domain=\"$domain\"" "Memory swapped out for domain in bytes"
                            ;;
                        "major_fault")
                            format_metric "domain_memory_major_faults_total" "$stat_value" "domain=\"$domain\"" "Total major page faults for domain" "counter"
                            ;;
                        "minor_fault")
                            format_metric "domain_memory_minor_faults_total" "$stat_value" "domain=\"$domain\"" "Total minor page faults for domain" "counter"
                            ;;
                        "unused")
                            format_metric "domain_memory_unused_bytes" "$((stat_value * 1024))" "domain=\"$domain\"" "Unused memory for domain in bytes"
                            ;;
                        "available")
                            format_metric "domain_memory_available_bytes" "$((stat_value * 1024))" "domain=\"$domain\"" "Available memory for domain in bytes"
                            ;;
                        "rss")
                            format_metric "domain_memory_rss_bytes" "$((stat_value * 1024))" "domain=\"$domain\"" "Resident set size for domain in bytes"
                            ;;
                    esac
                fi
            done <<< "$mem_stats"
        fi
        
        # Get block device stats
        local block_devices
        block_devices=$(virsh_cmd "domblklist $domain --details" | tail -n +3 | awk '{print $3}')
        
        while IFS= read -r device; do
            [[ -z "$device" ]] && continue
            
            local block_stats
            block_stats=$(virsh_cmd "domblkstat $domain $device")
            
            if [[ -n "$block_stats" ]]; then
                while IFS= read -r line; do
                    if [[ "$line" =~ ^([^[:space:]]+)[[:space:]]+([0-9]+)$ ]]; then
                        local stat_name="${BASH_REMATCH[1]}"
                        local stat_value="${BASH_REMATCH[2]}"
                        
                        case "$stat_name" in
                            "rd_req")
                                format_metric "domain_block_read_requests_total" "$stat_value" "domain=\"$domain\",device=\"$device\"" "Total block read requests for domain device" "counter"
                                ;;
                            "rd_bytes")
                                format_metric "domain_block_read_bytes_total" "$stat_value" "domain=\"$domain\",device=\"$device\"" "Total bytes read from domain device" "counter"
                                ;;
                            "wr_req")
                                format_metric "domain_block_write_requests_total" "$stat_value" "domain=\"$domain\",device=\"$device\"" "Total block write requests for domain device" "counter"
                                ;;
                            "wr_bytes")
                                format_metric "domain_block_write_bytes_total" "$stat_value" "domain=\"$domain\",device=\"$device\"" "Total bytes written to domain device" "counter"
                                ;;
                        esac
                    fi
                done <<< "$block_stats"
            fi
        done <<< "$block_devices"
        
        # Get network interface stats
        local net_interfaces
        net_interfaces=$(virsh_cmd "domiflist $domain" | tail -n +3 | awk '{print $1}')
        
        while IFS= read -r interface; do
            [[ -z "$interface" ]] && continue
            
            local net_stats
            net_stats=$(virsh_cmd "domifstat $domain $interface")
            
            if [[ -n "$net_stats" ]]; then
                while IFS= read -r line; do
                    if [[ "$line" =~ ^([^[:space:]]+)[[:space:]]+([0-9]+)$ ]]; then
                        local stat_name="${BASH_REMATCH[1]}"
                        local stat_value="${BASH_REMATCH[2]}"
                        
                        case "$stat_name" in
                            "rx_bytes")
                                format_metric "domain_network_receive_bytes_total" "$stat_value" "domain=\"$domain\",interface=\"$interface\"" "Total bytes received by domain interface" "counter"
                                ;;
                            "rx_packets")
                                format_metric "domain_network_receive_packets_total" "$stat_value" "domain=\"$domain\",interface=\"$interface\"" "Total packets received by domain interface" "counter"
                                ;;
                            "rx_errs")
                                format_metric "domain_network_receive_errors_total" "$stat_value" "domain=\"$domain\",interface=\"$interface\"" "Total receive errors for domain interface" "counter"
                                ;;
                            "rx_drop")
                                format_metric "domain_network_receive_drop_total" "$stat_value" "domain=\"$domain\",interface=\"$interface\"" "Total receive drops for domain interface" "counter"
                                ;;
                            "tx_bytes")
                                format_metric "domain_network_transmit_bytes_total" "$stat_value" "domain=\"$domain\",interface=\"$interface\"" "Total bytes transmitted by domain interface" "counter"
                                ;;
                            "tx_packets")
                                format_metric "domain_network_transmit_packets_total" "$stat_value" "domain=\"$domain\",interface=\"$interface\"" "Total packets transmitted by domain interface" "counter"
                                ;;
                            "tx_errs")
                                format_metric "domain_network_transmit_errors_total" "$stat_value" "domain=\"$domain\",interface=\"$interface\"" "Total transmit errors for domain interface" "counter"
                                ;;
                            "tx_drop")
                                format_metric "domain_network_transmit_drop_total" "$stat_value" "domain=\"$domain\",interface=\"$interface\"" "Total transmit drops for domain interface" "counter"
                                ;;
                        esac
                    fi
                done <<< "$net_stats"
            fi
        done <<< "$net_interfaces"
        
    done <<< "$running_domains"
}

# Function to get storage pool information
get_storage_pool_stats() {
    local pools
    pools=$(virsh_cmd "pool-list --all")
    
    local active_count=0
    local inactive_count=0
    
    while IFS= read -r line; do
        # Skip header lines
        [[ "$line" =~ ^[[:space:]]*Name || "$line" =~ ^[[:space:]]*-- ]] && continue
        
        if [[ "$line" =~ ^[[:space:]]*([^[:space:]]+)[[:space:]]+([^[:space:]]+)[[:space:]]+([^[:space:]]+) ]]; then
            local pool_name="${BASH_REMATCH[1]}"
            local state="${BASH_REMATCH[2]}"
            local autostart="${BASH_REMATCH[3]}"
            
            if [[ "$state" == "active" ]]; then
                active_count=$((active_count + 1))
                format_metric "pool_state" "1" "pool=\"$pool_name\",state=\"active\"" "Storage pool state (1=active, 0=inactive)"
                
                # Get pool info for active pools
                local pool_info
                pool_info=$(virsh_cmd "pool-info $pool_name")
                
                if [[ -n "$pool_info" ]]; then
                    local capacity allocation available
                    # Handle different decimal separators (. and ,) and extract numeric values
                    capacity=$(echo "$pool_info" | grep "Capacity:" | grep -oE '[0-9]+[,.][0-9]+' | head -1 | tr ',' '.')
                    allocation=$(echo "$pool_info" | grep "Allocation:" | grep -oE '[0-9]+[,.][0-9]+' | head -1 | tr ',' '.')
                    available=$(echo "$pool_info" | grep "Available:" | grep -oE '[0-9]+[,.][0-9]+' | head -1 | tr ',' '.')
                    
                    # Convert to bytes (assuming GiB as typical unit)
                    if [[ -n "$capacity" ]]; then
                        local capacity_bytes=$(echo "$capacity * 1024 * 1024 * 1024" | bc -l 2>/dev/null | cut -d. -f1)
                        [[ -n "$capacity_bytes" ]] && format_metric "pool_capacity_bytes" "$capacity_bytes" "pool=\"$pool_name\"" "Storage pool capacity in bytes"
                    fi
                    if [[ -n "$allocation" ]]; then
                        local allocation_bytes=$(echo "$allocation * 1024 * 1024 * 1024" | bc -l 2>/dev/null | cut -d. -f1)
                        [[ -n "$allocation_bytes" ]] && format_metric "pool_allocation_bytes" "$allocation_bytes" "pool=\"$pool_name\"" "Storage pool allocation in bytes"
                    fi
                    if [[ -n "$available" ]]; then
                        local available_bytes=$(echo "$available * 1024 * 1024 * 1024" | bc -l 2>/dev/null | cut -d. -f1)
                        [[ -n "$available_bytes" ]] && format_metric "pool_available_bytes" "$available_bytes" "pool=\"$pool_name\"" "Storage pool available space in bytes"
                    fi
                fi
            else
                inactive_count=$((inactive_count + 1))
                format_metric "pool_state" "0" "pool=\"$pool_name\",state=\"inactive\"" "Storage pool state (1=active, 0=inactive)"
            fi
            
            format_metric "pool_autostart" "$([[ "$autostart" == "yes" ]] && echo "1" || echo "0")" "pool=\"$pool_name\"" "Storage pool autostart setting (1=enabled, 0=disabled)"
        fi
    done <<< "$pools"
    
    format_metric "pools_total" "$active_count" "state=\"active\"" "Total number of storage pools by state" "counter"
    format_metric "pools_total" "$inactive_count" "state=\"inactive\"" "Total number of storage pools by state" "counter"
}

# Function to get network information
get_network_stats() {
    local networks
    networks=$(virsh_cmd "net-list --all")
    
    local active_count=0
    local inactive_count=0
    
    while IFS= read -r line; do
        # Skip header lines
        [[ "$line" =~ ^[[:space:]]*Name || "$line" =~ ^[[:space:]]*-- ]] && continue
        
        if [[ "$line" =~ ^[[:space:]]*([^[:space:]]+)[[:space:]]+([^[:space:]]+)[[:space:]]+([^[:space:]]+)[[:space:]]+([^[:space:]]+) ]]; then
            local net_name="${BASH_REMATCH[1]}"
            local state="${BASH_REMATCH[2]}"
            local autostart="${BASH_REMATCH[3]}"
            local persistent="${BASH_REMATCH[4]}"
            
            if [[ "$state" == "active" ]]; then
                active_count=$((active_count + 1))
                format_metric "network_state" "1" "network=\"$net_name\",state=\"active\"" "Virtual network state (1=active, 0=inactive)"
            else
                inactive_count=$((inactive_count + 1))
                format_metric "network_state" "0" "network=\"$net_name\",state=\"inactive\"" "Virtual network state (1=active, 0=inactive)"
            fi
            
            format_metric "network_autostart" "$([[ "$autostart" == "yes" ]] && echo "1" || echo "0")" "network=\"$net_name\"" "Virtual network autostart setting (1=enabled, 0=disabled)"
            format_metric "network_persistent" "$([[ "$persistent" == "yes" ]] && echo "1" || echo "0")" "network=\"$net_name\"" "Virtual network persistent setting (1=persistent, 0=transient)"
        fi
    done <<< "$networks"
    
    format_metric "networks_total" "$active_count" "state=\"active\"" "Total number of virtual networks by state" "counter"
    format_metric "networks_total" "$inactive_count" "state=\"inactive\"" "Total number of virtual networks by state" "counter"
}

# Function to get hypervisor version and capabilities
get_hypervisor_version() {
    local version
    version=$(virsh_cmd "version")
    
    if [[ -n "$version" ]]; then
        # Extract libvirt version
        local libvirt_version
        libvirt_version=$(echo "$version" | grep -A1 "Compiled against library:" | tail -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
        
        if [[ -n "$libvirt_version" ]]; then
            # Convert version to numeric for easier comparison (e.g., 7.6.0 -> 7006000)
            local version_numeric
            version_numeric=$(echo "$libvirt_version" | awk -F. '{printf "%d%03d%03d", $1, $2, $3}')
            format_metric "hypervisor_libvirt_version" "$version_numeric" "version=\"$libvirt_version\"" "Libvirt version (numeric)"
        fi
    fi
}

# Main function to collect and output all metrics
collect_metrics() {
    # Check if virsh is available
    if ! command -v "${VIRSH_COMMAND}" >/dev/null 2>&1; then
        log "ERROR: ${VIRSH_COMMAND} not found in PATH"
        exit 1
    fi

    # Test connection to libvirt
    if ! virsh_cmd "version" >/dev/null 2>&1; then
        log "ERROR: Cannot connect to libvirt. Check if libvirt is running and accessible."
        exit 1
    fi

    # Output metrics header
    echo "# Libvirt Hypervisor Metrics"
    echo "# Generated at $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo ""

    # Collect all metrics
    get_hypervisor_version
    echo ""
    get_hypervisor_info
    echo ""
    get_host_memory_usage
    echo ""
    get_domain_stats
    echo ""
    get_running_domain_metrics
    echo ""
    get_storage_pool_stats
    echo ""
    get_network_stats
}

# Handle command line arguments
case "${1:-collect}" in
    "collect"|"metrics"|"")
        collect_metrics
        ;;
    "test")
        log "Testing connection to libvirt..."
        if virsh_cmd "version" >/dev/null 2>&1; then
            log "SUCCESS: Connected to libvirt"
            exit 0
        else
            log "ERROR: Cannot connect to libvirt"
            exit 1
        fi
        ;;
    "version")
        echo "Libvirt Exporter v1.0.0"
        ;;
    "help"|"-h"|"--help")
        echo "Usage: $0 [collect|test|version|help]"
        echo ""
        echo "Commands:"
        echo "  collect  - Collect and output Prometheus metrics (default)"
        echo "  test     - Test connection to libvirt"
        echo "  version  - Show exporter version"
        echo "  help     - Show this help message"
        echo ""
        echo "Environment variables:"
        echo "  VIRSH_COMMAND - Path to virsh binary (default: virsh)"
        echo "  LIBVIRT_URI   - Libvirt connection URI (default: qemu:///system)"
        echo "  METRICS_PREFIX - Metrics prefix (default: libvirt)"
        ;;
    *)
        log "ERROR: Unknown command: $1"
        echo "Use '$0 help' for usage information"
        exit 1
        ;;
esac