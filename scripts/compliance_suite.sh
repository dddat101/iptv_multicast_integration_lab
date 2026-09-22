#!/usr/bin/env bash
# ==============================================================================
# IPTV MULTICAST LAB - COMPLIANCE SUITE WRAPPER
# Backward-compatibility wrapper delegating to benchmark_suite.sh
# ==============================================================================

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<'USAGE'
Description:
  Backward-compatibility entrypoint for running the IPTV Multicast Benchmark
  and RFC Verification Suite. Delegates directly to benchmark_suite.sh.

Usage:
  sudo ./scripts/compliance_suite.sh [benchmark]
  ./scripts/compliance_suite.sh -h | --help

Benchmarks:
  all          Execute all benchmark tests and generate comprehensive report [Default]
  quality      Multi-client concurrent packet loss & QoS benchmark
  stability    Multi-client Fast Leave isolation & zapping soak benchmark
  scale        Multicast group capacity scale benchmark
  churn        Rapid Join/Leave churn stability benchmark
  stress       High-rate Group-Specific Query stress benchmark
  loss         Multi-group UDP multicast packet loss measurement
  querier      Foreign LAN Querier injection & election benchmark
  diagnostics  Collect router multicast routing and snooping state
  pcap         Inspect packet capture headers and timing metrics

Options:
  -h, --help   Show this help message and exit

Examples:
  sudo ./scripts/compliance_suite.sh all
  sudo ./scripts/compliance_suite.sh quality
  ./scripts/compliance_suite.sh -h

Suggested Next Steps:
  - Run benchmark suite directly: sudo ./scripts/benchmark_suite.sh all
  - Verify compliance:            ./scripts/verify_compliance.sh
USAGE
}

for arg in "$@"; do
    if [[ "${arg}" == "-h" || "${arg}" == "--help" ]]; then
        usage
        exit 0
    fi
done

exec "${SCRIPT_DIR}/benchmark_suite.sh" "$@"
