#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PYTHON_URL="http://localhost:8080"
readonly TS_URL="http://localhost:8081"
readonly MINIO_URL="http://localhost:9000"
readonly VM_URL="http://localhost:8428"
readonly VM_BENCHMARK_URL="http://localhost:8427"
readonly VLOGS_URL="http://localhost:9428"
readonly GRAFANA_URL="http://localhost:3000"

wait_for_http() {
  local name="$1"
  local url="$2"
  local max_attempts="${3:-60}"
  local attempt=1

  until curl -fsS "$url" >/dev/null 2>&1; do
    if [[ "$attempt" -ge "$max_attempts" ]]; then
      echo "等待 ${name} 超时: ${url}" >&2
      exit 1
    fi

    sleep 2
    attempt=$((attempt + 1))
  done
}

wait_for_query_result() {
  local name="$1"
  local url="$2"
  local max_attempts="${3:-30}"
  local attempt=1
  local response

  while true; do
    response="$(curl -fsS "$url")"

    if python3 -c '
import json
import sys

name = sys.argv[1]
payload = json.loads(sys.stdin.read())
result = payload.get("data", {}).get("result", [])
if not result:
    raise SystemExit(f"{name} 查询结果为空")
' "$name" <<<"$response" >/dev/null 2>&1; then
      return 0
    fi

    if [[ "$attempt" -ge "$max_attempts" ]]; then
      echo "${name} 查询结果为空" >&2
      echo "$response" >&2
      exit 1
    fi

    sleep 2
    attempt=$((attempt + 1))
  done
}

wait_for_query_contains_text() {
  local name="$1"
  local url="$2"
  local expected="$3"
  local max_attempts="${4:-30}"
  local attempt=1
  local response

  while true; do
    response="$(curl -fsS "$url")"
    if [[ "$response" == *"$expected"* ]]; then
      return 0
    fi

    if [[ "$attempt" -ge "$max_attempts" ]]; then
      echo "${name} 未命中预期文本: ${expected}" >&2
      echo "$response" >&2
      exit 1
    fi

    sleep 2
    attempt=$((attempt + 1))
  done
}

wait_for_backup_object() {
  local name="$1"
  local expected="$2"
  local max_attempts="${3:-30}"
  local attempt=1
  local response

  while true; do
    response="$("${SCRIPT_DIR}/list-vm-backups.sh" 2>/dev/null || true)"
    if [[ "$response" == *"$expected"* ]]; then
      return 0
    fi

    if [[ "$attempt" -ge "$max_attempts" ]]; then
      echo "${name} 未命中预期文本: ${expected}" >&2
      echo "$response" >&2
      exit 1
    fi

    sleep 2
    attempt=$((attempt + 1))
  done
}

echo "[1/7] 等待基础服务就绪"
wait_for_http "demo-python" "${PYTHON_URL}/healthz"
wait_for_http "demo-ts" "${TS_URL}/healthz"
wait_for_http "MinIO" "${MINIO_URL}/minio/health/live"
wait_for_http "VictoriaMetrics" "${VM_URL}/health"
wait_for_http "VictoriaMetrics benchmark" "${VM_BENCHMARK_URL}/health"
wait_for_http "VictoriaLogs" "${VLOGS_URL}/health"
wait_for_http "Grafana" "${GRAFANA_URL}/api/health"
wait_for_http "demo-python metrics" "${PYTHON_URL}/metrics"
wait_for_http "demo-ts metrics" "${TS_URL}/metrics"

echo "[2/7] 生成演示流量"
for i in $(seq 1 5); do
  curl -fsS "${PYTHON_URL}/work/python-${i}" >/dev/null
  curl -fsS "${TS_URL}/work/ts-${i}" >/dev/null
done

echo "[3/7] 等待采集链路写入"
sleep 6

echo "[4/7] 校验 metrics"
wait_for_query_result \
  "应用 metrics" \
  "${VM_URL}/api/v1/query?query=sum%20by%20(service)(demo_requests_total)"
wait_for_query_contains_text \
  "Python metrics" \
  "${VM_URL}/api/v1/query?query=sum%20by%20(service)(demo_requests_total)" \
  "demo-python"
wait_for_query_contains_text \
  "TS metrics" \
  "${VM_URL}/api/v1/query?query=sum%20by%20(service)(demo_requests_total)" \
  "demo-ts"
wait_for_query_result \
  "系统 metrics" \
  "${VM_URL}/api/v1/query?query=node_cpu_seconds_total%7Bjob%3D%22system-node%22%7D"
wait_for_query_result \
  "Python 进程 metrics" \
  "${VM_URL}/api/v1/query?query=process_cpu_seconds_total%7Bjob%3D%22process-python%22%7D"
wait_for_query_result \
  "TS 进程 metrics" \
  "${VM_URL}/api/v1/query?query=process_resident_memory_bytes%7Bjob%3D%22process-ts%22%7D"
wait_for_query_result \
  "remote write 带宽 metrics" \
  "${VM_URL}/api/v1/query?query=vmagent_remotewrite_bytes_sent_total%7Bjob%3D%22transport-vmagent%22%7D"
wait_for_query_result \
  "主库存储 metrics" \
  "${VM_URL}/api/v1/query?query=process_resident_memory_bytes%7Bjob%3D%22storage-primary%22%7D"

echo "[5/7] 校验 logs 与 Grafana 数据源"
wait_for_query_contains_text \
  "Python logs" \
  "${VLOGS_URL}/select/logsql/query?query=service:demo-python%20|%20limit%205" \
  "demo-python"
wait_for_query_contains_text \
  "TS logs" \
  "${VLOGS_URL}/select/logsql/query?query=service:demo-ts%20|%20limit%205" \
  "demo-ts"
wait_for_query_contains_text \
  "Grafana VictoriaMetrics 数据源" \
  "http://admin:admin@localhost:3000/api/datasources/name/VictoriaMetrics" \
  "VictoriaMetrics"
wait_for_query_contains_text \
  "Grafana VictoriaLogs 数据源" \
  "http://admin:admin@localhost:3000/api/datasources/name/VictoriaLogs" \
  "VictoriaLogs"

echo "[6/7] 校验 MinIO 自动备份"
wait_for_backup_object \
  "MinIO 备份对象" \
  "latest/"

echo "[7/7] 校验 Grafana dashboard"
wait_for_query_contains_text \
  "Grafana cross-region dashboard" \
  "http://admin:admin@localhost:3000/api/dashboards/uid/cross-region-transport" \
  "\"uid\":\"cross-region-transport\""

echo "验证通过：高频 process metrics、低频 remote write、logs、Grafana dashboard、MinIO 自动备份 全部可用"
