#!/usr/bin/env bash
# Monitor run.sh execution until completion

LOG_FILE="/tmp/run_all.log"
PID_FILE="/tmp/run_all.pid"

# Find the run.sh process
find_pid() {
  ps aux | grep -E "[b]ash.*run.sh all" | awk '{print $2}' | head -1
}

# Wait for process to complete
wait_for_completion() {
  local pid="$1"
  local elapsed=0
  
  echo "Monitoring process PID: $pid"
  echo "Log file: $LOG_FILE"
  echo ""
  echo "═══════════════════════════════════════════════════════════"
  echo "  Following output (Press Ctrl+C to stop monitoring)"
  echo "  (Process will continue running in background)"
  echo "═══════════════════════════════════════════════════════════"
  echo ""
  
  # Follow the log file
  tail -f "$LOG_FILE" 2>/dev/null &
  local tail_pid=$!
  
  # Wait for the main process to finish
  while kill -0 "$pid" 2>/dev/null; do
    sleep 1
    ((elapsed++))
    # Show progress every 30 seconds
    if (( elapsed % 30 == 0 )); then
      echo "[Monitor] Process still running... (${elapsed}s elapsed)" >&2
    fi
  done
  
  # Stop tailing
  kill $tail_pid 2>/dev/null
  wait $tail_pid 2>/dev/null
  
  echo ""
  echo "═══════════════════════════════════════════════════════════"
  echo "  Process completed!"
  echo "═══════════════════════════════════════════════════════════"
  echo ""
  
  # Show final status
  if [ -f "$LOG_FILE" ]; then
    echo "Final exit status:"
    tail -20 "$LOG_FILE" | grep -E "ERROR|SUCCESS|completed|failed" | tail -5
    echo ""
    echo "Full log available at: $LOG_FILE"
  fi
}

# Main execution
PID=$(find_pid)

if [ -z "$PID" ]; then
  echo "No running run.sh process found."
  echo "Checking if log file exists..."
  if [ -f "$LOG_FILE" ]; then
    echo "Showing last 50 lines of log:"
    tail -50 "$LOG_FILE"
  else
    echo "No log file found. The script may not be running."
  fi
  exit 1
fi

wait_for_completion "$PID"


