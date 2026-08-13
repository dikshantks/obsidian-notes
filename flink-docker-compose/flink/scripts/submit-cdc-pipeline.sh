#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Wait for the Flink JobManager, then submit the MySQL→Iceberg CDC pipeline
# using the Flink CDC 3.x Pipeline framework.  Runs as a one-shot container
# (flink-cdc-pipeline-submitter) that exits 0 once the job is accepted.
#
# flink-cdc.sh reads cluster connection details from FLINK_HOME/conf/config.yaml.
# The FLINK_PROPERTIES env var (set in docker-compose.yml) is processed by the
# Flink Docker entrypoint before this script runs, so rest.address/rest.port
# are already written to config.yaml when we reach the submission step.
# ---------------------------------------------------------------------------
set -euo pipefail

JM_HOST="${JOBMANAGER_HOST:-jobmanager}"
JM_PORT="${JOBMANAGER_PORT:-8081}"
PIPELINE_FILE="${PIPELINE_FILE:-/opt/pipeline/mysql-to-iceberg.yaml}"

echo "[pipeline-submitter] waiting for Flink JobManager at ${JM_HOST}:${JM_PORT} ..."
for i in $(seq 1 60); do
    if curl -sf "http://${JM_HOST}:${JM_PORT}/overview" >/dev/null 2>&1; then
        echo "[pipeline-submitter] JobManager is up."
        break
    fi
    if [ "$i" -eq 60 ]; then
        echo "[pipeline-submitter] ERROR: JobManager never became ready." >&2
        exit 1
    fi
    sleep 2
done

echo "[pipeline-submitter] waiting for a registered TaskManager ..."
for i in $(seq 1 60); do
    slots=$(curl -sf "http://${JM_HOST}:${JM_PORT}/overview" 2>/dev/null \
        | grep -o '"slots-total":[0-9]*' | grep -o '[0-9]*' || echo 0)
    if [ "${slots:-0}" -gt 0 ]; then
        echo "[pipeline-submitter] ${slots} task slot(s) available."
        break
    fi
    if [ "$i" -eq 60 ]; then
        echo "[pipeline-submitter] ERROR: no TaskManager slots became available." >&2
        exit 1
    fi
    sleep 2
done

echo "[pipeline-submitter] submitting CDC pipeline from ${PIPELINE_FILE} ..."

# flink-cdc.sh sets FLINK_CDC_HOME from its own location, builds the classpath
# from FLINK_CDC_HOME/lib/*, then invokes CliFrontend. CliFrontend uses
# FLINK_HOME to locate config.yaml (written by the entrypoint from
# FLINK_PROPERTIES), which tells it where the remote cluster is.
export FLINK_HOME="${FLINK_HOME:-/opt/flink}"
/opt/flink-cdc/bin/flink-cdc.sh "${PIPELINE_FILE}"

echo "[pipeline-submitter] CDC pipeline submitted. Schema evolution is now active."
