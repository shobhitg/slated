#!/usr/bin/env python3
"""End-to-end checks of the Slated GNOME extension inside a running (headless) GNOME Shell.

run.sh starts the shell with SLATED_DEBUG=1 and then runs this script in the same D-Bus session. It
drives the extension through its debug D-Bus interface (lib/platform/debug.js), presses real keys
through it, and checks window frames, status.json and the event log.

Environment:
  SLATED_SKIP_INPUT=1   skip checks that press keys through the virtual keyboard
"""
import json
import os
import subprocess
import sys
import time
from pathlib import Path

import gi

gi.require_version('Gio', '2.0')
from gi.repository import Gio, GLib  # noqa: E402

UUID = 'slated@shobhit-aida.github.io'
OBJECT_PATH = '/io/github/shobhit_aida/Slated'
INTERFACE = 'io.github.shobhit_aida.Slated.Debug'
APP_ID = 'io.github.shobhit_aida.SlatedTest'
HOME = Path.home()
STATE = HOME / '.local/state/slated'
CONFIG = HOME / '.config/slated/config.json'
HERE = Path(__file__).resolve().parent
SKIP_INPUT = os.environ.get('SLATED_SKIP_INPUT') == '1'

bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
counts = {'passed': 0, 'failed': 0, 'skipped': 0}

LEFT_HALF = {'op': 'move', 'x': 'screenOriginX', 'y': 'screenOriginY', 'width': 'screenSizeX/2', 'height': 'screenSizeY'}
RIGHT_HALF = {'op': 'move', 'x': 'screenOriginX+screenSizeX/2', 'y': 'screenOriginY', 'width': 'screenSizeX/2', 'height': 'screenSizeY'}


# --- Helpers ------------------------------------------------------------------------------------------

def call(method, signature=None, *args, interface=INTERFACE, path=OBJECT_PATH, dest='org.gnome.Shell', timeout=10000):
    params = GLib.Variant(f'({signature})', args) if signature else None
    reply = bus.call_sync(dest, path, interface, method, params, None, Gio.DBusCallFlags.NONE, timeout, None)
    values = reply.unpack() if reply is not None else ()
    return values[0] if len(values) == 1 else values


def check(name, ok, detail=''):
    if ok:
        counts['passed'] += 1
        print(f'✔ {name}')
    else:
        counts['failed'] += 1
        print(f'✘ {name}')
        if detail:
            for line in str(detail).splitlines()[:20]:
                print(f'    | {line}')
    return ok


def skip(name, reason):
    counts['skipped'] += 1
    print(f'- {name} (skipped: {reason})')


def wait_until(predicate, timeout=20.0, interval=0.2):
    """Polls `predicate` until it returns something truthy; returns that, or None on timeout."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            value = predicate()
            if value:
                return value
        except (GLib.Error, OSError, ValueError, KeyError, StopIteration):
            pass
        time.sleep(interval)
    return None


def log_events(name=None):
    path = STATE / 'slated.log'
    if not path.exists():
        return []
    events = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    return [e for e in events if name is None or e['event'] == name]


def status():
    return json.loads((STATE / 'status.json').read_text())


def write_config(config):
    CONFIG.parent.mkdir(parents=True, exist_ok=True)
    CONFIG.write_text(json.dumps(config, indent=2))


def focused_window():
    return json.loads(call('GetFocusedWindow'))


def work_area():
    screens = json.loads(call('GetScreens'))
    return next(s for s in screens if s['isMain'])['visibleFrame']


def close(a, b, tolerance=2):
    return all(abs(a[k] - b[k]) <= tolerance for k in ('x', 'y', 'width', 'height'))


def frame_becomes(expected, timeout=5.0):
    """Waits for the focused window's frame to match; returns (matched, last frame)."""
    last = {}

    def matches():
        nonlocal last
        window = focused_window()
        last = window['frame'] if window else {}
        return window and close(window['frame'], expected)

    return bool(wait_until(matches, timeout)), last


def run_action(action):
    ok, error = call('RunAction', 's', json.dumps(action))
    return ok, error


def xkb_options():
    out = subprocess.run(['gsettings', 'get', 'org.gnome.desktop.input-sources', 'xkb-options'], capture_output=True, text=True)
    return out.stdout.strip()


def window_events():
    """What the test window received: {"buttons": {"1": n, …}, "pressed": [names], "released": [names]}."""
    return json.loads((HOME / 'test-window-events.json').read_text())


# --- The scenario -----------------------------------------------------------------------------------

def main():
    # 1. The extension is enabled and running.
    info = call('GetExtensionInfo', 's', UUID, interface='org.gnome.Shell.Extensions', path='/org/gnome/Shell/Extensions', dest='org.gnome.Shell.Extensions')
    check('the extension is enabled (state ACTIVE)', info.get('state') == 1.0, info)
    check('the extension loaded without an error', not info.get('error'), info.get('error'))

    s = wait_until(lambda: status() if status().get('running') else None, 10)
    check('status.json says running', bool(s), s)
    start = log_events('app.start')
    check('app.start is logged with mode gnome-extension', start and start[-1]['data'].get('mode') == 'gnome-extension', start[-1:] if start else 'no app.start')
    if start:
        data = start[-1]['data']
        check('app.start records the GNOME version and session type', data.get('gnome') and data.get('sessionType') == 'wayland', data)
    hotkeys = (s or {}).get('hotkeys', {})
    check('config bindings are registered', all(hotkeys.get(k) == 'active' for k in ('hyper+a', 'hyper+d', 'hyper+c', 'hyper+u')), hotkeys)

    # 2. A window to arrange.
    app = subprocess.Popen(['gjs', '-m', str(HERE / 'test-window.js')], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    window = wait_until(lambda: next((w for w in json.loads(call('ListWindows')) if w['app'] == APP_ID), None), 30)
    if not check('the test window appears', bool(window), call('ListWindows')):
        return
    call('FocusWindow', 't', window['id'])
    check('the test window has focus', wait_until(lambda: (focused_window() or {}).get('id') == window['id'], 5), focused_window())
    area = work_area()

    # 3. Actions through the debug interface.
    ok, error = run_action(LEFT_HALF)
    check('RunAction left half succeeds', ok, error)
    matched, frame = frame_becomes({'x': area['x'], 'y': area['y'], 'width': area['width'] // 2, 'height': area['height']})
    check('the window fills the left half of the work area', matched, f'frame {frame}, work area {area}')
    done = [e for e in log_events('action.done') if e['data'].get('trigger') == 'debug']
    check('action.done is logged with trigger, app and timing', done and done[-1]['data'].get('app') == APP_ID and 'ms' in done[-1]['data'], done[-1:] or log_events()[-5:])

    ok, error = run_action('push up bar-resize:screenSizeY/2')
    check('Slate operation syntax works', ok, error)
    matched, frame = frame_becomes({'x': area['x'], 'y': area['y'], 'width': area['width'], 'height': area['height'] // 2})
    check('the window fills the top half', matched, frame)

    ok, _ = run_action({'op': 'undo'})
    matched, frame = frame_becomes({'x': area['x'], 'y': area['y'], 'width': area['width'] // 2, 'height': area['height']})
    check('undo restores the previous frame', ok and matched, frame)

    ok, error = run_action({'op': 'teleport'})
    failed = log_events('action.failed')
    check('an unknown operation fails and is logged as action.failed', not ok and failed and 'teleport' in failed[-1]['data'].get('error', ''), error)

    # 4. Bindings: the chain cycles per binding.
    check('TriggerBinding finds the chain', call('TriggerBinding', 's', 'hyper+c'))
    matched_left, _ = frame_becomes({'x': area['x'], 'y': area['y'], 'width': area['width'] // 2, 'height': area['height']})
    call('TriggerBinding', 's', 'hyper+c')
    matched_right, frame = frame_becomes({'x': area['x'] + area['width'] // 2, 'y': area['y'], 'width': area['width'] // 2, 'height': area['height']})
    check('a chain binding cycles left, then right', matched_left and matched_right, frame)

    # 5. Real key presses through the virtual keyboard reach the grabbed accelerator.
    if SKIP_INPUT:
        skip('pressing the shortcut runs the binding', 'SLATED_SKIP_INPUT=1')
    else:
        call('TriggerBinding', 's', 'hyper+a')
        frame_becomes({'x': area['x'], 'y': area['y'], 'width': area['width'] // 2, 'height': area['height']})
        ok, error = call('PressKeys', 's', 'ctrl+alt+shift+cmd+d')
        matched, frame = frame_becomes({'x': area['x'] + area['width'] // 2, 'y': area['y'], 'width': area['width'] // 2, 'height': area['height']})
        hotkey = [e for e in log_events('action.done') if e['data'].get('trigger') == 'hotkey hyper+d']
        check('pressing Ctrl+Alt+Shift+Super+D runs the hyper+d binding', ok and matched and hotkey, f'{error} frame {frame}')

    # 6. Overlays open with a modal grab and Escape closes them.
    if SKIP_INPUT:
        skip('window hints and the grid open and close', 'SLATED_SKIP_INPUT=1')
    else:
        ok, error = run_action({'op': 'hint'})
        shown = wait_until(lambda: log_events('hints.shown'), 3)
        call('PressKeys', 's', 'esc')
        dismissed = wait_until(lambda: log_events('hints.dismissed'), 3)
        check('window hints open and Escape dismisses them', ok and shown and dismissed, error or log_events()[-5:])
        ok, error = run_action({'op': 'grid', 'padding': 4, 'grids': {'0': {'width': 6, 'height': 6}}})
        shown = wait_until(lambda: log_events('grid.shown'), 3)
        call('PressKeys', 's', 'esc')
        dismissed = wait_until(lambda: log_events('grid.dismissed'), 3)
        check('the grid opens and Escape dismisses it', ok and shown and dismissed, error or log_events()[-5:])

    # 6b. Game automation: synthesized clicks, held keys and auto-repeats reach the focused window.
    if SKIP_INPUT:
        skip('automation clicks and held keys reach the window', 'SLATED_SKIP_INPUT=1')
    else:
        call('FocusWindow', 't', window['id'])
        frame = focused_window()['frame']
        center = (float(frame['x'] + frame['width'] / 2), float(frame['y'] + frame['height'] / 2))
        check('the pointer moves over the test window', call('MovePointer', 'dd', *center))
        before = window_events()
        ok, error = run_action('click right 2')
        got = wait_until(lambda: window_events()['buttons'].get('3', 0) >= before['buttons'].get('3', 0) + 2, 5)
        check('click right 2 double-clicks the right button in the window', ok and got, f'{error} {window_events()}')
        left = window_events()['buttons'].get('1', 0)
        ok, error = run_action("repeat 0.05 times:5 'click left'")
        got = wait_until(lambda: window_events()['buttons'].get('1', 0) >= left + 5, 5)
        finished = wait_until(lambda: any(e['data'].get('reason') == 'finished' for e in log_events('automation.stopped')), 5)
        check('an auto-repeat clicks five times, then stops by itself', ok and got and finished, f'{error} {window_events()}')
        time.sleep(0.5)
        check('…and no more than five', window_events()['buttons'].get('1', 0) == left + 5, window_events())
        ok, error = run_action('hold key:w')
        held = wait_until(lambda: 'w' in window_events()['pressed'], 5)
        running = wait_until(lambda: status()['automation']['running'] == ['Hold W'], 5)
        check('hold key:w holds W down and status.json shows it', ok and held and running, f'{error} {status().get("automation")}')
        ok, error = run_action('stop-automations')
        released = wait_until(lambda: 'w' in window_events()['released'], 5)
        idle = wait_until(lambda: status()['automation']['running'] == [], 5)
        check('stop-automations releases W', ok and released and idle, f'{error} {window_events()}')
        stopped = log_events('automation.stopped_all')
        check('the stop is logged with its reason', stopped and stopped[-1]['data'].get('reason') == 'stop shortcut', stopped[-1:])

    # 6c. Clipboard history: the test window copied a text when it got focus.
    items = wait_until(lambda: status()['clipboard']['items'] >= 1, 10)
    check('the test window’s copy is in clipboard history', bool(items), status().get('clipboard'))
    saved_path = STATE / 'clipboard.json'
    saved = wait_until(lambda: saved_path.exists() and 'Slated clipboard test' in saved_path.read_text(), 5)
    check('clipboard history is saved, readable only by you', saved and (saved_path.stat().st_mode & 0o777) == 0o600,
          oct(saved_path.stat().st_mode) if saved_path.exists() else 'no clipboard.json')
    check('the log never contains clipboard text', 'Slated clipboard test' not in (STATE / 'slated.log').read_text())
    print(f"    clipboard shortcut status: {status()['hotkeys'].get('shift+cmd+v')}, stop shortcut: {status()['hotkeys'].get('hyper+esc')}")
    if SKIP_INPUT:
        skip('the clipboard switcher opens and closes', 'SLATED_SKIP_INPUT=1')
    else:
        ok, error = run_action({'op': 'clipboard-history'})
        opened = wait_until(lambda: log_events('clipboard.switcher_opened'), 3)
        call('PressKeys', 's', 'esc')
        check('the clipboard switcher opens', ok and opened, error or log_events()[-5:])

    # 7. ~/.slate.js: Slate's JavaScript API with orientation logic, reloaded when the config changes.
    (HOME / '.slate.js').write_text(
        'var third = slate.operation("move", {x: "screenOriginX", y: "screenOriginY", width: "screenSizeX/3", height: "screenSizeY"});\n'
        'var stacked = slate.operation("move", {x: "screenOriginX", y: "screenOriginY", width: "screenSizeX", height: "screenSizeY/3"});\n'
        'slate.bind("j:ctrl,shift,alt,cmd", function (win) {\n'
        '  var rect = slate.screen().rect();\n'
        '  win.doOperation(rect.width > rect.height ? third : stacked);\n'
        '});\n'
    )
    config = json.loads(CONFIG.read_text())
    config['general']['loadSlateConfigs'] = True
    write_config(config)
    loaded = wait_until(lambda: next((src for src in status()['sources'] if src['path'] == '~/.slate.js' and src['bindings'] == 1), None), 10)
    check('~/.slate.js loads with its binding', bool(loaded), status().get('sources'))
    check('the JavaScript binding is registered', status()['hotkeys'].get('hyper+j') == 'active', status()['hotkeys'])
    call('TriggerBinding', 's', 'hyper+j')
    matched, frame = frame_becomes({'x': area['x'], 'y': area['y'], 'width': area['width'] // 3, 'height': area['height']})
    script = log_events('script.binding')
    check('the JavaScript binding runs win.doOperation on a landscape screen', matched and script, f'frame {frame}, {log_events()[-3:]}')

    # 8. Caps Lock as Hyper adds the xkb option and gives it back.
    config['keyboard'] = {'capsLock': 'hyper'}
    write_config(config)
    hyper = wait_until(lambda: status()['hyper'] if status()['hyper'].get('mode') == 'xkb' else None, 10)
    check('Hyper mode is xkb', bool(hyper) and hyper.get('active'), status().get('hyper'))
    check('caps:hyper is added to xkb-options, keeping the others', "'caps:hyper'" in xkb_options() and "'compose:ralt'" in xkb_options(), xkb_options())
    check('keyboard.state logs the chosen mode', any(e['data'].get('mode') == 'xkb' for e in log_events('keyboard.state')))
    # Information, not a check: in the stock keymap Hyper may share Mod4 with Super, which makes <Hyper>
    # shortcuts collide with GNOME's Super shortcuts. Print what this GNOME/xkeyboard-config does.
    wait_until(lambda: 'hyper+a' in status()['hotkeys'], 5)
    print(f"    xkb-mode shortcut statuses: {json.dumps(status()['hotkeys'], sort_keys=True)}")

    # 9. Disabling undoes everything, and lets go of anything Slated holds down.
    held_before = None
    if not SKIP_INPUT:
        call('FocusWindow', 't', window['id'])
        held_before = window_events()['released'].count('w')
        run_action('hold key:w')
        wait_until(lambda: status()['automation']['running'] == ['Hold W'], 5)
    call('DisableExtension', 's', UUID, interface='org.gnome.Shell.Extensions', path='/org/gnome/Shell/Extensions', dest='org.gnome.Shell.Extensions')
    stopped = wait_until(lambda: not status()['running'], 10)
    check('status.json says stopped after disable', stopped, status())
    check('the xkb option is removed on disable', "'caps:hyper'" not in xkb_options() and "'compose:ralt'" in xkb_options(), xkb_options())
    check('app.quit is logged', bool(log_events('app.quit')))
    if held_before is not None:
        released = wait_until(lambda: window_events()['released'].count('w') > held_before, 5)
        check('disabling releases a held key', released, window_events())

    # 10. The log is clean.
    lines = (STATE / 'slated.log').read_text().splitlines()
    check('every log line is valid JSON with the shared schema', all(set(json.loads(line)) <= {'ts', 'level', 'event', 'session', 'data'} for line in lines if line.strip()))
    errors = log_events('runtime.error')
    check('no runtime errors were logged', not errors, errors)
    check('window titles never reach the log', 'Slated test window' not in (STATE / 'slated.log').read_text())
    app.terminate()


if __name__ == '__main__':
    try:
        main()
    except Exception as error:  # noqa: BLE001 — report and fail instead of a traceback mid-run
        check('the scenario ran to the end', False, repr(error))
    print(f"\n{counts['passed']} passed, {counts['failed']} failed, {counts['skipped']} skipped")
    sys.exit(1 if counts['failed'] else 0)
