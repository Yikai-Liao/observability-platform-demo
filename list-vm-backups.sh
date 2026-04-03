#!/usr/bin/env bash

set -euo pipefail

readonly script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly backup_prefix="${1:-}"
readonly minio_endpoint="http://minio:9000"
readonly minio_root_user="minioadmin"
readonly minio_root_password="minioadmin"
readonly minio_backup_bucket="vm-backups"

if [[ -n "${backup_prefix}" ]]; then
  target_path="local/${minio_backup_bucket}/${backup_prefix}"
else
  target_path="local/${minio_backup_bucket}"
fi

cd "${script_dir}"

minio_container_id="$(docker compose ps -q minio)"
if [[ -z "${minio_container_id}" ]]; then
  echo "minio 服务未运行" >&2
  exit 1
fi

minio_network_name="$(docker inspect "${minio_container_id}" --format '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}' | head -n 1)"
if [[ -z "${minio_network_name}" ]]; then
  echo "无法解析 minio 所在网络" >&2
  exit 1
fi

docker run --rm \
  --network "${minio_network_name}" \
  -e MINIO_ENDPOINT="${minio_endpoint}" \
  -e MINIO_ROOT_USER="${minio_root_user}" \
  -e MINIO_ROOT_PASSWORD="${minio_root_password}" \
  -e TARGET_PATH="${target_path}" \
  --entrypoint sh \
  minio/mc:latest \
  -lc 'mc alias set local "${MINIO_ENDPOINT}" "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}" >/dev/null && mc ls --recursive "${TARGET_PATH}"'
