#!/bin/bash

LOG_FILE="${EXPORTER_LOG_FILE:-/var/log/oracledb_exporter/exporter.log}"
LISTEN_ADDRESS="${EXPORTER_LISTEN_ADDRESS:-0.0.0.0:9161}"
PID_FILE="/tmp/oracledb_exporter.pid"

echo "Starting oracledb_exporter (v1.6.0) at $(date)" | tee -a "$LOG_FILE"
echo "DB_CONNECT_STRING: ${DB_CONNECT_STRING}" | tee -a "$LOG_FILE"

nohup /usr/local/bin/oracledb_exporter \
    --log.level error \
    --web.listen-address "$LISTEN_ADDRESS" \
    >> "$LOG_FILE" 2>&1 &

EXPORTER_PID=$!
echo $EXPORTER_PID > "$PID_FILE"
echo "Exporter PID: $EXPORTER_PID" | tee -a "$LOG_FILE"

sleep 2
if kill -0 $EXPORTER_PID 2>/dev/null; then
    echo "Exporter started successfully" | tee -a "$LOG_FILE"
else
    echo "Exporter failed to start" | tee -a "$LOG_FILE"
    cat "$LOG_FILE"
    exit 1
fi

cleanup() {
    echo "Stopping exporter (PID: $EXPORTER_PID)..." | tee -a "$LOG_FILE"
    kill $EXPORTER_PID 2>/dev/null
    wait $EXPORTER_PID
    rm -f "$PID_FILE"
    echo "Exporter stopped" | tee -a "$LOG_FILE"
}
trap cleanup SIGTERM SIGINT

wait $EXPORTER_PID
