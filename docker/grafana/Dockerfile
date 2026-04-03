FROM grafana/grafana:11.5.2

ARG VICTORIALOGS_PLUGIN_VERSION=0.26.3

ENV GF_PATHS_PLUGINS=/opt/grafana-plugins

COPY docker/grafana/vendor/victoriametrics-logs-datasource.tar.gz /tmp/victorialogs-plugin.tar.gz

USER root

RUN mkdir -p "${GF_PATHS_PLUGINS}" \
    && tar -xzf /tmp/victorialogs-plugin.tar.gz -C "${GF_PATHS_PLUGINS}" \
    && chown -R grafana:root "${GF_PATHS_PLUGINS}" \
    && rm -f /tmp/victorialogs-plugin.tar.gz

USER grafana
