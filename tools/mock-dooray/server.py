#!/usr/bin/env python3
"""Mock Dooray API that serves one fixtures/scenarios/<name> directory over HTTP.

Standard library only, so any platform's end-to-end tests can run it. The matching rules
are in fixtures/README.md.

Usage:
  server.py --scenario fixtures/scenarios/basic [--port 0]

It prints "LISTENING <port>" once bound. Port 0 picks a free port.

  GET /__mock/requests   every request served so far, as [{path, query, status}]
  GET /__mock/unmatched  the requests that matched no route
"""
import argparse
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qsl, urlsplit


class Scenario:
    def __init__(self, directory: Path):
        spec = json.loads((directory / "scenario.json").read_text(encoding="utf-8"))
        self.authorization = "dooray-api " + spec["token"]
        self.routes = []
        for request in spec["requests"]:
            responses = [
                {
                    "status": response["status"],
                    "headers": response.get("headers", {}),
                    "body": (directory / response["body"]).read_bytes() if "body" in response else b"",
                    "delay": response.get("delayMs", 0) / 1000,
                }
                for response in request["responses"]
            ]
            self.routes.append({"path": request["path"], "query": request.get("query", {}),
                                "responses": responses, "hits": 0})
        self.lock = threading.Lock()
        self.requests = []
        self.unmatched = []

    def respond(self, path, query, authorization):
        with self.lock:
            entry = {"path": path, "query": query}
            self.requests.append(entry)
            if authorization != self.authorization:
                entry["status"] = 401
                return 401, {}, b"", 0
            for route in self.routes:
                if route["path"] == path and route["query"] == query:
                    response = route["responses"][min(route["hits"], len(route["responses"]) - 1)]
                    route["hits"] += 1
                    entry["status"] = response["status"]
                    return response["status"], response["headers"], response["body"], response["delay"]
            entry["status"] = 599
            self.unmatched.append(entry)
            return 599, {}, json.dumps({"unmatched": entry}).encode(), 0


class Handler(BaseHTTPRequestHandler):
    scenario = None

    def do_GET(self):
        url = urlsplit(self.path)
        if url.path == "/__mock/requests":
            return self.reply(200, {}, json.dumps(self.scenario.requests).encode())
        if url.path == "/__mock/unmatched":
            return self.reply(200, {}, json.dumps(self.scenario.unmatched).encode())
        query = dict(parse_qsl(url.query, keep_blank_values=True))
        status, headers, body, delay = self.scenario.respond(url.path, query, self.headers.get("Authorization"))
        time.sleep(delay)
        self.reply(status, headers, body)

    def reply(self, status, headers, body):
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        for name, value in headers.items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--scenario", required=True, type=Path)
    parser.add_argument("--port", type=int, default=0)
    args = parser.parse_args()
    Handler.scenario = Scenario(args.scenario)
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"LISTENING {server.server_address[1]}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
