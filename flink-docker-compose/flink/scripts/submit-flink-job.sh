#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Wait for the Flink JobManager to be reachable, then submit the CDC->Iceberg
# SQL job. Runs as a one-shot container (`flink-job-submitter`) that exits 0
# once the job is accepted; the job itself keeps running on the cluster.
# ---------------------------------------------------------------------------
set -euo pipefail

JM_HOST="${JOBMANAGER_HOST:-jobmanager}"
JM_PORT="${JOBMANAGER_PORT:-8081}"
SQL_FILE="${SQL_FILE:-/opt/sql/cdc-to-iceberg.sql}"

echo "[submit] waiting for Flink JobManager at ${JM_HOST}:${JM_PORT} ..."
for i in $(seq 1 60); do
    # /overview returns cluster status once the JobManager REST API is up and
    # at least the JobManager itself is registered.
    if curl -sf "http://${JM_HOST}:${JM_PORT}/overview" >/dev/null 2>&1; then
        echo "[submit] JobManager is up."
        break
    fi
    if [ "$i" -eq 60 ]; then
        echo "[submit] ERROR: JobManager never became ready." >&2
        exit 1
    fi
    sleep 2
done

# Make sure at least one TaskManager slot exists, otherwise the job would be
# submitted but sit in SCHEDULED forever.
echo "[submit] waiting for a registered TaskManager ..."
for i in $(seq 1 60); do
    slots=$(curl -sf "http://${JM_HOST}:${JM_PORT}/overview" 2>/dev/null | grep -o '"slots-total":[0-9]*' | grep -o '[0-9]*' || echo 0)
    if [ "${slots:-0}" -gt 0 ]; then
        echo "[submit] ${slots} task slot(s) available."
        break
    fi
    if [ "$i" -eq 60 ]; then
        echo "[submit] ERROR: no TaskManager slots became available." >&2
        exit 1
    fi
    sleep 2
done

echo "[submit] submitting SQL job from ${SQL_FILE} ..."
# sql-client runs in embedded mode and submits to the cluster addressed by
# rest.address/rest.port (set here so it targets the remote JobManager).
"${FLINK_HOME}/bin/sql-client.sh" \
    -Drest.address="${JM_HOST}" \
    -Drest.port="${JM_PORT}" \
    -f "${SQL_FILE}"

echo "[submit] job submitted. The CDC stream is now running on the cluster."
