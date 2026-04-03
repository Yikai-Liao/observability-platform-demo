import json
import logging
import os
import random
import sys
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer

from opentelemetry import metrics
from opentelemetry.exporter.otlp.proto.http.metric_exporter import OTLPMetricExporter
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.sdk.resources import Resource
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Gauge, REGISTRY, generate_latest

SERVICE_NAME = os.getenv("OTEL_SERVICE_NAME", "demo-python")
OTLP_ENDPOINT = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://otel-collector:4318/v1/metrics")
LOG_FILE = os.getenv("DEMO_LOG_FILE", "/var/log/demo/demo-python.log")

os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)

class JsonFormatter(logging.Formatter):
    def format(self, record):
        payload = {
            "ts": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            "level": record.levelname,
            "service": SERVICE_NAME,
            "message": record.getMessage(),
        }

        for field in ("path", "method", "latency_ms"):
            value = getattr(record, field, None)
            if value is not None:
                payload[field] = value

        return json.dumps(payload, ensure_ascii=False)


logger = logging.getLogger(SERVICE_NAME)
logger.setLevel(logging.INFO)
logger.handlers.clear()

formatter = JsonFormatter()

stdout_handler = logging.StreamHandler(sys.stdout)
stdout_handler.setFormatter(formatter)
logger.addHandler(stdout_handler)

file_handler = logging.FileHandler(LOG_FILE)
file_handler.setFormatter(formatter)
logger.addHandler(file_handler)

resource = Resource.create({"service.name": SERVICE_NAME})
exporter = OTLPMetricExporter(endpoint=OTLP_ENDPOINT)
reader = PeriodicExportingMetricReader(exporter, export_interval_millis=5000)
provider = MeterProvider(resource=resource, metric_readers=[reader])
metrics.set_meter_provider(provider)
meter = metrics.get_meter(SERVICE_NAME)

request_counter = meter.create_counter(
    name="demo_requests_total",
    description="Total work requests handled by the demo service",
)
latency_hist = meter.create_histogram(
    name="demo_request_latency_ms",
    description="Request latency in milliseconds",
    unit="ms",
)
process_request_counter = Counter(
    "demo_process_requests_total",
    "Total requests observed by the process metrics endpoint",
)
process_latency_gauge = Gauge(
    "demo_process_last_request_latency_ms",
    "Latency for the latest request handled by the process",
)


class Handler(BaseHTTPRequestHandler):
    def respond_json(self, status_code, payload, headers=None):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/healthz":
            self.respond_json(200, {"ok": True, "service": SERVICE_NAME})
            return

        if self.path == "/metrics":
            body = generate_latest(REGISTRY)
            self.send_response(200)
            self.send_header("Content-Type", CONTENT_TYPE_LATEST)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if not self.path.startswith("/work/"):
            logger.warning("route not found", extra={"path": self.path, "method": "GET"})
            self.respond_json(404, {"ok": False, "service": SERVICE_NAME, "path": self.path})
            return

        started = time.time()
        latency_ms = random.randint(20, 250)
        time.sleep(latency_ms / 1000)

        metric_attrs = {"service": SERVICE_NAME, "path": "/work/:id", "method": "GET"}
        request_counter.add(1, metric_attrs)
        latency_hist.record(latency_ms, metric_attrs)
        process_request_counter.inc()
        process_latency_gauge.set(latency_ms)

        logger.info(
            "request handled",
            extra={"path": self.path, "method": "GET", "latency_ms": latency_ms},
        )

        request_id = self.path.removeprefix("/work/") or "default"
        self.respond_json(
            200,
            {
                "ok": True,
                "service": SERVICE_NAME,
                "path": self.path,
                "request_id": request_id,
                "latency_ms": latency_ms,
                "elapsed_ms": int((time.time() - started) * 1000),
            }
        )

    def log_message(self, format, *args):
        return


if __name__ == "__main__":
    port = 8080
    logger.info("demo-python starting on 0.0.0.0:%s, otlp=%s, log_file=%s", port, OTLP_ENDPOINT, LOG_FILE)
    server = HTTPServer(("0.0.0.0", port), Handler)
    server.serve_forever()
