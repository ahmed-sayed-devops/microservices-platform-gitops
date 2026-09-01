#!/usr/bin/env bash

set -euo pipefail

STATE_FILE="/state/current-primary"

CONFIGMAP_NAME="mysql-router-config"
NAMESPACE="microservices"

MYSQL_PRIMARY_SERVICE="mysql-primary"
MYSQL_REPLICA_SERVICE="mysql-replica"

CURRENT_PRIMARY=$(cat "$STATE_FILE")

if [ "$CURRENT_PRIMARY" = "$MYSQL_PRIMARY_SERVICE" ]; then
    CURRENT_REPLICA="$MYSQL_REPLICA_SERVICE"
else
    CURRENT_REPLICA="$MYSQL_PRIMARY_SERVICE"
fi

PRIMARY_HOST="${CURRENT_PRIMARY}-0.${CURRENT_PRIMARY}.${NAMESPACE}.svc.cluster.local"
REPLICA_HOST="${CURRENT_REPLICA}-0.${CURRENT_REPLICA}.${NAMESPACE}.svc.cluster.local"

echo "========================================"
echo "Generating HAProxy Configuration"
echo "========================================"

echo "[INFO] Current primary: $CURRENT_PRIMARY"
echo "[INFO] Current replica: $CURRENT_REPLICA"

cat > /tmp/haproxy.cfg <<EOF
global
    log stdout format raw local0

defaults
    log global
    mode tcp
    option tcplog

    timeout connect 5s
    timeout client 1m
    timeout server 1m

frontend mysql
    bind *:3306
    default_backend mysql_primary

backend mysql_primary
    option tcp-check

    server primary ${PRIMARY_HOST}:3306 check inter 2s fall 2 rise 2

    server replica ${REPLICA_HOST}:3306 check backup inter 2s fall 2 rise 2

listen stats
    bind *:8404
    mode http

    stats enable
    stats uri /stats
    stats refresh 10s

    http-request use-service prometheus-exporter if { path /metrics }
EOF

# Make absolutely sure the file ends with LF
printf '\n' >> /tmp/haproxy.cfg

echo "[INFO] Applying HAProxy ConfigMap..."

kubectl -n "$NAMESPACE" create configmap "$CONFIGMAP_NAME" \
    --from-file=haproxy.cfg=/tmp/haproxy.cfg \
    --dry-run=client \
    -o yaml | kubectl apply -f -

echo "[SUCCESS] HAProxy configuration updated."

echo "========================================"
cat /tmp/haproxy.cfg
echo "========================================"
