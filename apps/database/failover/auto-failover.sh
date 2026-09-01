#!/usr/bin/env bash

set -euo pipefail

MYSQL1="mysql-primary"
MYSQL2="mysql-replica"

STATE_FILE="/state/current-primary"

MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD}"

CHECK_INTERVAL=2
FAIL_THRESHOLD=3

FAIL_COUNT=0

echo "========================================"
echo "MySQL Auto Failover Started"
echo "========================================"

while true
do

    CURRENT_PRIMARY=$(cat "$STATE_FILE")

    if [ "$CURRENT_PRIMARY" = "$MYSQL1" ]; then
        CURRENT_REPLICA="$MYSQL2"
    else
        CURRENT_REPLICA="$MYSQL1"
    fi

    ####################################################
    # Check Current Primary
    ####################################################

    if mysqladmin \
        ping \
        -h "${CURRENT_PRIMARY}-0.${CURRENT_PRIMARY}.microservices.svc.cluster.local" \
        -uroot \
        -p"${MYSQL_ROOT_PASSWORD}" \
        --connect-timeout=2 \
        --silent >/dev/null 2>&1
    then

        if [ "$FAIL_COUNT" -gt 0 ]; then
            echo "[INFO] Primary recovered."
        fi

        FAIL_COUNT=0

        sleep "$CHECK_INTERVAL"
        continue
    fi

    ####################################################
    # Primary failed
    ####################################################

    FAIL_COUNT=$((FAIL_COUNT + 1))

    echo "[WARNING] Primary check failed (${FAIL_COUNT}/${FAIL_THRESHOLD})"

    if [ "$FAIL_COUNT" -lt "$FAIL_THRESHOLD" ]; then
        sleep "$CHECK_INTERVAL"
        continue
    fi

    echo "[FAILOVER] ${CURRENT_PRIMARY} considered FAILED."

    ####################################################
    # Make sure replica is alive
    ####################################################

    if ! mysqladmin \
        ping \
        -h "${CURRENT_REPLICA}-0.${CURRENT_REPLICA}.microservices.svc.cluster.local" \
        -uroot \
        -p"${MYSQL_ROOT_PASSWORD}" \
        --connect-timeout=2 \
        --silent >/dev/null 2>&1
    then

        echo "[ERROR] ${CURRENT_REPLICA} is also DOWN."

        sleep "$CHECK_INTERVAL"
        continue
    fi

    echo "========================================"
    echo "FAILOVER STARTED"
    echo "========================================"

    ####################################################
    # Promote replica
    ####################################################

    if mysql \
        -h "${CURRENT_REPLICA}-0.${CURRENT_REPLICA}.microservices.svc.cluster.local" \
        -uroot \
        -p"${MYSQL_ROOT_PASSWORD}" <<EOF
STOP REPLICA;
RESET REPLICA ALL;
SET GLOBAL super_read_only=OFF;
SET GLOBAL read_only=OFF;
EOF
    then

        echo "[SUCCESS] ${CURRENT_REPLICA} promoted."

        ################################################
        # Update state
        ################################################

        kubectl -n microservices patch configmap mysql-failover-state \
            --type merge \
            -p "{\"data\":{\"current-primary\":\"${CURRENT_REPLICA}\",\"rejoin-required\":\"true\"}}"

        echo "[INFO] New primary: ${CURRENT_REPLICA}"
        echo "[INFO] Rejoin required: true"

        ################################################
        # Update HAProxy
        ################################################

        echo "[INFO] Updating HAProxy configuration..."

        /scripts/generate-haproxy-config.sh

        ################################################
        # Restart HAProxy
        ################################################

        echo "[INFO] Restarting HAProxy..."

        kubectl -n microservices rollout restart deployment/mysql-router

        echo "[SUCCESS] HAProxy restart requested."

        FAIL_COUNT=0

        ################################################
        # Wait before checking again
        ################################################

        sleep 10

    else

        echo "[ERROR] Promotion failed."

        sleep "$CHECK_INTERVAL"
    fi

done
