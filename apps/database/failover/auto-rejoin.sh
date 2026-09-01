#!/usr/bin/env bash

set -euo pipefail

MYSQL1="mysql-primary"
MYSQL2="mysql-replica"

STATE_FILE="/state/current-primary"

MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD}"

REPLICATION_USER="replicator"
REPLICATION_PASSWORD="replica123"

CHECK_INTERVAL=3

echo "========================================"
echo "MySQL Auto Rejoin Started"
echo "========================================"

while true
do

    CURRENT_PRIMARY=$(cat "$STATE_FILE")

    REJOIN_REQUIRED=$(cat /state/rejoin-required)

    ####################################################
    # No rejoin required
    ####################################################

    if [ "$REJOIN_REQUIRED" != "true" ]; then

        sleep "$CHECK_INTERVAL"
        continue
    fi

    ####################################################
    # Determine replica
    ####################################################

    if [ "$CURRENT_PRIMARY" = "$MYSQL1" ]; then
        CURRENT_REPLICA="$MYSQL2"
    else
        CURRENT_REPLICA="$MYSQL1"
    fi

    PRIMARY_HOST="${CURRENT_PRIMARY}-0.${CURRENT_PRIMARY}.microservices.svc.cluster.local"
    REPLICA_HOST="${CURRENT_REPLICA}-0.${CURRENT_REPLICA}.microservices.svc.cluster.local"

    echo "========================================"
    echo "AUTO REJOIN"
    echo "========================================"

    echo "[INFO] Current primary: ${CURRENT_PRIMARY}"
    echo "[INFO] Rejoining: ${CURRENT_REPLICA}"

    ####################################################
    # Wait for failed MySQL to return
    ####################################################

    if ! mysqladmin \
        ping \
        -h "$REPLICA_HOST" \
        -uroot \
        -p"${MYSQL_ROOT_PASSWORD}" \
        --connect-timeout=2 \
        --silent >/dev/null 2>&1
    then

        echo "[INFO] ${CURRENT_REPLICA} is not available yet."

        sleep "$CHECK_INTERVAL"
        continue
    fi

    ####################################################
    # Check whether already replicating
    ####################################################

    STATUS=$(mysql \
        -h "$REPLICA_HOST" \
        -uroot \
        -p"${MYSQL_ROOT_PASSWORD}" \
        -e "SHOW REPLICA STATUS\G" 2>/dev/null || true)

    if echo "$STATUS" | grep -q "Replica_IO_Running: Yes" \
       && echo "$STATUS" | grep -q "Replica_SQL_Running: Yes"
    then

        echo "[INFO] ${CURRENT_REPLICA} is already replicating."

        kubectl -n microservices patch configmap mysql-failover-state \
            --type merge \
            -p '{"data":{"rejoin-required":"false"}}'

        sleep "$CHECK_INTERVAL"
        continue
    fi

    ####################################################
    # Rejoin replica
    ####################################################

    echo "[INFO] Making ${CURRENT_REPLICA} read-only..."

    mysql \
        -h "$REPLICA_HOST" \
        -uroot \
        -p"${MYSQL_ROOT_PASSWORD}" <<EOF
STOP REPLICA;

RESET REPLICA ALL;

SET GLOBAL super_read_only=ON;
SET GLOBAL read_only=ON;
EOF

    echo "[INFO] Configuring replication from ${CURRENT_PRIMARY}..."

    mysql \
        -h "$REPLICA_HOST" \
        -uroot \
        -p"${MYSQL_ROOT_PASSWORD}" <<EOF
CHANGE REPLICATION SOURCE TO
SOURCE_HOST='${PRIMARY_HOST}',
SOURCE_USER='${REPLICATION_USER}',
SOURCE_PASSWORD='${REPLICATION_PASSWORD}',
SOURCE_AUTO_POSITION=1,
GET_SOURCE_PUBLIC_KEY=1;
EOF

    echo "[INFO] Starting replication..."

    mysql \
        -h "$REPLICA_HOST" \
        -uroot \
        -p"${MYSQL_ROOT_PASSWORD}" \
        -e "START REPLICA;"

    ####################################################
    # Verify
    ####################################################

    sleep 3

    VERIFY=$(mysql \
        -h "$REPLICA_HOST" \
        -uroot \
        -p"${MYSQL_ROOT_PASSWORD}" \
        -e "SHOW REPLICA STATUS\G" 2>/dev/null || true)

    if echo "$VERIFY" | grep -q "Replica_IO_Running: Yes" \
       && echo "$VERIFY" | grep -q "Replica_SQL_Running: Yes"
    then

        echo "[SUCCESS] ${CURRENT_REPLICA} successfully rejoined."

        ################################################
        # Clear rejoin flag
        ################################################

        kubectl -n microservices patch configmap mysql-failover-state \
            --type merge \
            -p '{"data":{"rejoin-required":"false"}}'

        echo "[INFO] rejoin-required=false"

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

    else

        echo "[WARNING] Rejoin executed but replication is still unhealthy."

    fi

    sleep "$CHECK_INTERVAL"

done
