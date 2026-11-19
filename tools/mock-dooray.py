#!/usr/bin/env python3
"""Serve fixtures/ as a local stand-in for the Dooray API.

Usage: tools/mock-dooray.py [--port 8787] [--token test-token] [--max-size 100]
                            [--rate-limit-first N] [--shift-dates]
"""
import argparse
import datetime
import json
import pathlib
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

FIXTURES = pathlib.Path(__file__).resolve().parent.parent / "fixtures"
ANCHOR_DAY = datetime.date(2026, 11, 19)
ISO = "%Y-%m-%dT%H:%M:%SZ"


def load(relative):
    return json.loads((FIXTURES / relative).read_text(encoding="utf-8"))


def envelope(result, total=None):
    body = {"header": {"isSuccessful": True, "resultCode": 0, "resultMessage": ""}, "result": result}
    if total is not None:
        body["totalCount"] = total
    return body


def failure(code, message):
    return {"header": {"isSuccessful": False, "resultCode": code, "resultMessage": message}, "result": None}


def assigned_to(post, member_id):
    for entry in post["users"]["to"]:
        if entry["type"] == "member" and entry["member"]["organizationMemberId"] == member_id:
            return True
        if entry["type"] == "group" and any(
            m["organizationMemberId"] == member_id for m in entry["group"]["members"]
        ):
            return True
    return False


class Handler(BaseHTTPRequestHandler):
    options = None
    remaining_rate_limits = 0

    def log_message(self, fmt, *args):
        sys.stdout.write("%s %s\n" % (self.command, self.path))
        sys.stdout.flush()

    def reply(self, status, body, headers=None):
        data = json.dumps(body, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(data)

    def page(self, rows, query):
        size = min(int(query.get("size", ["20"])[0]), self.options.max_size)
        start = int(query.get("page", ["0"])[0]) * size
        return envelope(rows[start : start + size], len(rows))

    def shifted(self, post):
        if not self.options.shift_dates or "dueDate" not in post:
            return post
        offset = datetime.date.today() - ANCHOR_DAY
        due = datetime.datetime.strptime(post["dueDate"], ISO) + offset
        return {**post, "dueDate": due.strftime(ISO)}

    def do_GET(self):
        if self.headers.get("Authorization") != "dooray-api " + self.options.token:
            return self.reply(401, failure(-401, "unauthorized"))
        if Handler.remaining_rate_limits > 0:
            Handler.remaining_rate_limits -= 1
            return self.reply(429, failure(-429, "too many requests"), {"Retry-After": "1"})

        url = urlparse(self.path)
        query = parse_qs(url.query)
        if url.path == "/common/v1/members/me":
            return self.reply(200, load("me.json"))
        if url.path == "/project/v1/projects":
            return self.reply(200, self.page(load("projects.json")["result"], query))

        match = re.fullmatch(r"/project/v1/projects/(\d+)/(workflows|posts)", url.path)
        if not match or not (FIXTURES / "projects" / match.group(1)).is_dir():
            return self.reply(404, failure(-404, "not found"))
        project_id, resource = match.groups()
        rows = load(f"projects/{project_id}/{resource}.json")["result"]
        if resource == "workflows":
            return self.reply(200, envelope(rows))

        member_ids = query.get("toMemberIds", [""])[0].split(",")
        classes = query.get("postWorkflowClasses", [""])[0].split(",")
        if member_ids != [""]:
            rows = [p for p in rows if any(assigned_to(p, m) for m in member_ids)]
        if classes != [""]:
            rows = [p for p in rows if p["workflowClass"] in classes]
        return self.reply(200, self.page([self.shifted(p) for p in rows], query))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument("--token", default="test-token")
    parser.add_argument("--max-size", type=int, default=100, help="cap on page size, lower it to force paging")
    parser.add_argument("--rate-limit-first", type=int, default=0, help="answer the first N requests with 429")
    parser.add_argument("--shift-dates", action="store_true", help="move due dates so the anchor day is today")
    Handler.options = parser.parse_args()
    Handler.remaining_rate_limits = Handler.options.rate_limit_first
    server = ThreadingHTTPServer(("127.0.0.1", Handler.options.port), Handler)
    print(f"mock dooray on http://127.0.0.1:{Handler.options.port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
