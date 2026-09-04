#!/usr/bin/env bash
# Backward-compatibility wrapper for benchmark_suite.sh
exec "$(dirname "$0")/benchmark_suite.sh" "$@"
