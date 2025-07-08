#!/bin/bash
set -x # Enable debugging output

# This script automates the diagnosis of Claude API tool schema errors.

# --- Configuration ---
CLAUDE_CMD="$HOME/.claude/local/claude"
TEST_REQUEST_COMMAND="$CLAUDE_CMD \"this is a test request\""

# Define absolute paths for scripts and logs
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
MITMDUMP_LOG="$SCRIPT_DIR/mitmproxy.log"
MCP_VALIDATOR_SCRIPT="$SCRIPT_DIR/mcp_validator.py"
DIAGNOSIS_RESULTS_FILE="$SCRIPT_DIR/diagnosis_results.json"

DIAGNOSIS_START_MARKER="--- CLAUDE_TOOL_DIAGNOSIS_START ---"
DIAGNOSIS_END_MARKER="--- CLAUDE_TOOL_DIAGNOSIS_END ---"

# --- Functions ---
cleanup() {
    echo "Performing cleanup..."
    # Kill mitmdump process
    if [ -n "$MITMDUMP_PID" ]; then
        kill "$MITMDUMP_PID" 2>/dev/null
        wait "$MITMDUMP_PID" 2>/dev/null
    fi
    # Kill claude process if still running
    if [ -n "$CLAUDE_PID" ]; then
        kill "$CLAUDE_PID" 2>/dev/null
        wait "$CLAUDE_PID" 2>/dev/null
    fi
    unset HTTPS_PROXY
    unset NODE_EXTRA_CA_CERTS
    rm -f "$MCP_VALIDATOR_SCRIPT" "$MITMDUMP_LOG" # Do NOT remove $DIAGNOSIS_RESULTS_FILE
    echo "Cleanup complete. Diagnosis results are in $DIAGNOSIS_RESULTS_FILE."
}

# --- Main Script ---
trap cleanup EXIT # Ensure cleanup runs on exit

echo "Starting automated Claude tool diagnosis..."

# 1. Check for mitmdump and python3
if ! command -v mitmdump &> /dev/null; then
    echo "Error: mitmdump is not installed. Please install mitmproxy."
    exit 1
fi
if ! command -v python3 &> /dev/null; then
    echo "Error: python3 is not installed. Please install python3."
    exit 1
fi

# Resolve absolute path for mitmproxy CA cert
MITMPROXY_CA_DIR="$HOME/.mitmproxy"
MITMPROXY_CA_CERT="$MITMPROXY_CA_DIR/mitmproxy-ca-cert.pem"

# Check if mitmproxy CA cert exists
if [ ! -f "$MITMPROXY_CA_CERT" ]; then
    echo "Error: mitmproxy CA certificate not found at $MITMPROXY_CA_CERT."
    echo "Please run 'mitmproxy' or 'mitmdump' once manually to generate the certificates."
    echo "Then try running this script again."
    exit 1
fi

# 2. Create mcp_validator.py (with debugging prints)
echo "Creating $MCP_VALIDATOR_SCRIPT..."
cat > "$MCP_VALIDATOR_SCRIPT" << 'EOF'
import json
import re
import datetime
from mitmproxy import http
from mitmproxy import ctx

DIAGNOSIS_START_MARKER = "--- CLAUDE_TOOL_DIAGNOSIS_START ---"
DIAGNOSIS_END_MARKER = "--- CLAUDE_TOOL_DIAGNOSIS_END ---"

def response(flow: http.HTTPFlow) -> None:
    """
    This function is called for every HTTP response that mitmproxy intercepts.
    """
    # We only care about responses from the Anthropic messages API
    if "api.anthropic.com/v1/messages" not in flow.request.pretty_url:
        return

    # Check if the response is a 400 Bad Request
    if flow.response and flow.response.status_code == 400:
        try:
            response_data = json.loads(flow.response.get_text())
            error = response_data.get("error", {})

            # Check for the specific error type
            if error.get("type") == "invalid_request_error":
                message = error.get("message", "")
                
                # --- DEBUGGING PRINTS ---
                ctx.log.info(f"[DEBUG] Raw error message: {message}")
                match = re.search(r"tools\.([0-9]+)\.", message)
                ctx.log.info(f"[DEBUG] Regex match result: {match}")
                # --- END DEBUGGING PRINTS ---

                diagnosis_info = {}
                if match:
                    tool_index = int(match.group(1))
                    
                    # Load the corresponding request body to find the tool name
                    request_data = json.loads(flow.request.get_text())
                    tools = request_data.get("tools", [])
                    
                    if 0 <= tool_index < len(tools):
                        problem_tool = tools[tool_index]
                        tool_name = problem_tool.get("name")
                        schema_url = problem_tool.get("input_schema", {}).get("$schema", "Not specified")

                        diagnosis_info = {
                            "timestamp": datetime.datetime.now().isoformat(),
                            "tool_name": tool_name,
                            "tool_index": tool_index,
                            "schema_url": schema_url,
                            "message": "Problematic Tool Found"
                        }
                    else:
                        diagnosis_info = {
                            "timestamp": datetime.datetime.now().isoformat(),
                            "message": f"Error: Invalid tool index {tool_index} found in error message."
                        }
                else:
                    diagnosis_info = {
                        "timestamp": datetime.datetime.now().isoformat(),
                        "message": f"400 Bad Request detected, but tool index not found in error message: {message}"
                    }

                # Print the diagnosis directly to stdout (captured by mitmdump)
                print(DIAGNOSIS_START_MARKER)
                print(json.dumps(diagnosis_info))
                print(DIAGNOSIS_END_MARKER)

        except (json.JSONDecodeError, IndexError, KeyError) as e:
            # Print errors to stderr, so they don't interfere with JSON output
            import sys
            print(f"An error occurred while analyzing the response: {e}", file=sys.stderr)

EOF

# Verify creation and content
ls -l "$MCP_VALIDATOR_SCRIPT"
cat "$MCP_VALIDATOR_SCRIPT"
sleep 1 # Give filesystem a moment

# 3. Start mitmdump in background
echo "Starting mitmdump in background..."
mitmdump -s "$MCP_VALIDATOR_SCRIPT" > "$MITMDUMP_LOG" 2>&1 &
MITMDUMP_PID=$!

# Give mitmdump a moment to start
sleep 3

if ! kill -0 "$MITMDUMP_PID" 2>/dev/null; then
    echo "Error: mitmdump failed to start. Check $MITMDUMP_LOG for details."
    exit 1
fi

echo "mitmdump PID: $MITMDUMP_PID"

# 4. Set environment variables
export HTTPS_PROXY=http://127.0.0.1:8080
export NODE_EXTRA_CA_CERTS="$MITMPROXY_CA_CERT"

echo "Environment variables set."

# 5. Run claude test request in background
echo "Running claude test request..."
$TEST_REQUEST_COMMAND &
CLAUDE_PID=$!

# 6. Monitor mitmproxy.log for diagnosis
echo "Monitoring $MITMDUMP_LOG for diagnosis..."
DIAGNOSIS=""
TIMEOUT=60 # seconds
START_TIME=$(date +%s)

while [ -z "$DIAGNOSIS" ]; do
    if [ $(($(date +%s) - START_TIME)) -gt "$TIMEOUT" ]; then
        echo "Timeout: No diagnosis found within $TIMEOUT seconds."
        exit 1
    fi

    # Check if mitmdump is still running
    if ! kill -0 "$MITMDUMP_PID" 2>/dev/null; then
        echo "Error: mitmdump process died unexpectedly. Check $MITMDUMP_LOG."
        exit 1
    fi

    # Extract diagnosis (JSON string) between markers
    DIAGNOSIS=$(awk "/$DIAGNOSIS_START_MARKER/{flag=1;next}/$DIAGNOSIS_END_MARKER/{flag=0}flag" "$MITMDUMP_LOG" | tail -n 1)
    
    if [ -z "$DIAGNOSIS" ]; then
        sleep 1 # Wait before checking again
    fi
done

echo "Diagnosis found!"

# 7. Save diagnosis to file
python3 -c "import json; data = json.loads('$DIAGNOSIS'); print(json.dumps(data, indent=2))" > "$DIAGNOSIS_RESULTS_FILE"
echo "Diagnosis saved to $DIAGNOSIS_RESULTS_FILE"

# Script will automatically run cleanup via trap EXIT
