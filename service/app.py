import json
import os
import signal
import socket
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler

def read_config_value(key: str, default: str = "") -> str:
    """
    Read config key dynamically.
    Checks mounted ConfigMap volume file first (/config/<key>),
    falling back to environment variable (<key>).
    """
    file_path = os.path.join("/config", key)
    if os.path.isfile(file_path):
        try:
            with open(file_path, "r", encoding="utf-8") as f:
                val = f.read().strip()
                if val:
                    return val
        except Exception:
            pass
    return os.environ.get(key, default)


class ServiceHandler(BaseHTTPRequestHandler):
    server_version = "DemoService/1.0"

    def do_GET(self):
        if self.path == "/" or self.path == "":
            app_name = read_config_value("APP_NAME", "demo-app")
            version = read_config_value("VERSION", "1.0.0")
            pod_name = os.environ.get("HOSTNAME") or socket.gethostname()

            response_data = {
                "app": app_name,
                "version": version,
                "pod": pod_name
            }
            body = json.dumps(response_data).encode("utf-8")

            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        elif self.path == "/healthz":
            body = json.dumps({"status": "ok"}).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        else:
            body = json.dumps({"error": "not found"}).encode("utf-8")
            self.send_response(404)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    def log_message(self, format, *args):
        sys.stdout.write(f"[{self.log_date_time_string()}] {format % args}\n")
        sys.stdout.flush()


def run_server():
    port = int(os.environ.get("PORT", 8080))
    server_address = ("0.0.0.0", port)
    httpd = HTTPServer(server_address, ServiceHandler)

    def handle_signal(signum, frame):
        sys.stdout.write(f"Received signal {signum}, shutting down...\n")
        sys.stdout.flush()
        httpd.server_close()
        sys.exit(0)

    try:
        signal.signal(signal.SIGTERM, handle_signal)
        signal.signal(signal.SIGINT, handle_signal)
    except (ValueError, AttributeError):
        pass

    sys.stdout.write(f"Starting service on port {port}...\n")
    sys.stdout.flush()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()


if __name__ == "__main__":
    run_server()