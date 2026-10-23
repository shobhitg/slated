#!/usr/bin/env python3
"""Readable view of Slated's event log (one JSON event per line).

The log is found by platform:
  macOS  ~/Library/Logs/Slated/slated.log
  Linux  $XDG_STATE_HOME/slated/slated.log (default ~/.local/state/slated/slated.log), written by the
         GNOME Shell extension and its preferences window

Examples:
  scripts/logs.py                    last 50 events
  scripts/logs.py -n 200             last 200 events
  scripts/logs.py --since 15m        events from the last 15 minutes (also 30s, 2h, 1d)
  scripts/logs.py --errors           only errors and warnings
  scripts/logs.py --session last     only the most recent run of the app
  scripts/logs.py --grep hotstring   events whose name or data mention "hotstring"
  scripts/logs.py --follow           keep printing new events as they happen
  scripts/logs.py --summary          counts per event, errors, sessions
  scripts/logs.py --json             raw JSON lines (for tools)
  scripts/logs.py --file slated.log  read a log file from anywhere (a copy from someone else's machine)
"""
import argparse
import datetime as dt
import json
import os
import re
import sys
import time

LEVEL_ICON = {"debug": "·", "info": "✔", "notice": "●", "error": "✘", "fault": "‼"}
COLORS = {"error": "\033[31m", "fault": "\033[31;1m", "notice": "\033[33m", "debug": "\033[2m"}
RESET = "\033[0m"


def detect_platform():
    return "macos" if sys.platform == "darwin" else "linux"


def log_path(home, platform=None, state_home=None):
    """Where Slated writes its log: ~/Library/Logs on macOS, the XDG state folder on Linux."""
    platform = platform or detect_platform()
    if platform == "macos":
        return os.path.join(home, "Library/Logs/Slated/slated.log")
    return os.path.join(state_home or os.path.join(home, ".local/state"), "slated/slated.log")


def parse_since(text):
    m = re.fullmatch(r"(\d+)([smhd])", text or "")
    if not m:
        raise SystemExit(f"--since: use a number and s/m/h/d, like 15m (got {text!r})")
    seconds = int(m.group(1)) * {"s": 1, "m": 60, "h": 3600, "d": 86400}[m.group(2)]
    return dt.datetime.now(dt.timezone.utc) - dt.timedelta(seconds=seconds)


def read_events(path):
    files = [f"{path[:-4]}.{n}.log" for n in (3, 2, 1)] + [path]
    for name in files:
        if not os.path.exists(name):
            continue
        with open(name, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if line:
                    try:
                        yield json.loads(line)
                    except json.JSONDecodeError:
                        yield {"ts": "", "level": "error", "event": "log.unreadable_line", "data": {"line": line[:200]}}


def timestamp(event):
    try:
        return dt.datetime.fromisoformat(event.get("ts", "").replace("Z", "+00:00"))
    except ValueError:
        return None


def fmt_value(value):
    if isinstance(value, list):
        return "[" + ", ".join(fmt_value(v) for v in value) + "]"
    if isinstance(value, float):
        return f"{value:g}"
    return str(value)


def render(event, color):
    ts = timestamp(event)
    when = ts.astimezone().strftime("%H:%M:%S.%f")[:-3] if ts else "--:--:--"
    level = event.get("level", "info")
    data = event.get("data", {})
    details = "  ".join(f"{k}={fmt_value(v)}" for k, v in sorted(data.items()))
    line = f"{when} {LEVEL_ICON.get(level, '?')} {event.get('event', '?'):<26} {details}"
    if color and level in COLORS:
        line = COLORS[level] + line + RESET
    return line


def matches(event, args, since, session):
    if args.errors and event.get("level") not in ("error", "fault", "notice"):
        return False
    if since and (timestamp(event) or since) < since:
        return False
    if session and event.get("session") != session:
        return False
    if args.grep and args.grep.lower() not in json.dumps(event).lower():
        return False
    return True


def summary(events):
    by_event, errors, sessions = {}, [], {}
    for e in events:
        by_event[e.get("event", "?")] = by_event.get(e.get("event", "?"), 0) + 1
        if e.get("level") in ("error", "fault"):
            errors.append(e)
        if e.get("event") == "app.start":
            sessions[e.get("session")] = e
    print(f"{len(events)} events, {len(sessions)} app starts, {len(errors)} errors\n")
    for name, count in sorted(by_event.items(), key=lambda kv: -kv[1]):
        print(f"  {count:6}  {name}")
    if sessions:
        print("\nApp starts:")
        for s, e in list(sessions.items())[-10:]:
            d = e.get("data", {})
            build = f" ({d['build']})" if d.get("build") else ""
            # macOS logs how the app is signed; the GNOME extension, GNOME's version and the session type.
            extras = "  ".join(f"{k}: {d[k]}" for k in ("signing", "gnome", "sessionType") if d.get(k))
            print(f"  {e.get('ts', '')[:19]}  session {s}  {d.get('version')}{build} {d.get('commit')}  {extras}".rstrip())
    if errors:
        print("\nLast errors:")
        for e in errors[-10:]:
            print("  " + render(e, False))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("-n", type=int, default=50, help="number of events (default 50)")
    parser.add_argument("--since", help="only events newer than this, e.g. 15m")
    parser.add_argument("--errors", action="store_true", help="only errors and warnings")
    parser.add_argument("--session", help="a session id, or 'last' for the most recent run")
    parser.add_argument("--grep", help="only events mentioning this text")
    parser.add_argument("--follow", "-f", action="store_true", help="keep printing new events")
    parser.add_argument("--summary", action="store_true", help="counts, app starts and recent errors")
    parser.add_argument("--json", action="store_true", help="print raw JSON lines")
    parser.add_argument("--file", help="read this log file instead of the platform's default")
    parser.add_argument("--platform", choices=["auto", "macos", "linux"], default="auto",
                        help="whose log location to use (default: this machine's)")
    parser.add_argument("--home", default=None, help="home folder to find the log in (default: $SLATED_HOME or ~)")
    args = parser.parse_args()

    platform = detect_platform() if args.platform == "auto" else args.platform
    if args.file:
        path = os.path.expanduser(args.file)
    else:
        home = args.home or os.environ.get("SLATED_HOME") or os.path.expanduser("~")
        # $XDG_STATE_HOME belongs to the real home folder, not one passed with --home or SLATED_HOME.
        state_home = os.environ.get("XDG_STATE_HOME") if home == os.path.expanduser("~") else None
        path = log_path(home, platform, state_home)
    if not os.path.exists(path):
        hint = "Launch Slated first." if platform == "macos" else "Enable the Slated GNOME Shell extension first (see docs/LINUX.md)."
        raise SystemExit(f"No log yet at {path}. {hint}")
    events = list(read_events(path))
    if args.summary:
        summary(events)
        return
    since = parse_since(args.since) if args.since else None
    session = args.session
    if session == "last":
        starts = [e for e in events if e.get("event") == "app.start"]
        session = starts[-1]["session"] if starts else None
    color = sys.stdout.isatty() and not args.json
    selected = [e for e in events if matches(e, args, since, session)]
    for e in selected[-args.n:]:
        print(json.dumps(e, ensure_ascii=False) if args.json else render(e, color))
    if args.follow:
        with open(path, encoding="utf-8", errors="replace") as f:
            f.seek(0, os.SEEK_END)
            while True:
                line = f.readline()
                if not line:
                    time.sleep(0.3)
                    if not os.path.exists(path) or os.path.getsize(path) < f.tell():  # rotated
                        f.close()
                        while not os.path.exists(path):
                            time.sleep(0.3)
                        f = open(path, encoding="utf-8", errors="replace")
                    continue
                try:
                    e = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if matches(e, args, None, None):
                    print(json.dumps(e, ensure_ascii=False) if args.json else render(e, color), flush=True)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
