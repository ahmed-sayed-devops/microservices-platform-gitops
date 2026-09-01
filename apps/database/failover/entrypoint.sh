#!/usr/bin/env bash

set -u

echo "========================================"
echo "MySQL Failover Controller Starting"
echo "========================================"

echo "[INFO] Starting auto-failover controller..."
/controller/auto-failover.sh &
FAILOVER_PID=$!

echo "[INFO] Starting auto-rejoin controller..."
/controller/auto-rejoin.sh &
REJOIN_PID=$!

trap '
    kill "$FAILOVER_PID" "$REJOIN_PID" 2>/dev/null || true
' SIGTERM SIGINT

wait -n "$FAILOVER_PID" "$REJOIN_PID"

kill "$FAILOVER_PID" "$REJOIN_PID" 2>/dev/null || true

wait
