// A D-Bus interface for tests, exported only when GNOME Shell runs with SLATED_DEBUG=1 (it can run
// any action, including shell commands, so it never exists in normal use). It lives on GNOME Shell's
// own bus connection, so callers address `org.gnome.Shell`:
//
//   gdbus call --session --dest org.gnome.Shell --object-path /io/github/shobhit_aida/Slated \
//     --method io.github.shobhit_aida.Slated.Debug.RunAction '{"op":"push","direction":"left"}'
//
// Window listings carry ids, app ids and frames, never titles.

import Gio from 'gi://Gio';

export const DEBUG_BUS_NAME = 'org.gnome.Shell';
export const DEBUG_OBJECT_PATH = '/io/github/shobhit_aida/Slated';
export const DEBUG_INTERFACE = 'io.github.shobhit_aida.Slated.Debug';

const XML = `<node>
  <interface name="${DEBUG_INTERFACE}">
    <method name="RunAction">
      <arg type="s" name="action" direction="in"/>
      <arg type="b" name="ok" direction="out"/>
      <arg type="s" name="error" direction="out"/>
    </method>
    <method name="TriggerBinding">
      <arg type="s" name="keys" direction="in"/>
      <arg type="b" name="found" direction="out"/>
    </method>
    <method name="PressKeys">
      <arg type="s" name="keys" direction="in"/>
      <arg type="b" name="ok" direction="out"/>
      <arg type="s" name="error" direction="out"/>
    </method>
    <method name="FocusWindow">
      <arg type="t" name="id" direction="in"/>
      <arg type="b" name="found" direction="out"/>
    </method>
    <method name="GetFocusedWindow">
      <arg type="s" name="json" direction="out"/>
    </method>
    <method name="ListWindows">
      <arg type="s" name="json" direction="out"/>
    </method>
    <method name="GetScreens">
      <arg type="s" name="json" direction="out"/>
    </method>
    <method name="GetStatus">
      <arg type="s" name="json" direction="out"/>
    </method>
    <method name="Reload"/>
  </interface>
</node>`;

/** The D-Bus object. `runtime` provides the debug* methods in runtime.js. */
export class DebugService {
  constructor(runtime) {
    this._runtime = runtime;
    this._object = Gio.DBusExportedObject.wrapJSObject(XML, this);
    this._object.export(Gio.DBus.session, DEBUG_OBJECT_PATH);
  }

  RunAction(json) {
    const result = this._runtime.debugRunAction(json);
    return [result.ok, result.error ?? ''];
  }

  TriggerBinding(keys) {
    return this._runtime.debugTriggerBinding(keys);
  }

  PressKeys(keys) {
    const result = this._runtime.debugPressKeys(keys);
    return [result.ok, result.error ?? ''];
  }

  FocusWindow(id) {
    return this._runtime.debugFocusWindow(Number(id));
  }

  GetFocusedWindow() {
    return JSON.stringify(this._runtime.debugFocusedWindow());
  }

  ListWindows() {
    return JSON.stringify(this._runtime.debugWindows());
  }

  GetScreens() {
    return JSON.stringify(this._runtime.debugScreens());
  }

  GetStatus() {
    return JSON.stringify(this._runtime.debugStatus());
  }

  Reload() {
    this._runtime.scheduleReload('debug');
  }

  destroy() {
    this._object?.unexport();
    this._object = null;
    this._runtime = null;
  }
}
