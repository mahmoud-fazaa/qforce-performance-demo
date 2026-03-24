#!/bin/bash

set -e

# BSD sed (macOS) requires a backup suffix for -i; GNU sed does not
sed_inplace() {
    if [ "$(uname -s)" = "Darwin" ]; then
        sed -i '' "$@"
    else
        sed -i "$@"
    fi
}

SERVICE=$1
MODULE=$2
TEST_PLAN=$3
SERVICE_BASE_URL=$4
THREADS=$5
RAMPUP=$6
LOOPS_OR_DURATION=$7
ENV=$8
MODE=${9:-LOOP}            # Default to LOOP if not specified
TEST_ACTION=${10:-ALL}     # Default ALL if not specified

# Resolve JMeter executable (macOS Homebrew: /opt/homebrew/bin/jmeter; Jenkins agents may not have Homebrew on PATH)
if [ -n "${JMETER_BIN:-}" ] && [ -x "${JMETER_BIN}" ]; then
    :
elif [ -n "${JMETER_HOME:-}" ] && [ -x "${JMETER_HOME}/bin/jmeter" ]; then
    JMETER_BIN="${JMETER_HOME}/bin/jmeter"
elif _jm="$(command -v jmeter 2>/dev/null)" && [ -n "${_jm}" ] && [ -x "${_jm}" ]; then
    JMETER_BIN="${_jm}"
elif [ -x /opt/homebrew/bin/jmeter ]; then
    JMETER_BIN=/opt/homebrew/bin/jmeter
elif [ -x /usr/local/bin/jmeter ]; then
    JMETER_BIN=/usr/local/bin/jmeter
else
    JMETER_BIN=""
fi
unset _jm 2>/dev/null || true

# Debug: Print all received parameters
echo "=== Script Parameters ==="
echo "SERVICE=$SERVICE"
echo "MODULE=$MODULE"
echo "TEST_PLAN=$TEST_PLAN"
echo "SERVICE_BASE_URL=$SERVICE_BASE_URL"
echo "THREADS=$THREADS"
echo "RAMPUP=$RAMPUP"
echo "LOOPS_OR_DURATION=$LOOPS_OR_DURATION"
echo "ENV=$ENV"
echo "MODE=$MODE"
echo "TEST_ACTION=$TEST_ACTION"
echo "========================"

# ReqRes: single ENV (dev|prod) drives x-reqres-env header and API key selection — never log key values
resolve_api_key() {
    case "${ENV}" in
        DEV|PROD) ;;
        *)
            echo "Error: ENV must be dev or prod (also sent as x-reqres-env), got: ${ENV}"
            exit 1
            ;;
    esac

    if [ -n "${API_KEY}" ]; then
        API_KEY_RESOLVED="${API_KEY}"
    elif [ "${ENV}" = "PROD" ] && [ -n "${REQRES_API_KEY_PROD}" ]; then
        API_KEY_RESOLVED="${REQRES_API_KEY_PROD}"
    elif [ "${ENV}" = "DEV" ] && [ -n "${REQRES_API_KEY_DEV}" ]; then
        API_KEY_RESOLVED="${REQRES_API_KEY_DEV}"
    else
        echo "Error: Missing API key. Set one of:"
        echo "  - API_KEY (direct), or"
        echo "  - REQRES_API_KEY_DEV and REQRES_API_KEY_PROD (Jenkins credentials / local exports)"
        echo "Current ENV (x-reqres-env): ${ENV}"
        exit 1
    fi
}
resolve_api_key
echo "ENV (x-reqres-env header): ${ENV}"

# Validate inputs first
if [ -z "$SERVICE" ] || [ -z "$TEST_PLAN" ] || [ -z "$SERVICE_BASE_URL" ] || [ -z "$THREADS" ] || [ -z "$RAMPUP" ] || [ -z "$LOOPS_OR_DURATION" ] || [ -z "$ENV" ]; then
    echo "Error: Missing required parameters"
    echo "Usage: $0 <service> <module> <test_plan> <service_base_url> <threads> <rampup> <loops_or_duration> <env> <mode> <test_action>"
    echo "Note: <env> must be dev or prod (x-reqres-env). ReqRes requires <module> products or users."
    echo "Received parameters: SERVICE=$SERVICE, MODULE=$MODULE, TEST_PLAN=$TEST_PLAN"
    exit 1
fi

if [ "$SERVICE" = "ReqRes" ]; then
    if [ -z "$MODULE" ] || [ "$MODULE" = "N/A" ]; then
        echo "Error: ReqRes requires MODULE (products or users)"
        exit 1
    fi
fi

# Construct test plan path based on module
echo "Debug: Constructing path - SERVICE=$SERVICE, MODULE=$MODULE, TEST_PLAN=$TEST_PLAN"
if [ -n "$MODULE" ] && [ "$MODULE" != "" ] && [ "$MODULE" != "N/A" ]; then
    # e.g. Core: Services/Core/testplans/{module}/{test_plan}
    TEST_PLAN_PATH="Services/${SERVICE}/testplans/${MODULE}/${TEST_PLAN}"
else
    # e.g. Reports (no module): Services/{Service}/testplans/{test_plan}
    TEST_PLAN_PATH="Services/${SERVICE}/testplans/${TEST_PLAN}"
fi
echo "Debug: Constructed TEST_PLAN_PATH=$TEST_PLAN_PATH"

# Create unique result directory based on test plan name to avoid conflicts in parallel runs
TEST_PLAN_NAME=$(basename "${TEST_PLAN}" .jmx)
RESULTS_DIR="results/${TEST_PLAN_NAME}"
mkdir -p "${RESULTS_DIR}"

# Create unique temp directory for this run to avoid conflicts in parallel execution
UNIQUE_TEMP_DIR="${RESULTS_DIR}/jmeter_temp_$$"
mkdir -p "${UNIQUE_TEMP_DIR}"

RESULT_FILE="${RESULTS_DIR}/result.jtl"
LOG_FILE="${RESULTS_DIR}/jmeter.log"

if [ ! -f "$TEST_PLAN_PATH" ]; then
    echo "Error: Test plan not found at $TEST_PLAN_PATH"
    echo "Debug: SERVICE=$SERVICE, MODULE=$MODULE, TEST_PLAN=$TEST_PLAN"
    echo "Debug: Constructed path=$TEST_PLAN_PATH"
    echo "Debug: Current directory=$(pwd)"
    echo "Debug: Checking if directory exists: $(ls -la Services/${SERVICE}/testplans/${MODULE}/ 2>&1 || echo 'Directory not found')"
    exit 1
fi

if [ ! -x "${JMETER_BIN}" ]; then
    echo "Error: JMeter not found or not executable: ${JMETER_BIN:-<empty>}"
    echo "Set JMETER_BIN (e.g. /opt/homebrew/bin/jmeter) or JMETER_HOME, or add JMeter to PATH."
    exit 1
fi

# Create a temporary copy of the test plan to avoid conflicts when multiple runs modify it in parallel
TEST_PLAN_COPY="${RESULTS_DIR}/$(basename ${TEST_PLAN})"
cp "${TEST_PLAN_PATH}" "${TEST_PLAN_COPY}"
echo "Created temporary copy of test plan: ${TEST_PLAN_COPY}"

# Cleanup function to remove temporary files
cleanup() {
    echo "Cleaning up temporary files..."
    rm -f "${TEST_PLAN_COPY}"
    rm -rf "${UNIQUE_TEMP_DIR}" 2>/dev/null || true
}
trap cleanup EXIT

# Build JMeter command based on execution mode
echo "=== JMeter Test Execution ==="
echo "Service: ${SERVICE}"
[ -n "$MODULE" ] && [ "$MODULE" != "" ] && echo "Module: ${MODULE}"
echo "Test Plan: ${TEST_PLAN}"
echo "Test Plan Path: ${TEST_PLAN_PATH}"
echo "Test Plan Copy: ${TEST_PLAN_COPY}"
echo "Service base URL: ${SERVICE_BASE_URL}"
echo "Environment: ${ENV}"
echo "Threads: ${THREADS}"
echo "Ramp-up: ${RAMPUP}s"
echo "Execution Mode: ${MODE}"
echo "Test Actions: ${TEST_ACTION}"

# Use the temporary copy instead of the original test plan
JMETER_CMD="${JMETER_BIN} -n -t ${TEST_PLAN_COPY}"
JMETER_CMD="${JMETER_CMD} -l ${RESULT_FILE}"
JMETER_CMD="${JMETER_CMD} -j ${LOG_FILE}"
JMETER_CMD="${JMETER_CMD} -Djava.awt.headless=true"
# Set unique temp directory for this JMeter instance to avoid conflicts
JMETER_CMD="${JMETER_CMD} -Djava.io.tmpdir=${UNIQUE_TEMP_DIR}"
JMETER_CMD="${JMETER_CMD} -JSERVICE_BASE_URL=${SERVICE_BASE_URL}"
JMETER_CMD="${JMETER_CMD} -Jthreads=${THREADS}"
JMETER_CMD="${JMETER_CMD} -Jrampup=${RAMPUP}"
JMETER_CMD="${JMETER_CMD} -JrampUp=${RAMPUP}"
JMETER_CMD="${JMETER_CMD} -JENV=${ENV}"
API_KEY_Q=$(printf '%q' "${API_KEY_RESOLVED}")
JMETER_CMD="${JMETER_CMD} -JAPI_KEY=${API_KEY_Q}"
JMETER_CMD="${JMETER_CMD} -JSERVICE=${SERVICE}"
JMETER_CMD="${JMETER_CMD} -JTEST_ACTION=${TEST_ACTION}"   # NEW

if [ "$MODE" = "DURATION" ]; then
    echo "Duration: ${LOOPS_OR_DURATION}s"
    JMETER_CMD="${JMETER_CMD} -Jduration=${LOOPS_OR_DURATION}"
    JMETER_CMD="${JMETER_CMD} -Jloops=-1"  # Infinite loops when using duration

    # Modify the temporary copy (not the original) to use scheduler
    echo "Enabling scheduler mode for duration-based execution..."
    sed_inplace 's/<boolProp name="ThreadGroup.scheduler">false<\/boolProp>/<boolProp name="ThreadGroup.scheduler">true<\/boolProp>/g' "${TEST_PLAN_COPY}"
    sed_inplace "s/<stringProp name=\"ThreadGroup.duration\"><\/stringProp>/<stringProp name=\"ThreadGroup.duration\">\${__P(duration,60)}<\/stringProp>/g" "${TEST_PLAN_COPY}"
else
    echo "Loop Count: ${LOOPS_OR_DURATION}"
    JMETER_CMD="${JMETER_CMD} -Jloops=${LOOPS_OR_DURATION}"

    # Ensure scheduler is disabled for loop mode (modify the copy, not the original)
    sed_inplace 's/<boolProp name="ThreadGroup.scheduler">true<\/boolProp>/<boolProp name="ThreadGroup.scheduler">false<\/boolProp>/g' "${TEST_PLAN_COPY}"
fi

# Add additional JMeter properties for better reporting
JMETER_CMD="${JMETER_CMD} -Jjmeter.save.saveservice.output_format=csv"
JMETER_CMD="${JMETER_CMD} -Jjmeter.save.saveservice.response_data=false"
JMETER_CMD="${JMETER_CMD} -Jjmeter.save.saveservice.samplerData=false"
JMETER_CMD="${JMETER_CMD} -Jjmeter.save.saveservice.requestHeaders=false"
JMETER_CMD="${JMETER_CMD} -Jjmeter.save.saveservice.url=true"
JMETER_CMD="${JMETER_CMD} -Jjmeter.save.saveservice.responseHeaders=false"

echo "==========================="
echo "Executing JMeter test..."
CMD_LOG="${JMETER_CMD//${API_KEY_RESOLVED}/-JAPI_KEY=***REDACTED***}"
echo "Command: ${CMD_LOG}"
echo "==========================="

# Execute JMeter test (suppress package scanning warnings)
set +e  # Don't exit on error, we'll check exit code manually
# Use a temp file for stderr to properly capture exit code
TEMP_STDERR="${RESULTS_DIR}/jmeter_stderr.tmp"
eval "${JMETER_CMD}" 2> "${TEMP_STDERR}"
EXIT_CODE=$?
# Filter and display stderr (excluding package scanning warnings)
if [ -f "${TEMP_STDERR}" ]; then
    grep -v "WARN StatusConsoleListener The use of package scanning" "${TEMP_STDERR}" >&2 || true
    rm -f "${TEMP_STDERR}"
fi
set -e  # Re-enable exit on error

# Check if test completed successfully
if [ $EXIT_CODE -eq 0 ]; then
    echo "✅ JMeter test completed successfully"

    # Display basic statistics
    if [ -f "${RESULT_FILE}" ]; then
        echo ""
        echo "=== Quick Statistics ==="
        TOTAL=$(tail -n +2 "${RESULT_FILE}" | wc -l)
        FAILED=$(tail -n +2 "${RESULT_FILE}" | awk -F',' '$8=="false"' | wc -l)
        SUCCESS=$((TOTAL - FAILED))

        if [ $TOTAL -gt 0 ]; then
            SUCCESS_RATE=$(echo "scale=2; $SUCCESS * 100 / $TOTAL" | bc)
            echo "Total Requests: ${TOTAL}"
            echo "Successful: ${SUCCESS}"
            echo "Failed: ${FAILED}"
            echo "Success Rate: ${SUCCESS_RATE}%"
        else
            echo "No results found in ${RESULT_FILE}"
        fi
        echo "========================"
    fi
else
    echo "❌ JMeter test failed with exit code: ${EXIT_CODE}"
    echo "Check log file for details: ${LOG_FILE}"
    exit ${EXIT_CODE}
fi

# ================================
# Generate JMeter HTML Dashboard
# ================================
echo ""
echo "=== Generating HTML Dashboard Report ==="

if [ -f "${RESULT_FILE}" ]; then
    REPORT_DIR="${RESULTS_DIR}/html-report"

    # Remove previous report folder if exists
    if [ -d "${REPORT_DIR}" ]; then
        echo "Removing previous HTML report..."
        rm -rf "${REPORT_DIR}"
    fi

    echo "Generating HTML report at: ${REPORT_DIR}"
    # Use unique temp directory for HTML report generation to avoid conflicts
    export JAVA_OPTS="-Djava.io.tmpdir=${UNIQUE_TEMP_DIR}"
    ${JMETER_BIN} -g "${RESULT_FILE}" -o "${REPORT_DIR}"

    if [ $? -eq 0 ]; then
        echo "📊 HTML Report Generated Successfully: ${REPORT_DIR}"
    else
        echo "⚠️ Failed to generate HTML report, check logs."
    fi
else
    echo "⚠️ No result.jtl found; skipping HTML report generation."
fi

echo "Results saved to: ${RESULT_FILE}"
echo "Log file: ${LOG_FILE}"

exit 0
