#!/usr/bin/env python3
"""End to end: the real Debug bundle against the mock server, once per scenario tagged "e2e".

Each run starts tools/mock-dooray/server.py on a free loopback port, launches the binary
inside the bundle with its debug console on stdin and stdout, and checks what the app
prints against the scenario's expected.json, the same file the unit tests use.
A scenario in FILTERS also gets a task filter through the console, and the run checks
which tasks stay visible, the counts, and that the change sent no request.

The app gets a fake token through MEGAMIND_CONFIG, which keeps its settings in memory, so
a run never reads or writes the Keychain or the saved addresses.

Usage: run.py --app build/Build/Products/Debug/MegaMind.app [--scenario basic]
"""
import argparse
import json
import os
import queue
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCENARIOS = ROOT / "fixtures" / "scenarios"
SERVER = ROOT / "tools" / "mock-dooray" / "server.py"
SETTLED = {"loaded", "failed", "authFailed"}
MENU_BAR_TITLES = {
    "basic": "디자인 리뷰 반영 · 18:00",
    "rate-limited": "디자인 리뷰 반영 · 18:00",
    "empty": "할 일 없음",
    "unauthorized": "토큰 확인",
    "server-error": "",
}
FILTERS = {
    "basic": {
        "filter": {"projects": {
            "3000000000000000001": {"code": "FE"},
            "3000000000000000002": {"code": "APP", "milestones": {
                "picked": {"7000000000000000001": "v1.0.0"}, "withoutMilestone": False}},
        }},
        "visibleIDs": ["5000000000000000001", "5000000000000000004", "5000000000000000005", "5000000000000000003"],
        "hiddenCount": 5,
    },
}


class Failure(Exception):
    pass


class MockServer:
    def __init__(self, scenario: Path):
        self.process = subprocess.Popen(
            [sys.executable, str(SERVER), "--scenario", str(scenario), "--port", "0"],
            stdout=subprocess.PIPE, text=True)
        self.port = int(self.process.stdout.readline().split()[1])

    def get(self, path):
        with urllib.request.urlopen(f"http://127.0.0.1:{self.port}{path}", timeout=5) as response:
            return json.load(response)

    def stop(self):
        self.process.terminate()
        self.process.wait(timeout=5)


class App:
    def __init__(self, bundle: Path, env: dict, stderr):
        self.process = subprocess.Popen(
            [str(bundle / "Contents" / "MacOS" / "MegaMind")],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr, text=True, env=env)
        self.lines = []
        self.events = queue.Queue()
        threading.Thread(target=self.read, daemon=True).start()

    def read(self):
        for line in self.process.stdout:
            self.lines.append(line)
            self.events.put(json.loads(line))

    def send(self, command):
        self.process.stdin.write(command + "\n")
        self.process.stdin.flush()

    def wait_for(self, description, predicate, timeout):
        deadline = time.monotonic() + timeout
        last = None
        while True:
            try:
                last = self.events.get(timeout=max(deadline - time.monotonic(), 0.01))
            except queue.Empty:
                raise Failure(f"timed out waiting for {description}; last event: {json.dumps(last, ensure_ascii=False)}")
            if predicate(last):
                return last

    def ask(self, command, event_type, timeout=5):
        self.send(command)
        return self.wait_for(f"the reply to '{command}'", lambda event: event["type"] == event_type, timeout)

    def quit(self):
        self.send("quit")
        return self.process.wait(timeout=5)

    def kill(self):
        if self.process.poll() is None:
            self.process.kill()
            self.process.wait()


def expect(condition, message):
    if not condition:
        raise Failure(message)


def check(app, server, name, expected):
    state = app.wait_for("the first sync to settle",
                         lambda event: event["type"] == "state" and event["kind"] in SETTLED, timeout=30)

    if "tasks" in expected:
        expect(state["kind"] == "loaded", f"kind is {state['kind']}, expected loaded")
        agenda = [{key: row[key] for key in ("id", "key", "urgency", "state")} for row in state["agenda"]]
        expect(agenda == expected["tasks"],
               "agenda differs from expected.json:\n" + json.dumps(agenda, ensure_ascii=False, indent=2))
        expect(state["header"]["openCount"] == len(expected["tasks"]), "header count is not the open count")
    else:
        kind = "authFailed" if expected["error"] == "unauthorized" else "failed"
        expect(state["kind"] == kind, f"kind is {state['kind']}, expected {kind}")
        if kind == "failed":
            expect(state["error"] == expected["error"], f"error is {state['error']}, expected {expected['error']}")

    title = MENU_BAR_TITLES[name]
    expect(state["menuBar"]["full"] == title, f"menu bar title is {state['menuBar']['full']!r}, expected {title!r}")

    served = Counter(request["path"] for request in server.get("/__mock/requests"))
    for path, count in expected.get("requestCounts", {}).items():
        expect(served[path] == count, f"{served[path]} requests to {path}, expected {count}")
    expect(server.get("/__mock/unmatched") == [], "the app sent a request no route matches")

    # macOS hides a status item when the menu bar is full. The app cannot prevent that, so
    # the check is that it either stays on screen or has fallen back all the way to the icon.
    deadline = time.monotonic() + 5
    while not (state["menuBar"]["onScreen"] or state["menuBar"]["form"] == "iconOnly"):
        expect(time.monotonic() < deadline, "the status item is neither on screen nor reduced to its icon")
        time.sleep(0.3)
        state = app.ask("state", "state")
    placement = "status item on screen" if state["menuBar"]["onScreen"] else "status item hidden by macOS"

    panel = app.ask("open", "panel")
    expect(panel["open"] and panel["windowNumber"] > 0, "the panel did not open")
    expect(panel["frame"][2] == 344 and panel["frame"][3] > 0, f"panel frame is {panel['frame']}")
    expect(app.ask("state", "state")["panel"]["open"], "state does not report the open panel")
    expect(not app.ask("close", "panel")["open"], "the panel did not close")

    if name in FILTERS:
        check_filter(app, server, state, FILTERS[name])

    expect(app.quit() == 0, "the app did not exit cleanly")
    return f"{state['kind']}, {len(state['agenda'])} tasks, title {title!r}, {placement}"


def check_filter(app, server, unfiltered, case):
    requests = len(server.get("/__mock/requests"))
    expect(app.ask("filter " + json.dumps(case["filter"]), "ok")["type"] == "ok", "the filter command failed")
    state = app.ask("state", "state")
    expect(state["visibleIDs"] == case["visibleIDs"], f"visible ids are {state['visibleIDs']}")
    expect(state["header"]["openCount"] == len(case["visibleIDs"]), f"header count is {state['header']['openCount']}")
    expect(state["hiddenCount"] == case["hiddenCount"], f"hidden count is {state['hiddenCount']}")
    expect(len(state["agenda"]) == len(unfiltered["agenda"]), "the filter changed the agenda")
    expect(app.ask("open", "panel")["open"], "the panel did not open with a filter on")
    expect(not app.ask("close", "panel")["open"], "the panel did not close")

    expect(app.ask("filter null", "ok")["type"] == "ok", "filter null failed")
    state = app.ask("state", "state")
    expect(state.get("hiddenCount") is None, "hiddenCount stays after the filter is cleared")
    expect(state["visibleIDs"] == [row["id"] for row in unfiltered["agenda"]], "clearing the filter did not show every task")
    expect(state["header"]["openCount"] == unfiltered["header"]["openCount"], "header count did not come back")
    expect(len(server.get("/__mock/requests")) == requests, "changing the filter sent a request")


def run(bundle: Path, directory: Path, spec: dict) -> str:
    expected = json.loads((directory / spec["expect"]).read_text(encoding="utf-8"))
    server = MockServer(directory)
    app = None
    with tempfile.TemporaryDirectory() as work:
        config = Path(work) / "config.json"
        config.write_text(json.dumps({
            "apiBase": f"http://127.0.0.1:{server.port}",
            "webBase": "https://example.dooray.com",
            "token": spec["token"],
        }))
        env = dict(os.environ, MEGAMIND_CONSOLE="1", MEGAMIND_CONFIG=str(config),
                   MEGAMIND_NOW=spec["now"], TZ=spec["timeZone"])
        try:
            with open(Path(work) / "stderr.log", "w+") as stderr:
                app = App(bundle, env, stderr)
                summary = check(app, server, directory.name, expected)
                stderr.seek(0)
                output = "".join(app.lines) + stderr.read()
                expect(spec["token"] not in output, "the token appears in the app's output")
                return summary
        finally:
            if app:
                app.kill()
            server.stop()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--scenario")
    args = parser.parse_args()
    if not (args.app / "Contents" / "MacOS" / "MegaMind").exists():
        print(f"no app bundle at {args.app}; run `make app` first", file=sys.stderr)
        return 2

    failed = 0
    ran = 0
    for directory in sorted(path for path in SCENARIOS.iterdir() if (path / "scenario.json").exists()):
        spec = json.loads((directory / "scenario.json").read_text(encoding="utf-8"))
        if args.scenario not in (None, directory.name) or (not args.scenario and "e2e" not in spec["tags"]):
            continue
        ran += 1
        try:
            print(f"ok    {directory.name}: {run(args.app, directory, spec)}", flush=True)
        except (Failure, subprocess.TimeoutExpired) as failure:
            failed += 1
            print(f"FAIL  {directory.name}: {failure}", flush=True)
    print(f"e2e: {ran - failed} passed, {failed} failed")
    return 1 if failed or not ran else 0


if __name__ == "__main__":
    sys.exit(main())
