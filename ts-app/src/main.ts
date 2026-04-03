import { metrics } from "@opentelemetry/api";
import { OTLPMetricExporter } from "@opentelemetry/exporter-metrics-otlp-http";
import { MeterProvider, PeriodicExportingMetricReader } from "@opentelemetry/sdk-metrics";
import { Counter, Gauge, Registry, collectDefaultMetrics } from "prom-client";
import { createWriteStream, mkdirSync } from "node:fs";
import { createServer, ServerResponse } from "node:http";
import { dirname } from "node:path";
import { URL } from "node:url";

const SERVICE_NAME = process.env.OTEL_SERVICE_NAME ?? "demo-ts";
const OTLP_ENDPOINT =
  process.env.OTEL_EXPORTER_OTLP_ENDPOINT ?? "http://otel-collector:4318/v1/metrics";
const LOG_FILE = process.env.DEMO_LOG_FILE ?? "/var/log/demo/demo-ts.log";
const PORT = 8080;

mkdirSync(dirname(LOG_FILE), { recursive: true });

const logStream = createWriteStream(LOG_FILE, { flags: "a" });

const exporter = new OTLPMetricExporter({ url: OTLP_ENDPOINT });
const reader = new PeriodicExportingMetricReader({
  exporter,
  exportIntervalMillis: 5000,
});
const meterProvider = new MeterProvider({ readers: [reader] });

metrics.setGlobalMeterProvider(meterProvider);

const meter = metrics.getMeter(SERVICE_NAME);
const requestCounter = meter.createCounter("demo_requests_total", {
  description: "Total work requests handled by the demo service",
});
const latencyHistogram = meter.createHistogram("demo_request_latency_ms", {
  description: "Request latency in milliseconds",
  unit: "ms",
});
const promRegistry = new Registry();

collectDefaultMetrics({ register: promRegistry });

const processRequestCounter = new Counter({
  name: "demo_process_requests_total",
  help: "Total requests observed by the process metrics endpoint",
  registers: [promRegistry],
});
const processLatencyGauge = new Gauge({
  name: "demo_process_last_request_latency_ms",
  help: "Latency for the latest request handled by the process",
  registers: [promRegistry],
});

function writeJson(
  response: ServerResponse,
  statusCode: number,
  payload: Record<string, number | string | boolean>,
): void {
  const body = JSON.stringify(payload);
  response.writeHead(statusCode, {
    "Content-Type": "application/json",
    "Content-Length": Buffer.byteLength(body),
  });
  response.end(body);
}

function logEvent(
  level: "INFO" | "WARN",
  message: string,
  fields: Record<string, number | string>,
): void {
  const entry = JSON.stringify({
    ts: new Date().toISOString(),
    level,
    service: SERVICE_NAME,
    message,
    ...fields,
  });

  process.stdout.write(`${entry}\n`);
  logStream.write(`${entry}\n`);
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
}

const server = createServer(async (request, response) => {
  const method = request.method ?? "GET";
  const url = new URL(request.url ?? "/", "http://localhost");

  if (method !== "GET") {
    writeJson(response, 405, { ok: false, service: SERVICE_NAME, path: url.pathname });
    return;
  }

  if (url.pathname === "/healthz") {
    writeJson(response, 200, { ok: true, service: SERVICE_NAME });
    return;
  }

  if (url.pathname === "/metrics") {
    const body = await promRegistry.metrics();
    response.writeHead(200, {
      "Content-Type": promRegistry.contentType,
      "Content-Length": Buffer.byteLength(body),
    });
    response.end(body);
    return;
  }

  if (!url.pathname.startsWith("/work/")) {
    logEvent("WARN", "route not found", { path: url.pathname, method });
    writeJson(response, 404, { ok: false, service: SERVICE_NAME, path: url.pathname });
    return;
  }

  const started = Date.now();
  const requestId = url.pathname.slice("/work/".length) || "default";
  const latencyMs = Math.floor(Math.random() * 231) + 20;

  await sleep(latencyMs);

  const metricAttributes = {
    service: SERVICE_NAME,
    path: "/work/:id",
    method,
  };

  requestCounter.add(1, metricAttributes);
  latencyHistogram.record(latencyMs, metricAttributes);
  processRequestCounter.inc();
  processLatencyGauge.set(latencyMs);
  logEvent("INFO", "request handled", {
    path: url.pathname,
    method,
    latency_ms: latencyMs,
  });

  writeJson(response, 200, {
    ok: true,
    service: SERVICE_NAME,
    path: url.pathname,
    request_id: requestId,
    latency_ms: latencyMs,
    elapsed_ms: Date.now() - started,
  });
});

logEvent("INFO", "service starting", { port: PORT, otlp_endpoint: OTLP_ENDPOINT, log_file: LOG_FILE });

server.listen(PORT, "0.0.0.0");

function shutdown(): void {
  logStream.end();
  server.close(() => {
    process.exit(0);
  });
}

process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
