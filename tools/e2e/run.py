#!/usr/bin/env python3
"""End to end: the real Debug bundle against the mock server, once per scenario tagged "e2e".

Each run starts tools/mock-dooray/server.py on a free loopback port, launches the binary
inside the bundle with its debug console on stdin and stdout, and checks what the app
prints against the scenario's expected.json, the same file the unit tests use.
A scenario in FILTERS also gets each of its task filters through the console, and the run
checks which tasks stay visible, the counts, and that the change sent no request. A scenario in
CHOICES also checks the settings list: every project including one with no task, a filter
that picks only that project, and the on-demand milestone load with its cache. A scenario in
UPDATES also checks how the update check ends for the version the app is pinned at.

The app gets a fake token through TODOORAY_CONFIG, which keeps its settings in memory, so
a run never reads or writes the Keychain or the saved addresses. The same file points the
update check at the mock server's fake release, so a run never calls GitHub.

Usage: run.py --app build/Build/Products/Debug/ToDooray.app [--scenario basic]
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
BASIC_PROJECTS = {
    "3000000000000000001": {"code": "FE"},
    "3000000000000000002": {"code": "APP", "milestones": {
        "picked": {"7000000000000000001": "v1.0.0"}, "withoutMilestone": False}},
}
FILTERS = {
    "basic": [
        {
            "filter": {"projects": BASIC_PROJECTS},
            "visibleIDs": ["5000000000000000001", "5000000000000000004", "5000000000000000005", "5000000000000000003"],
            "hiddenCount": 5,
        },
        {
            "filter": {"directOnly": True},
            "visibleIDs": ["5000000000000000001", "5000000000000000004", "5000000000000000007", "5000000000000000005",
                           "5000000000000000008", "5000000000000000011", "5000000000000000009", "5000000000000000010"],
            "hiddenCount": 1,
        },
        {
            "filter": {"projects": BASIC_PROJECTS, "directOnly": True},
            "visibleIDs": ["5000000000000000001", "5000000000000000004", "5000000000000000005"],
            "hiddenCount": 6,
        },
    ],
}

CHOICES = {
    "basic": {
        "codes": ["APP", "FE", "OPS", "ADMIN"],
        "emptyProject": "3000000000000000004",
        "hiddenCount": 9,
        "milestoneProject": "3000000000000000002",
        "milestones": ["v1.0.0", "v1.0.1", "v1.1.0"],
    },
}

MOCK_DMG = "https://github.com/megastudymobile/ToDooray/releases/download/v9.9.9/ToDooray-9.9.9.dmg"
UNREACHABLE_RELEASES = "http://127.0.0.1:9/releases/latest"
UPDATES = {
    "basic": {"version": "1.0.0", "update": {"kind": "available", "version": "9.9.9", "downloadURL": MOCK_DMG}},
    "empty": {"version": "9.9.9", "update": {"kind": "upToDate"}},
    "rate-limited": {"version": "1.0.0", "releases": UNREACHABLE_RELEASES, "update": {"kind": "unknown"}},
}
DEFAULT_VERSION = "1.0.0"


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
            [str(bundle / "Contents" / "MacOS" / "ToDooray")],
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
    update = check_update(app, server, UPDATES[name]) if name in UPDATES else None

    panel = app.ask("open", "panel")
    expect(panel["open"] and panel["windowNumber"] > 0, "the panel did not open")
    expect(panel["frame"][2] == 344 and panel["frame"][3] > 0, f"panel frame is {panel['frame']}")
    expect(app.ask("state", "state")["panel"]["open"], "state does not report the open panel")
    expect(not app.ask("close", "panel")["open"], "the panel did not close")

    for case in FILTERS.get(name, []):
        check_filter(app, server, state, case)
    if name in CHOICES:
        check_choices(app, server, CHOICES[name])

    expect(app.quit() == 0, "the app did not exit cleanly")
    summary = f"{state['kind']}, {len(state['agenda'])} tasks, title {title!r}, {placement}"
    return f"{summary}, update {update}" if update else summary


def check_update(app, server, case):
    app.send("state")
    update = app.wait_for("the first update check to end",
                          lambda event: event["type"] == "state" and event["update"]["checked"], timeout=20)["update"]
    expect(update["current"] == case["version"], f"current version is {update['current']}, expected {case['version']}")
    for key in ("kind", "version", "downloadURL"):
        expected = case["update"].get(key)
        expect(update.get(key) == expected, f"update {key} is {update.get(key)!r}, expected {expected!r}")
    served = server.get("/__mock/releases")
    if "releases" in case:
        expect(served == [], f"the mock release was asked for though the app points elsewhere: {served}")
    else:
        asked = [{"userAgent": f"ToDooray/{case['version']}", "accept": "application/vnd.github+json"}]
        expect(served == asked, f"release requests were {served}, expected {asked}")
    return update["kind"]


def check_filter(app, server, unfiltered, case):
    requests = len(server.get("/__mock/requests"))
    expect(app.ask("filter " + json.dumps(case["filter"]), "ok")["type"] == "ok", "the filter command failed")
    state = app.ask("state", "state")
    expect(state["visibleIDs"] == case["visibleIDs"], f"visible ids are {state['visibleIDs']}")
    expect(state["header"]["openCount"] == len(case["visibleIDs"]), f"header count is {state['header']['openCount']}")
    expect(state["hiddenCount"] == case["hiddenCount"], f"hidden count is {state['hiddenCount']}")
    expect(state["filter"].get("directOnly", False) == case["filter"].get("directOnly", False),
           f"state reports directOnly as {state['filter'].get('directOnly')}")
    expect(len(state["agenda"]) == len(unfiltered["agenda"]), "the filter changed the agenda")
    expect(app.ask("open", "panel")["open"], "the panel did not open with a filter on")
    expect(not app.ask("close", "panel")["open"], "the panel did not close")

    expect(app.ask("filter null", "ok")["type"] == "ok", "filter null failed")
    state = app.ask("state", "state")
    expect(state.get("hiddenCount") is None, "hiddenCount stays after the filter is cleared")
    expect(state["visibleIDs"] == [row["id"] for row in unfiltered["agenda"]], "clearing the filter did not show every task")
    expect(state["header"]["openCount"] == unfiltered["header"]["openCount"], "header count did not come back")
    expect(len(server.get("/__mock/requests")) == requests, "changing the filter sent a request")


def check_choices(app, server, case):
    choices = app.ask("choices", "choices")["projects"]
    expect([project["code"] for project in choices] == case["codes"], f"choices are {[p['code'] for p in choices]}")
    empty = next(project for project in choices if project["id"] == case["emptyProject"])
    expect(empty["taskCount"] == 0, f"the project with no task counts {empty['taskCount']}")
    expect(empty["milestoneLoad"].get("state") is None, "milestones loaded before anyone asked")

    requests = len(server.get("/__mock/requests"))
    only_empty = {"projects": {empty["id"]: {"code": empty["code"]}}}
    expect(app.ask("filter " + json.dumps(only_empty), "ok")["type"] == "ok", "the filter command failed")
    state = app.ask("state", "state")
    expect(state["visibleIDs"] == [], f"visible ids are {state['visibleIDs']}")
    expect(state["header"]["openCount"] == 0, f"header count is {state['header']['openCount']}")
    expect(state["hiddenCount"] == case["hiddenCount"], f"hidden count is {state['hiddenCount']}")
    expect(app.ask("filter null", "ok")["type"] == "ok", "filter null failed")
    expect(len(server.get("/__mock/requests")) == requests, "changing the filter sent a request")

    project = case["milestoneProject"]
    path = f"/project/v1/projects/{project}/milestones"
    app.send(f"milestones {project}")
    replies = [app.ask(f"milestones {project}", "milestones")]
    replies.append(app.wait_for("the second milestones reply", lambda event: event["type"] == "milestones", 5))
    for reply in replies:
        expect(reply["load"].get("state") == "loaded", f"milestone load is {reply['load']}")
        names = [milestone["name"] for milestone in reply["milestones"]]
        expect(names == case["milestones"], f"milestones are {names}")
    pages = [request for request in server.get("/__mock/requests") if request["path"] == path]
    expect(len(pages) == 2, f"{len(pages)} milestone requests; two loads should share one two-page fetch")
    expect(server.get("/__mock/unmatched") == [], "the milestone load sent a request no route matches")

    listed = next(p for p in app.ask("choices", "choices")["projects"] if p["id"] == project)
    expect(listed["milestoneLoad"].get("state") == "loaded", f"choices show the load as {listed['milestoneLoad']}")
    names = [milestone["name"] for milestone in listed["milestones"]]
    expect(names == case["milestones"] + ["단계 없음"], f"choices list milestones {names}")


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
            "releasesURL": f"http://127.0.0.1:{server.port}/releases/latest",
        }))
        update = UPDATES.get(directory.name, {})
        env = dict(os.environ, TODOORAY_CONSOLE="1", TODOORAY_CONFIG=str(config),
                   TODOORAY_NOW=spec["now"], TZ=spec["timeZone"],
                   TODOORAY_VERSION=update.get("version", DEFAULT_VERSION))
        env.pop("TODOORAY_RELEASES_URL", None)
        if "releases" in update:
            env["TODOORAY_RELEASES_URL"] = update["releases"]
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
    if not (args.app / "Contents" / "MacOS" / "ToDooray").exists():
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
