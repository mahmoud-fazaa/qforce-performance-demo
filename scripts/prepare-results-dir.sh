#!/bin/bash
# This script prepares the results directory

RESULTS_DIR="results"

echo "Cleaning previous results directory..."
rm -rf "${RESULTS_DIR}"
mkdir -p "${RESULTS_DIR}"
echo "Results directory prepared."