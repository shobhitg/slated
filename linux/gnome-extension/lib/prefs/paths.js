// Where Slated for Linux keeps its files. Pure: callers pass the home folder and environment (in the
// preferences window that's GLib.get_home_dir() and GLib.getenv()).
//
// - config: $XDG_CONFIG_HOME/slated/config.json (default ~/.config/slated/config.json), the same
//   file the macOS app uses;
// - state:  $XDG_STATE_HOME/slated/ (default ~/.local/state/slated/) with status.json, written by
//   the extension, and slated.log, the event log (JSON Lines, same events as on macOS).

/**
 * @param {string} home the home folder
 * @param {(name: string) => string|null} getenv environment lookup
 */
export function slatedPaths(home, getenv = () => null) {
  const base = home.replace(/\/$/, '');
  const absolute = value => (value && value.startsWith('/') ? value.replace(/\/$/, '') : null);
  const configHome = absolute(getenv('XDG_CONFIG_HOME')) ?? `${base}/.config`;
  const stateHome = absolute(getenv('XDG_STATE_HOME')) ?? `${base}/.local/state`;
  return {
    home: base,
    configDir: `${configHome}/slated`,
    configFile: `${configHome}/slated/config.json`,
    stateDir: `${stateHome}/slated`,
    statusFile: `${stateHome}/slated/status.json`,
    logFile: `${stateHome}/slated/slated.log`,
  };
}
