// Editors for the Mouse & Keys actions (port of AutomationEditors.swift and the automation cases of
// ActionParameters.swift): the mouse button or key to press or hold, what an auto-repeat repeats,
// how often it runs, how it starts and stops, humanized timing, and waits.
//
// Each builder returns a field for ActionEditor: {rows, sync(form), recorders?}. Rows are created
// once per kind and shown or hidden as the action changes, so editing never rebuilds the page.

import Adw from 'gi://Adw';
import Gtk from 'gi://Gtk';

import {actionTitle, secondsText, resolveAction} from '../actions.js';
import {keysString, keyLabel, comboLabel} from '../keys.js';
import {
  MODIFIER_KEY_CHOICES, COMMON_GAME_KEYS, parseInput, rate, modeExplanation, jitterText, sentence, whileHeldNote,
  clipboardSettings, automationSettings,
} from '../automation.js';
import {box, label, button, glyph, icon, comboRow, switchRow, spinRow, notice, keycaps} from './widgets.js';
import {ShortcutRecorder} from './recorder.js';
import {setSubtitle, setTitle} from './configkeys.js';

const BUTTON_ITEMS = [{id: 'left', label: 'Left'}, {id: 'right', label: 'Right'}, {id: 'middle', label: 'Middle'}];
const PHASE_ITEMS = [{id: 'down', label: 'Press down'}, {id: 'up', label: 'Release'}];
const INPUT_ITEMS = [
  {id: 'mouse:left', label: 'Left mouse button'}, {id: 'mouse:right', label: 'Right mouse button'},
  {id: 'mouse:middle', label: 'Middle mouse button'}, {id: 'key', label: 'A key'},
];
const MODE_ITEMS = [{id: 'toggle', label: 'Until pressed again'}, {id: 'while-held', label: 'While held'}];
const INTERVAL_PRESETS = [0.05, 0.1, 0.25, 0.5, 1];
const WAIT_PRESETS = [0.1, 0.25, 0.5, 1, 2];

/** Single, Double, Triple, plus the current count when a hand edit set another one. */
function clickItems(count) {
  const items = [{id: 1, label: 'Single'}, {id: 2, label: 'Double'}, {id: 3, label: 'Triple'}];
  return items.some(i => i.id === count) ? items : [...items, {id: count, label: `${count} clicks`}];
}

/** The input combo's choice for an input string: the mouse button, or "key". */
const inputChoice = input => {
  const parsed = parseInput(input);
  return parsed?.kind === 'mouse' ? `mouse:${parsed.button}` : 'key';
};

/**
 * A menu of keys one click away: keys games use, and (`modifiers`) Shift, Ctrl, Alt and Super on
 * their own, which the recorder can't take since they only modify other keys.
 */
function keyMenu(onPick, {modifiers = true} = {}) {
  const content = box('vertical', 6);
  content.set_margin_top(6);
  content.set_margin_bottom(6);
  content.set_margin_start(6);
  content.set_margin_end(6);
  const popover = new Gtk.Popover({child: content});
  const section = (title, keys) => {
    content.append(label(title, {classes: ['heading']}));
    // Four keys to a line.
    for (let start = 0; start < keys.length; start += 4) {
      const line = box('horizontal', 4);
      line.set_homogeneous(true);
      for (const {key, title: text} of keys.slice(start, start + 4)) {
        const b = new Gtk.Button({child: keycaps(key), css_classes: ['flat'], tooltip_text: `Use ${text}`});
        b.connect('clicked', () => {
          popover.popdown();
          onPick(key);
        });
        line.append(b);
      }
      content.append(line);
    }
  };
  section('Common', COMMON_GAME_KEYS.map(key => ({key, title: keyLabel(key)})));
  if (modifiers) section('Modifier Keys', MODIFIER_KEY_CHOICES);
  return new Gtk.MenuButton({
    icon_name: 'input-keyboard-symbolic', popover, valign: Gtk.Align.CENTER, css_classes: ['flat'],
    tooltip_text: modifiers ? 'Common keys, and Shift, Ctrl, Alt or Super on their own' : 'Common keys',
  });
}

/**
 * A mouse button or a key to press or hold (an input such as "mouse:right" or "key:w"). `get()`
 * returns the current input and `set(input)` stores a new one.
 */
export function inputRows({get, set, title = 'Input'}) {
  const choice = comboRow({
    title, items: INPUT_ITEMS, selected: inputChoice(get()),
    onChange: id => {
      if (id !== 'key') set(id);
      else if (parseInput(get())?.kind !== 'key') set('key:w');
    },
  });
  const recorder = new ShortcutRecorder({
    title: 'Key', keys: parseInput(get())?.keys ?? '', requiresModifier: false, subtitle: 'Record it, or pick one from the menu',
    onChange: keys => keys && set(`key:${keys}`),
  });
  recorder.row.add_suffix(keyMenu(key => set(`key:${key}`)));
  return {
    rows: [choice.row, recorder.row],
    recorders: [recorder],
    sync() {
      const input = get();
      const parsed = parseInput(input);
      choice.set(inputChoice(input));
      recorder.row.set_visible(parsed?.kind !== 'mouse');
      recorder.set(parsed?.kind === 'key' ? parsed.keys : '');
    },
  };
}

/** A click: which button, and single, double or triple. */
export function clickRows({get, update}) {
  const form = get();
  const buttonRow = comboRow({title: 'Button', items: BUTTON_ITEMS, selected: form.mouseButton, onChange: v => update('mouseButton', v)});
  const clicks = comboRow({title: 'Clicks', items: clickItems(form.clickCount), selected: form.clickCount, onChange: v => update('clickCount', v)});
  return {
    rows: [buttonRow.row, clicks.row],
    sync(f) {
      buttonRow.set(f.mouseButton);
      clicks.setItems(clickItems(f.clickCount), f.clickCount);
    },
  };
}

/** Press down or release. */
export function phaseRows({get, update}) {
  const phase = comboRow({title: 'Action', items: PHASE_ITEMS, selected: get().phase, onChange: v => update('phase', v)});
  return {rows: [phase.row], sync: f => phase.set(f.phase)};
}

/** Quick picks for a number of seconds: one row of buttons, the current value highlighted. */
function presetRow(title, values, onPick) {
  const row = new Adw.ActionRow({use_markup: false, title});
  const line = box('horizontal', 4);
  line.set_valign(Gtk.Align.CENTER);
  const buttons = values.map(value => {
    const b = button(secondsText(value), () => onPick(value), {classes: ['flat']});
    line.append(b);
    return {value, button: b};
  });
  row.add_suffix(line);
  return {
    row,
    sync(current) {
      for (const {value, button: b} of buttons) {
        if (Math.abs(value - current) < 0.0005) b.add_css_class('suggested-action');
        else b.remove_css_class('suggested-action');
      }
    },
  };
}

/** What an auto-repeat runs: the quick choices, then any other action on its own page. */
const repeatChoice = action => {
  const a = resolveAction(action);
  return a?.op === 'click' ? 'click' : a?.op === 'keystroke' ? 'key' : 'other';
};

function repeatChoiceItems(action) {
  const items = [{id: 'click', label: 'A click'}, {id: 'key', label: 'A key press'}];
  return repeatChoice(action) === 'other' ? [...items, {id: 'other', label: actionTitle(action)}] : items;
}

/**
 * An auto-repeat: what it repeats (a click or a key here; anything else on a nested page), how
 * often, toggle or while held, an optional number of runs, and humanized timing.
 *
 * @param {object} options
 * @param {() => object} options.get the current form
 * @param {(field: string, value: any) => void} options.update
 * @param {() => void} options.openNested pushes the full editor for the repeated action
 * @param {() => string} options.whileHeldMode status.json's automation.whileHeld
 */
export function repeatRows({get, update, openNested, whileHeldMode = () => 'key-repeat'}) {
  const form = get();
  const setRepeated = action => update('repeatAction', action);
  const repeated = () => get().repeatAction;

  const what = comboRow({
    title: 'Repeat', items: repeatChoiceItems(form.repeatAction), selected: repeatChoice(form.repeatAction),
    onChange: id => {
      if (id === repeatChoice(repeated())) return;
      if (id === 'click') setRepeated({op: 'click', button: 'left'});
      else if (id === 'key') setRepeated({op: 'keystroke', keys: 'e'});
    },
  });
  const clickButton = comboRow({
    title: 'Button', items: BUTTON_ITEMS, selected: 'left',
    onChange: v => setRepeated({...resolveAction(repeated()), button: v}),
  });
  const double = switchRow({
    title: 'Double-click', active: false,
    onChange: on => {
      const click = {...resolveAction(repeated())};
      if (on) click.count = 2;
      else delete click.count;
      setRepeated(click);
    },
  });
  const key = new ShortcutRecorder({
    title: 'Key', keys: '', requiresModifier: false, subtitle: 'The key or shortcut to press each time',
    onChange: keys => keys && setRepeated({op: 'keystroke', keys}),
  });
  key.row.add_suffix(keyMenu(k => setRepeated({op: 'keystroke', keys: k}), {modifiers: false}));
  const nested = new Adw.ActionRow({use_markup: false, title: 'Something else', subtitle: 'Any action but another auto-repeat', activatable: true});
  const nestedGlyph = glyph(form.repeatAction);
  nested.add_prefix(nestedGlyph);
  nested.add_suffix(icon('go-next-symbolic'));
  nested.connect('activated', () => openNested());

  const every = spinRow({
    title: 'Every', subtitle: '', min: 10, max: 3_600_000, step: 10, value: Math.round(form.interval * 1000),
    onChange: ms => update('interval', Math.max(10, Math.round(ms)) / 1000),
  });
  const presets = presetRow('Quick picks', INTERVAL_PRESETS, value => update('interval', value));
  const mode = comboRow({title: 'Runs', items: MODE_ITEMS, selected: form.repeatMode, onChange: v => update('repeatMode', v)});
  const limited = switchRow({
    title: 'Stop after a number of runs', active: form.repeatTimes !== null,
    onChange: on => update('repeatTimes', on ? (get().repeatTimes ?? 10) : null),
  });
  const times = spinRow({title: 'Number of runs', min: 1, max: 100_000, value: form.repeatTimes ?? 10, onChange: v => update('repeatTimes', Math.max(1, Math.round(v)))});
  const humanize = switchRow({
    title: 'Humanize timing', active: form.jitter > 0,
    onChange: on => update('jitter', on ? Math.max(get().jitter, 0.15) : 0),
  });
  const vary = spinRow({
    title: 'Vary each interval by up to', subtitle: 'Percent', min: 5, max: 50, step: 5, value: Math.round((form.jitter || 0.15) * 100),
    onChange: v => update('jitter', Math.min(Math.max(Math.round(v), 1), 50) / 100),
  });

  return {
    rows: [what.row, clickButton.row, double.row, key.row, nested, every.row, presets.row, mode.row, limited.row, times.row, humanize.row, vary.row],
    recorders: [key],
    sync(f) {
      const action = resolveAction(f.repeatAction);
      const choice = repeatChoice(action);
      what.setItems(repeatChoiceItems(action), choice);
      clickButton.row.set_visible(choice === 'click');
      double.row.set_visible(choice === 'click');
      key.row.set_visible(choice === 'key');
      if (choice === 'click') {
        clickButton.set(action.button ?? 'left');
        double.set(action.count === 2);
      }
      if (choice === 'key') key.set(keysString(action.keys));
      setTitle(nested, choice === 'other' ? actionTitle(action) : 'Something else');
      setSubtitle(nested, choice === 'other' ? 'Change what repeats' : 'Any action but another auto-repeat');
      nestedGlyph._slatedUpdate(action);
      const ms = Math.round(f.interval * 1000);
      every.set(ms);
      setSubtitle(every.row, f.interval < 0.03
        ? `${ms} ms, ${rate(f.interval)}. Very fast: some games ignore clicks faster than about 30 a second.`
        : `${ms} ms, ${rate(f.interval)}`);
      presets.sync(f.interval);
      mode.set(f.repeatMode);
      const note = f.repeatMode === 'while-held' ? whileHeldNote({action: {op: 'repeat', action, mode: 'while-held'}}, whileHeldMode()) : null;
      setSubtitle(mode.row, [modeExplanation(f.repeatMode), note].filter(Boolean).join(' '));
      limited.set(f.repeatTimes !== null);
      times.row.set_visible(f.repeatTimes !== null);
      if (f.repeatTimes !== null) {
        times.set(f.repeatTimes);
        const total = secondsText(Math.max(f.repeatTimes - 1, 0) * f.interval);
        setSubtitle(times.row, `Stops by itself after ${f.repeatTimes} run${f.repeatTimes === 1 ? '' : 's'}, about ${total} at this speed. Press the shortcut again to stop early.`);
      }
      humanize.set(f.jitter > 0);
      setSubtitle(humanize.row, f.jitter > 0
        ? `Each interval varies by up to ${jitterText(f.jitter)}, so it doesn't tick like clockwork.`
        : "Off: perfectly even timing. Some games ignore input that's too regular; humanizing helps.");
      vary.row.set_visible(f.jitter > 0);
      if (f.jitter > 0) vary.set(Math.round(f.jitter * 100));
    },
    /** One sentence for the group's description: "Clicks the left button 10 times a second until pressed again." */
    describe: action => `${sentence(action)}.`,
  };
}

/** A wait: seconds, with quick picks. */
export function waitRows({get, update}) {
  const seconds = spinRow({
    title: 'Seconds', min: 0, max: 3600, step: 0.05, digits: 2, value: get().seconds,
    onChange: v => update('seconds', Math.max(0, Math.round(v * 1000) / 1000)),
  });
  const presets = presetRow('Quick picks', WAIT_PRESETS, value => update('seconds', value));
  return {
    rows: [seconds.row, presets.row],
    sync(f) {
      seconds.set(f.seconds);
      setSubtitle(seconds.row, secondsText(f.seconds));
      presets.sync(f.seconds);
    },
  };
}

/** Stop Automations: Slated's built-in stop shortcut does the same. */
export function stopAutomationsInfo(ctx) {
  const card = notice({level: 'info', title: '', actions: [{label: 'Automation Settings', onClick: () => ctx.navigate('automation')}]});
  return {
    rows: [card.widget],
    sync() {
      const stop = automationSettings(ctx.model.configuration).stopShortcut;
      card.update({
        level: stop ? 'info' : 'warning',
        title: stop ? 'The built-in stop shortcut does the same' : 'There is no built-in stop shortcut',
        detail: stop
          ? `${comboLabel(stop)} stops every automation and lets go of anything held, from any app.`
          : 'Set one in Automation, or keep this shortcut handy: it lets go of anything an automation holds down.',
      });
    },
  };
}

/** Clipboard History: what opens it, and a warning when it's off. */
export function clipboardHistoryInfo(ctx) {
  const card = notice({level: 'info', title: '', actions: [{label: 'Clipboard Settings', onClick: () => ctx.navigate('clipboard')}]});
  return {
    rows: [card.widget],
    sync() {
      const settings = clipboardSettings(ctx.model.configuration);
      if (!settings.enabled) {
        card.update({level: 'warning', title: 'Clipboard history is off',
          detail: 'Turn it on in Clipboard, or this shortcut has nothing to show.'});
      } else {
        card.update({level: 'info', title: 'Opens the clipboard switcher',
          detail: settings.shortcut ? `The built-in shortcut opens it too: ${comboLabel(settings.shortcut)}.` : 'Search what you copied, then press Return to paste it.'});
      }
    },
  };
}
