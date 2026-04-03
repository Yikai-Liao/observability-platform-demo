#!/usr/bin/env bash

set -euo pipefail

readonly VM_URL="${VM_URL:-http://localhost:8428}"
readonly SAMPLE_WINDOW_SECONDS="${1:-30}"

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

prom_query_scalar() {
  local expr="$1"
  local response

  response="$(curl -fsS -G --data-urlencode "query=${expr}" "${VM_URL}/api/v1/query")"

  python3 - "$expr" "$response" <<'PY'
import json
import sys

expr = sys.argv[1]
payload = json.loads(sys.argv[2])
result = payload.get("data", {}).get("result", [])

if not result:
    raise SystemExit(f"查询结果为空: {expr}")

value = result[0].get("value")
if not value or len(value) < 2:
    raise SystemExit(f"无法解析查询结果: {expr}")

print(value[1])
PY
}

wait_for_http "VictoriaMetrics 主库" "${VM_URL}/health"

vm_bandwidth_bps="$(prom_query_scalar "sum(rate(vmagent_remotewrite_bytes_sent_total{job=\"transport-vmagent\",url=\"1:secret-url\"}[${SAMPLE_WINDOW_SECONDS}s]))")"
prom_bandwidth_bps="$(prom_query_scalar "sum(rate(vmagent_remotewrite_bytes_sent_total{job=\"transport-vmagent\",url=\"2:secret-url\"}[${SAMPLE_WINDOW_SECONDS}s]))")"
vm_rows_per_second="$(prom_query_scalar "sum(rate(vmagent_remotewrite_rows_pushed_after_relabel_total{job=\"transport-vmagent\",url=\"1:secret-url\"}[${SAMPLE_WINDOW_SECONDS}s]))")"
storage_cpu_ratio="$(prom_query_scalar "100 * sum(rate(process_cpu_seconds_total{job=\"storage-primary\"}[${SAMPLE_WINDOW_SECONDS}s])) / max(process_cpu_cores_available{job=\"storage-primary\"})")"
storage_rss_bytes="$(prom_query_scalar "max(process_resident_memory_bytes{job=\"storage-primary\"})")"
storage_data_bytes="$(prom_query_scalar "sum(vm_data_size_bytes{job=\"storage-primary\"})")"
storage_rows_total="$(prom_query_scalar "sum(vm_rows_added_to_storage_total{job=\"storage-primary\"})")"
storage_zstd_ratio="$(prom_query_scalar "sum(vm_zstd_block_original_bytes_total{job=\"storage-primary\"}) / sum(vm_zstd_block_compressed_bytes_total{job=\"storage-primary\"})")"

container_id="$(docker compose ps -q victoria-metrics)"
if [[ -z "${container_id}" ]]; then
  echo "无法找到 victoria-metrics 容器" >&2
  exit 1
fi

storage_volume_name="$(docker inspect "${container_id}" --format '{{range .Mounts}}{{if eq .Destination "/victoria-metrics-data"}}{{.Name}}{{end}}{{end}}')"
if [[ -z "${storage_volume_name}" ]]; then
  echo "无法找到 victoria-metrics 数据卷名称" >&2
  exit 1
fi

storage_disk_bytes="$(
  docker run --rm -v "${storage_volume_name}:/data:ro" busybox:1.36.1 sh -c 'du -sb /data | awk "{print \$1}"'
)"

python3 - "${SAMPLE_WINDOW_SECONDS}" \
  "${vm_bandwidth_bps}" \
  "${prom_bandwidth_bps}" \
  "${vm_rows_per_second}" \
  "${storage_cpu_ratio}" \
  "${storage_rss_bytes}" \
  "${storage_data_bytes}" \
  "${storage_rows_total}" \
  "${storage_zstd_ratio}" \
  "${storage_disk_bytes}" <<'PY'
import sys

window = int(float(sys.argv[1]))
vm_bandwidth = float(sys.argv[2])
prom_bandwidth = float(sys.argv[3])
rows_per_second = float(sys.argv[4])
cpu_ratio = float(sys.argv[5])
rss_bytes = float(sys.argv[6])
data_bytes = float(sys.argv[7])
rows_total = float(sys.argv[8])
zstd_ratio = float(sys.argv[9])
disk_bytes = float(sys.argv[10])


def human_bytes(value: float) -> str:
    units = ["B", "KiB", "MiB", "GiB", "TiB"]
    size = float(value)
    for unit in units:
        if size < 1024 or unit == units[-1]:
            return f"{size:.2f} {unit}"
        size /= 1024
    return f"{size:.2f} TiB"


vm_to_prom_ratio = prom_bandwidth / vm_bandwidth if vm_bandwidth > 0 else 0.0
bandwidth_saving = (1 - vm_bandwidth / prom_bandwidth) * 100 if prom_bandwidth > 0 else 0.0
vm_bytes_per_sample = vm_bandwidth / rows_per_second if rows_per_second > 0 else 0.0
prom_bytes_per_sample = prom_bandwidth / rows_per_second if rows_per_second > 0 else 0.0
storage_bytes_per_row = data_bytes / rows_total if rows_total > 0 else 0.0

print(f"跨区域传输观测报告（采样窗口 {window}s）")
print()
print("传输层")
print(f"- VM 协议 remote write 带宽: {human_bytes(vm_bandwidth)}/s ({vm_bandwidth * 8 / 1024 / 1024:.3f} Mib/s)")
print(f"- Prom 对照 remote write 带宽: {human_bytes(prom_bandwidth)}/s ({prom_bandwidth * 8 / 1024 / 1024:.3f} Mib/s)")
print(f"- 高频样本写入速率: {rows_per_second:.2f} rows/s")
print(f"- VM 协议平均每样本网络开销: {vm_bytes_per_sample:.2f} B/sample")
print(f"- Prom 对照平均每样本网络开销: {prom_bytes_per_sample:.2f} B/sample")
print(f"- VM 相对 Prom 的传输压缩倍率: {vm_to_prom_ratio:.2f}x")
print(f"- VM 相对 Prom 的带宽节省: {bandwidth_saving:.2f}%")
print()
print("存储层")
print(f"- VictoriaMetrics CPU 占用: {cpu_ratio:.2f}%")
print(f"- VictoriaMetrics RSS 内存: {human_bytes(rss_bytes)}")
print(f"- TSDB 逻辑数据体积: {human_bytes(data_bytes)}")
print(f"- TSDB 数据目录实际占用: {human_bytes(disk_bytes)}")
print(f"- TSDB 已写入样本总数: {rows_total:.0f}")
print(f"- TSDB 平均每样本占用: {storage_bytes_per_row:.4f} B/sample")
print(f"- VictoriaMetrics 内部块压缩率: {zstd_ratio:.2f}x")
PY
