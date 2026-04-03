#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUTPUT_DIR="${SCRIPT_DIR}/vendor"
OUTPUT_FILE="${OUTPUT_DIR}/victoriametrics-logs-datasource.tar.gz"
PLUGIN_VERSION="${1:-${VICTORIALOGS_PLUGIN_VERSION:-0.26.3}}"
PLUGIN_URL="https://github.com/VictoriaMetrics/victorialogs-datasource/releases/download/v${PLUGIN_VERSION}/victoriametrics-logs-datasource-v${PLUGIN_VERSION}.tar.gz"

read_docker_proxy() {
    key="$1"
    docker system info 2>/dev/null | sed -n "s/^ ${key}: //p" | head -n 1
}

if [ -z "${HTTP_PROXY:-}" ]; then
    docker_http_proxy=$(read_docker_proxy "HTTP Proxy")
    if [ -n "${docker_http_proxy}" ]; then
        export HTTP_PROXY="${docker_http_proxy}"
        export http_proxy="${docker_http_proxy}"
    fi
fi

if [ -z "${HTTPS_PROXY:-}" ]; then
    docker_https_proxy=$(read_docker_proxy "HTTPS Proxy")
    if [ -n "${docker_https_proxy}" ]; then
        export HTTPS_PROXY="${docker_https_proxy}"
        export https_proxy="${docker_https_proxy}"
    fi
fi

if [ -z "${NO_PROXY:-}" ]; then
    docker_no_proxy=$(read_docker_proxy "No Proxy")
    if [ -n "${docker_no_proxy}" ]; then
        export NO_PROXY="${docker_no_proxy}"
        export no_proxy="${docker_no_proxy}"
    fi
fi

mkdir -p "${OUTPUT_DIR}"
tmp_file="${OUTPUT_FILE}.tmp"
rm -f "${tmp_file}"

echo "Downloading VictoriaLogs Grafana plugin v${PLUGIN_VERSION}"
echo "Source: ${PLUGIN_URL}"
echo "Target: ${OUTPUT_FILE}"

if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --connect-timeout 15 -o "${tmp_file}" "${PLUGIN_URL}"
elif command -v wget >/dev/null 2>&1; then
    wget -O "${tmp_file}" "${PLUGIN_URL}"
else
    echo "Neither curl nor wget is available" >&2
    exit 1
fi

tar -tzf "${tmp_file}" | grep -Eq '^(\./)?victoriametrics-logs-datasource/plugin.json$'
mv "${tmp_file}" "${OUTPUT_FILE}"

echo "Plugin archive is ready at ${OUTPUT_FILE}"
echo "Next:"
echo "  docker compose build --no-cache grafana"
echo "  docker compose up -d --force-recreate grafana"
