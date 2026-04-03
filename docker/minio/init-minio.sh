#!/bin/sh

set -eu

: "${MINIO_ENDPOINT:=http://minio:9000}"
: "${MINIO_ROOT_USER:=minioadmin}"
: "${MINIO_ROOT_PASSWORD:=minioadmin}"
: "${MINIO_REGION:=us-east-1}"
: "${MINIO_BACKUP_BUCKET:=vm-backups}"

echo "等待 MinIO 就绪: ${MINIO_ENDPOINT}"
until mc alias set local "${MINIO_ENDPOINT}" "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}" >/dev/null 2>&1; do
  sleep 2
done

mc mb --ignore-existing --with-versioning --region "${MINIO_REGION}" "local/${MINIO_BACKUP_BUCKET}"

echo "MinIO bucket 已就绪: ${MINIO_BACKUP_BUCKET}"
