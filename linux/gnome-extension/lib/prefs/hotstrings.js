// Hotstring helpers for the editor: the "try it" simulator (port of
// Sources/SlatedUI/Model/HotstringTester.swift) and the espanso guidance shown on Linux, where text
// expansion runs through espanso (the extension writes espanso's match file from config.json).
//
// Pure ES module.

/** Characters that end a word: anything that isn't a letter or digit. */
export function isDelimiter(c) {
  return !/[\p{L}\p{N}]/u.test(c);
}

function triggerStart(text, hotstring) {
  const trigger = hotstring.trigger;
  const chars = [...text];
  const t = [...trigger];
  if (chars.length < t.length) return -1;
  const start = chars.length - t.length;
  const tail = chars.slice(start).join('');
  const matches = hotstring.caseSensitive === false ? tail.toLowerCase() === trigger.toLowerCase() : tail === trigger;
  if (!matches) return -1;
  if (hotstring.wordBoundary && start > 0 && !isDelimiter(chars[start - 1])) return -1;
  return start;
}

/**
 * The expanded text when typing the last character of `current` (one character appended to
 * `previous`) fires `hotstring`; otherwise null. Runs entirely on the field's own text, so it never
 * touches other apps.
 */
export function expandTyping(previous, current, hotstring) {
  if (!hotstring?.trigger) return null;
  const prev = [...previous];
  const cur = [...current];
  if (cur.length !== prev.length + 1 || !current.startsWith(previous)) return null;
  const typed = cur[cur.length - 1];
  if ((hotstring.fire ?? 'immediately') === 'immediately') {
    const start = triggerStart(current, hotstring);
    if (start < 0) return null;
    return cur.slice(0, start).join('') + (hotstring.replacement ?? '');
  }
  if (!isDelimiter(typed)) return null;
  const body = cur.slice(0, -1).join('');
  const start = triggerStart(body, hotstring);
  if (start < 0) return null;
  return [...body].slice(0, start).join('') + (hotstring.replacement ?? '') + typed;
}

/**
 * What a hotstring's app filter means on GNOME. The filters hold Mac bundle identifiers, and espanso
 * can't tell apps apart on GNOME Wayland, so the extension leaves out hotstrings limited to some
 * apps and expands the ones with exceptions everywhere (lib/platform/espanso.js). Null without a
 * filter; else {caption} for the list and {detail} for the editor.
 */
export function gnomeScopeNote(hotstring) {
  const only = hotstring?.onlyInApps ?? [];
  const except = hotstring?.exceptInApps ?? [];
  const mac = 'On the Mac, apps are bundle identifiers like com.apple.mail.';
  if (only.length) {
    return {
      caption: `Mac only: in ${only.join(', ')}`,
      detail: `Mac only. espanso can't tell apps apart on GNOME, so a hotstring limited to some apps doesn't expand here. ${mac}`,
    };
  }
  if (except.length) {
    return {
      caption: `Everywhere here; not in ${except.join(', ')} on the Mac`,
      detail: `On GNOME this expands in every app: espanso can't tell apps apart here. ${mac}`,
    };
  }
  return null;
}

/** espanso is installed and Slated writes its match file, but espanso itself doesn't run. */
export const ESPANSO_START = 'espanso start';

/**
 * What the Hotstrings page says about espanso, from status.json's "hotstrings" entry and whether
 * `espanso status` says it runs (`espansoRunning`: true, false, or null when unknown).
 */
export function espansoGuidance(hotstringsStatus, running, espansoRunning = null) {
  const s = hotstringsStatus ?? {};
  if (!running) {
    return {
      level: 'info', title: 'Expansion runs through espanso',
      detail: 'Slated turns these hotstrings into an espanso match file while it runs. Start Slated to apply changes (see Overview).',
    };
  }
  if (!s.espansoInstalled) {
    return {
      level: 'warning', title: 'Install espanso to expand hotstrings',
      detail: 'On GNOME, only espanso can type text into other apps. Install its Wayland build, then run '
        + '“espanso service register” and “espanso start”. Slated keeps your hotstrings in sync with it.',
      link: 'https://espanso.org/install/linux/',
    };
  }
  if (s.engine !== 'espanso') {
    return {
      level: 'warning', title: "espanso is installed but Slated isn't using it",
      detail: 'Check that espanso is running (“espanso status”) and look at the Slated log for details.',
    };
  }
  if (espansoRunning === false) {
    return {
      level: 'warning', title: "espanso isn't running",
      detail: `Slated keeps your hotstrings in espanso's match file, but espanso itself isn't running, so nothing expands. `
        + `Start it with “${ESPANSO_START}”. Running linux/install.sh again also registers it to start when you log in.`,
      command: ESPANSO_START,
    };
  }
  return {
    level: 'ok', title: 'Expansion runs through espanso',
    detail: `Slated keeps ${s.count === 1 ? '1 hotstring' : `${s.count ?? 0} hotstrings`} in sync with espanso`
      + (s.matchFile ? ` (${s.matchFile}).` : '.'),
  };
}
