# observability-platform-demo

一个基于 `docker compose` 的可观测性演示仓库，用最小可运行栈验证三类能力：

- 应用层主动埋点：`Java / Python / TS` 风格应用通过 `OTel SDK -> OTel Collector -> vmagent -> VictoriaMetrics`
- 平台与系统指标采集：`node_exporter` 等被动采集指标通过 `vmagent -> VictoriaMetrics`
- 日志采集与查询：应用文件日志通过 `Vector -> VictoriaLogs -> Grafana`

同时，这个 demo 还模拟了一个跨区域传输场景：

- 系统级指标按 `1Hz` 抓取
- 进程级指标按 `10Hz` 抓取
- `vmagent` 不做聚合，按 `2s` flush 一次
- 主链路强制使用 `VictoriaMetrics remote write` 协议
- 旁路保留一条 `Prometheus remote write` 对照链路，用于估算带宽占用与协议压缩收益

这个仓库适合做三件事：

- 演示一套最小可用的 `metrics + logs + dashboard` 方案
- 验证 `vmagent -> VictoriaMetrics` 直写是否能满足跨区域汇聚场景
- 量化 `VM remote write` 相对 `Prom remote write` 的带宽与压缩差异

## 快速开始

前置要求：

- 已安装 Docker 与 Docker Compose
- 本机可以访问镜像源
- 如果访问 GitHub 需要代理，宿主机已配置可用代理

启动：

```bash
cd /home/lyk/code/observability-platform-demo
./docker/grafana/download-victorialogs-plugin.sh
docker compose up -d --build --force-recreate --remove-orphans
docker compose ps
```

验证：

```bash
./verify.sh
./report-cross-region.sh
```

停止：

```bash
docker compose down
```

## 演示链路

- 应用业务 metrics：`demo-python + demo-ts -> OTel Collector -> vmagent -> VictoriaMetrics`
- 高频进程 metrics：`demo-python:/metrics + demo-ts:/metrics -> vmagent(10Hz) -> VictoriaMetrics`
- 低频系统 metrics：`node-exporter -> vmagent(1Hz) -> VictoriaMetrics`
- 传输对照：`vmagent -> VictoriaMetrics(primary, VM 协议)` 与 `vmagent -> VictoriaMetrics benchmark(Prom 协议)`
- logs：`demo-python.log + demo-ts.log -> Vector -> VictoriaLogs`
- 展示：`Grafana -> VictoriaMetrics + VictoriaLogs`

接收侧没有再加一个 `vmagent`。这个 demo 直接把 `vmagent` 写入 `VictoriaMetrics`，更符合“源端汇聚，目标端直接入库”的最小实现。

## 组件说明

- `demo-python`：Python HTTP 服务，主动上报 OTel 业务指标，同时暴露 `/metrics` 进程指标，并输出 JSON Lines 文件日志。
- `demo-ts`：TypeScript/Node HTTP 服务，主动上报 OTel 业务指标，同时暴露 `/metrics` 进程指标，并输出 JSON Lines 文件日志。
- `otel-collector`：只接 OTLP metrics，不接 logs。
- `node-exporter`：提供主机级 CPU、内存等系统指标。
- `vmagent`：统一抓取 OTel、系统、进程、自监控与主库自监控；`2s` flush；主链路强制 `VM remote write`，旁路对照强制 `Prom remote write`。
- `victoria-metrics`：主库存储，用于展示最终 TSDB 资源占用与压缩率。
- `victoria-metrics-benchmark`：只用于传输协议对照，不接入 Grafana。
- `vector`：读取共享 volume 中的双应用日志文件，做 JSON 解析和过滤后写入 `VictoriaLogs`。
- `grafana`：预置数据源和 `Cross-Region Transport & Storage` dashboard。

## 仓库结构

```text
.
├── app/                         # Python demo 应用
├── ts-app/                      # TypeScript demo 应用
├── config/
│   ├── otel-collector/          # OTel Collector 配置
│   ├── vector/                  # Vector 日志采集配置
│   └── vmagent/                 # vmagent 抓取与 remote write 配置
├── docker/
│   ├── demo-app/                # Python 应用镜像
│   ├── demo-ts/                 # TS 应用镜像
│   └── grafana/                 # Grafana 自定义镜像与插件下载脚本
├── docker-compose.yml           # 整体编排
├── verify.sh                    # 基础链路验收脚本
└── report-cross-region.sh       # 跨区域传输与存储报告脚本
```

## 代理处理

构建时优先使用镜像源，代理只作为兜底：

- 应用镜像构建阶段显式暴露 `ARG HTTP_PROXY / HTTPS_PROXY / ALL_PROXY / NO_PROXY`
- 同时传递大小写代理变量
- `apt` 使用清华 Debian 镜像
- `pip` 使用清华 PyPI 镜像
- `npm` 使用 `npmmirror` 镜像

需要代理时：

```bash
cd /home/lyk/code/observability-platform-demo
cp .env.example .env
```

然后按需填写代理地址；如果镜像源可直连，可以不配置代理。

Grafana 的 `VictoriaLogs` 插件不在 `docker build` 阶段联网下载，而是先在宿主机下载到仓库内固定路径，再由镜像通过 `COPY` 带入。这样可以避开 Docker build 阶段代理不透传的问题。

先准备 Grafana 插件包：

```bash
cd /home/lyk/code/observability-platform-demo
./docker/grafana/download-victorialogs-plugin.sh
```

这个脚本会优先使用当前 shell 的代理环境变量；如果 shell 没有设置代理，会回退读取 `docker system info` 里的 `HTTP Proxy / HTTPS Proxy / No Proxy`。

只重建 Grafana：

```bash
cd /home/lyk/code/observability-platform-demo
./docker/grafana/download-victorialogs-plugin.sh
docker compose build --no-cache grafana
docker compose up -d --force-recreate grafana
```

一键验收：

```bash
./verify.sh
```

输出跨区域传输与存储报告：

```bash
./report-cross-region.sh
```

也可以指定报告采样窗口，例如 `60s`：

```bash
./report-cross-region.sh 60
```

## 访问入口

- Demo Python: `http://localhost:8080`
- Demo TS: `http://localhost:8081`
- Grafana: `http://localhost:3000`
- VictoriaMetrics 主库: `http://localhost:8428`
- VictoriaMetrics benchmark: `http://localhost:8427`
- VictoriaLogs: `http://localhost:9428`

Grafana 默认账号密码：

- 用户名：`admin`
- 密码：`admin`

Grafana 预置 dashboard：

- `Cross-Region Transport & Storage`

## 这个 demo 能展示什么

`report-cross-region.sh` 会直接输出：

- VM 协议 remote write 的实际带宽占用
- Prom 对照链路的实际带宽占用
- 两者对同一批样本的传输压缩倍率和带宽节省比例
- 主库 VictoriaMetrics 的 CPU、RSS 内存、逻辑数据体积、实际磁盘占用
- 主库内部块压缩率
- 主库平均每样本占用

其中：

- 传输带宽来自 `vmagent_remotewrite_bytes_sent_total`
- 高频样本速率来自 `vmagent_remotewrite_rows_pushed_after_relabel_total`
- 主库资源来自 `process_*` 与 `vm_data_size_bytes`
- 存储压缩率来自 `vm_zstd_block_original_bytes_total / vm_zstd_block_compressed_bytes_total`

说明：

- 这里的“带宽节省”是基于 demo 内同一批样本、两条 remote write 链路自监控指标做的估算
- 它适合做相对对比，不应被理解为生产环境中的精确账单值
- 最终存储压缩率看的是 VictoriaMetrics 入库后的块压缩结果，与传输协议压缩率不是同一个指标

## 手工验证

应用业务指标：

```bash
curl -s "http://localhost:8428/api/v1/query?query=sum%20by%20(service)(demo_requests_total)"
```

系统与进程指标：

```bash
curl -s "http://localhost:8428/api/v1/query?query=process_cpu_seconds_total%7Bjob%3D%22process-python%22%7D"
curl -s "http://localhost:8428/api/v1/query?query=node_memory_MemAvailable_bytes%7Bjob%3D%22system-node%22%7D"
```

remote write 带宽：

```bash
curl -s "http://localhost:8428/api/v1/query?query=sum(rate(vmagent_remotewrite_bytes_sent_total%7Bjob%3D%22transport-vmagent%22,url%3D%221:secret-url%22%7D%5B30s%5D))"
curl -s "http://localhost:8428/api/v1/query?query=sum(rate(vmagent_remotewrite_bytes_sent_total%7Bjob%3D%22transport-vmagent%22,url%3D%222:secret-url%22%7D%5B30s%5D))"
```

logs：

```bash
curl -s "http://localhost:9428/select/logsql/query?query=service:demo-python%20|%20limit%205"
curl -s "http://localhost:9428/select/logsql/query?query=service:demo-ts%20|%20limit%205"
```

Grafana：

```bash
curl -s -u admin:admin "http://localhost:3000/api/datasources/name/VictoriaMetrics"
curl -s -u admin:admin "http://localhost:3000/api/datasources/name/VictoriaLogs"
curl -s -u admin:admin "http://localhost:3000/api/dashboards/uid/cross-region-transport"
```

如果 Grafana 里看不到日志，优先检查：

- 是否执行过 `./docker/grafana/download-victorialogs-plugin.sh`
- 是否重新构建过 `grafana` 镜像
- `curl -u admin:admin http://localhost:3000/api/plugins | jq '.[] | select(.id=="victoriametrics-logs-datasource")'` 是否有结果

## 取舍

- 保留现有 OTel + Vector 基础链路，不把进程级高频采集混到 OTel 里。
- 高频进程指标直接由 `vmagent` 抓取应用 `/metrics`，避免额外引入接收侧 `vmagent`。
- 为了可量化展示 VM 协议带宽收益，额外保留一条 Prom 协议 benchmark 落点；主链路仍然只使用 VM 协议。
- 只做 `1Hz` 系统指标和 `10Hz` 进程指标两档频率，不扩展更多频率层级。
