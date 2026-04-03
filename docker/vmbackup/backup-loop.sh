#!/bin/sh

set -eu

: "${VM_STORAGE_DATA_PATH:=/victoria-metrics-data}"
: "${VM_SNAPSHOT_URL:=http://victoria-metrics:8428/snapshot/create}"
: "${VM_BACKUP_DST:=s3://vm-backups/latest}"
: "${VM_BACKUP_INTERVAL_SECONDS:=60}"
: "${VM_BACKUP_CONCURRENCY:=4}"
: "${VM_BACKUP_S3_ENDPOINT:=http://minio:9000}"

while true; do
  started_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  echo "[${started_at}] 开始执行 VictoriaMetrics 备份 -> ${VM_BACKUP_DST}"
  if /vmbackup-prod \
    -storageDataPath="${VM_STORAGE_DATA_PATH}" \
    -snapshot.createURL="${VM_SNAPSHOT_URL}" \
    -dst="${VM_BACKUP_DST}" \
    -concurrency="${VM_BACKUP_CONCURRENCY}" \
    -customS3Endpoint="${VM_BACKUP_S3_ENDPOINT}" \
    -s3ForcePathStyle; then
    finished_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo "[${finished_at}] 备份完成"
  else
    status="$?"
    failed_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo "[${failed_at}] 备份失败，退出码: ${status}" >&2
  fi

  sleep "${VM_BACKUP_INTERVAL_SECONDS}"
done
