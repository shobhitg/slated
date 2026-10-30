// Checks the JavaScript engine against the golden vectors Swift wrote to /fixtures
// (`swift run SlatedFixtures`). Each fixture section is one test; every case in it is compared.

import * as core from '../gnome-extension/lib/core/index.js';
import {SlatedError} from '../gnome-extension/lib/core/errors.js';
import {closestName, editDistance} from '../gnome-extension/lib/core/expression.js';
import {canonicalKey, isValidKey, keyDisplayName, modifierToken} from '../gnome-extension/lib/core/keys.js';
import {
  readSettings,
  screenRefFromSlate,
  screenRefToSlate,
  settingBool,
  settingDouble,
  settingFromSlate,
  settingString,
} from '../gnome-extension/lib/core/model.js';
import {describeDiagnostic, stableUUID, stripComment} from '../gnome-extension/lib/core/slateConfig.js';
import {escapeText, unescapeText} from '../gnome-extension/lib/core/slateSyntax.js';
import {isDelimiter} from '../gnome-extension/lib/core/hotstrings.js';
import * as text from '../gnome-extension/lib/core/text.js';
import * as tokenizer from '../gnome-extension/lib/core/tokenizer.js';
import {countCheck, expect, expectEqual, fail, firstDifference, show, test} from './harness.mjs';

const UUID = /[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}/g;

/** Converts the fixture's {"$double": "inf" | "-inf" | "nan"} markers back to numbers. */
function revive(value) {
  if (Array.isArray(value)) return value.map(revive);
  if (value !== null && typeof value === 'object') {
    const keys = Object.keys(value);
    if (keys.length === 1 && keys[0] === '$double') return {inf: Infinity, '-inf': -Infinity, nan: NaN}[value.$double];
    const out = {};
    for (const k of keys) out[k] = revive(value[k]);
    return out;
  }
  return value;
}

/** Runs `body`, returning {value} or {error}. */
function attempt(body) {
  try {
    return {value: body()};
  } catch (error) {
    return {error};
  }
}

/** Compares an engine call with a fixture outcome: `expected.error` ({kind, message}) or the value. */
function checkOutcome(label, outcome, expected, valueKey, compare = (a, b) => firstDifference(a, b)) {
  countCheck();
  if (expected.error !== undefined) {
    if (outcome.error === undefined) return fail(`${label}: expected error ${show(expected.error.message)}, got ${show(outcome.value)}`);
    return checkError(label, outcome.error, expected.error);
  }
  if (outcome.error !== undefined) return fail(`${label}: unexpected error ${outcome.error && outcome.error.message}`);
  const d = compare(outcome.value, revive(expected[valueKey]));
  if (d !== null) fail(`${label}: ${d}`);
}

function checkError(label, error, expected) {
  if (!(error instanceof SlatedError)) return fail(`${label}: threw ${error && error.stack ? error.stack : error}`);
  if (expected.kind === 'decoding') {
    if (error.kind !== 'invalidConfiguration') fail(`${label}: expected a decoding error, got ${error.kind}: ${error.message}`);
    if (expected.exact && error.message !== expected.message) {
      fail(`${label}: expected message ${show(expected.message)}, got ${show(error.message)}`);
    }
    return;
  }
  if (expected.kind === 'encoding' || expected.kind === 'other') {
    if (error.kind !== 'invalidConfiguration') fail(`${label}: expected an ${expected.kind} error, got ${error.kind}: ${error.message}`);
    return;
  }
  if (error.kind !== expected.kind || error.message !== expected.message) {
    fail(`${label}: expected ${expected.kind} ${show(expected.message)}, got ${error.kind} ${show(error.message)}`);
  }
}

/**
 * One config-files vector: decodeConfigurationFiles on config.json `input` and settings.json
 * `settingsInput` (missing: none), then both files as encodeConfigurationFiles writes them, compared
 * with Swift's texts; `legacy` (what a version 1 file said), or the error and the file it names.
 */
function checkConfigFiles(c) {
  countCheck();
  const label = c.name;
  const decoded = attempt(() => core.decodeConfigurationFiles(c.input, c.settingsInput ?? null));
  if (c.error) {
    if (decoded.error === undefined) return fail(`${label}: expected error ${show(c.error.message)}`);
    checkError(label, decoded.error, c.error);
    if (c.errorFile !== undefined && decoded.error.file !== c.errorFile) {
      fail(`${label}: the error names ${show(decoded.error.file)}, expected ${show(c.errorFile)}`);
    }
    return;
  }
  if (decoded.error) return fail(`${label}: unexpected error ${decoded.error.message} at ${show(decoded.error.codingPath)} in ${decoded.error.file}`);
  const {configuration, extras, legacy} = decoded.value;
  expectEqual(legacy, c.legacy, `${label} (legacy)`);
  const encoded = attempt(() => core.encodeConfigurationFiles(configuration, extras));
  if (c.encodeError) {
    expect(encoded.error instanceof SlatedError, `${label}: expected encoding to fail, got ${show(encoded.value)}`);
    return;
  }
  if (encoded.error) return fail(`${label}: encoding failed: ${encoded.error.message}`);
  const known = `${c.input}${c.settingsInput ?? ''}`.toUpperCase();
  const mask = (text) => text.replace(UUID, (u) => (known.includes(u) ? u : 'RANDOM-UUID'));
  expectEqual(mask(encoded.value.config), c.config, `${label} (config.json)`);
  expectEqual(mask(encoded.value.settings), c.settings, `${label} (settings.json)`);
  // Writing what was read back gives the same texts again, and, where Swift's does, the same configuration.
  const again = attempt(() => core.decodeConfigurationFiles(encoded.value.config, encoded.value.settings));
  if (again.error) return fail(`${label}: reading the written files failed: ${again.error.message}`);
  expectEqual(core.encodeConfigurationFiles(again.value.configuration, again.value.extras), encoded.value, `${label} (re-encoded)`);
  if (c.roundTrips === true) expectEqual(again.value.configuration, configuration, `${label} (round trip)`);
}

const ulp = (x) => (x === 0 ? Number.MIN_VALUE : 2 ** (Math.floor(Math.log2(Math.abs(x))) - 52));

/** Exact equality, or within 4 ulps when the fixture marks a libm-dependent result. */
function numberCompare(tolerance) {
  return (actual, expected) => {
    if (Object.is(actual, expected)) return null;
    if (tolerance === 'ulp' && typeof actual === 'number' && Math.abs(actual - expected) <= 4 * ulp(expected)) return null;
    return `expected ${show(expected)}, got ${show(actual)}`;
  };
}

/** Each fixture file's checks, by section; `sections` must cover every section in the file. */
export const checkers = {
  'expressions.json': (data) => ({
    evaluate() {
      for (const c of data.evaluate) {
        const variables = data.variables[c.variables];
        const label = `${show(c.expression)} with ${c.variables} variables`;
        if (c.random) {
          countCheck();
          for (let i = 0; i < 50; i++) {
            const r = attempt(() => core.evaluateExpression(c.expression, variables));
            const v = r.value;
            if (r.error || !(v >= c.random.min && v < c.random.max) || (c.random.integer && v !== Math.round(v))) {
              fail(`${label}: ${show(v ?? r.error?.message)} is out of range`);
              break;
            }
          }
          continue;
        }
        checkOutcome(label, attempt(() => core.evaluateExpression(c.expression, variables)), c, 'result', numberCompare(c.tolerance));
      }
    },
    validate() {
      for (const c of data.validate) {
        const names = data.variableSets[c.variables];
        checkOutcome(show(c.expression), attempt(() => (core.validateExpression(c.expression, names), true)), c, 'valid');
      }
      countCheck(2);
      expectEqual([...core.windowVariableNames].sort(), data.windowVariableNames, 'windowVariableNames');
      expectEqual([...core.variableNames].sort(), data.variableNames, 'variableNames');
    },
    closestName() {
      for (const c of data.closestName) {
        countCheck();
        expectEqual(closestName(c.name, c.candidates), c.result, show(c.name));
      }
    },
    editDistance() {
      for (const c of data.editDistance) {
        countCheck();
        expectEqual(editDistance(c.a, c.b), c.distance, `${show(c.a)} → ${show(c.b)}`);
      }
    },
  }),

  'tokenizer.json': (data) => ({
    tokenize() {
      for (const c of data.tokenize) checkOutcome(show(c.input), attempt(() => tokenizer.tokenize(c.input)), c, 'tokens');
    },
    leadingTokens() {
      for (const c of data.leadingTokens) {
        const outcome = attempt(() => tokenizer.leadingTokens(c.input, c.count));
        checkOutcome(show(c.input), outcome, c.error ? c : {both: {tokens: c.tokens, rest: c.rest}}, 'both');
      }
    },
    split() {
      for (const c of data.split) checkOutcome(show(c.input), attempt(() => tokenizer.split(c.input, c.separators)), c, 'pieces');
    },
    firstIndexOutsideQuotes() {
      for (const c of data.firstIndexOutsideQuotes) {
        countCheck();
        const index = tokenizer.firstIndexOutsideQuotes(c.input, c.character);
        expectEqual(index < 0 ? null : index, c.index, show(c.input));
      }
    },
    quote() {
      for (const c of data.quote) {
        countCheck();
        expectEqual(tokenizer.quote(c.input), c.quoted, `quote ${show(c.input)}`);
        expectEqual(tokenizer.quoteIfNeeded(c.input), c.quotedIfNeeded, `quoteIfNeeded ${show(c.input)}`);
      }
    },
    unquote() {
      for (const c of data.unquote) {
        countCheck();
        expectEqual(tokenizer.unquote(c.input), c.unquoted, show(c.input));
      }
    },
    shellArguments() {
      for (const c of data.shellArguments) checkOutcome(show(c.input), attempt(() => core.shellArguments(c.input)), c, 'arguments');
    },
    escapeText() {
      for (const c of data.escapeText) {
        countCheck();
        expectEqual(escapeText(c.input), c.escaped, `escape ${show(c.input)}`);
        expectEqual(unescapeText(c.input), c.unescaped, `unescape ${show(c.input)}`);
      }
    },
    trimming() {
      for (const c of data.trimming) {
        countCheck();
        const ch = String.fromCodePoint(c.codePoint);
        const label = `U+${c.codePoint.toString(16).toUpperCase().padStart(4, '0')}`;
        expectEqual(text.trimWhitespace(`${ch}x${ch}`) === 'x', c.whitespaces, `${label} in .whitespaces`);
        expectEqual(text.trimWhitespaceAndNewlines(`${ch}x${ch}`) === 'x', c.whitespacesAndNewlines, `${label} in .whitespacesAndNewlines`);
        expectEqual(text.isWhitespace(ch), c.isWhitespace, `${label} isWhitespace`);
        expectEqual(text.isNewline(ch), c.isNewline, `${label} isNewline`);
      }
    },
  }),

  'operations.json': (data) => ({
    parse() {
      for (const c of data.parse) {
        const label = show(c.input);
        const outcome = attempt(() => core.parseOperation(c.input));
        checkOutcome(label, outcome, c, 'action');
        if (c.error || outcome.error) continue;
        expectEqual(core.isWindowGeometry(outcome.value), c.isWindowGeometry, `isWindowGeometry ${label}`);
        // Formatting what was parsed keeps a grid's written order; formatting the JSON form sorts it.
        expectEqual(core.formatOperation(outcome.value), c.format, `format ${label}`);
        const canonical = c.formatCanonical ?? c.format;
        expectEqual(core.formatOperation(c.action), canonical, `format JSON of ${label}`);
        const reparsed = attempt(() => core.parseOperation(canonical));
        if (c.reparseError) checkOutcome(`reparse ${label}`, reparsed, {error: c.reparseError});
        else checkOutcome(`reparse ${label}`, reparsed, {action: c.reparsed ?? c.action}, 'action');
      }
    },
    format() {
      for (const c of data.format) {
        const label = show(c.action);
        countCheck();
        expectEqual(core.formatOperation(c.action), c.format, `format ${label}`);
        const reparsed = attempt(() => core.parseOperation(c.format));
        if (c.reparseError) checkOutcome(`reparse ${show(c.format)}`, reparsed, {error: c.reparseError});
        else checkOutcome(`reparse ${show(c.format)}`, reparsed, c, 'reparsed');
      }
    },
    decode() {
      for (const c of data.decode) checkOutcome(c.json, attempt(() => core.decodeAction(JSON.parse(c.json))), c, 'action');
    },
  }),

  'keys.json': (data) => ({
    keyCombos() {
      for (const c of data.keyCombos) {
        countCheck();
        const label = show(c.input);
        const combo = core.parseKeyCombo(c.input);
        expectEqual(combo, c.combo, label);
        if (combo === null || c.combo === null) continue;
        expectEqual(core.formatKeyCombo(combo), c.string, `string ${label}`);
        expectEqual(core.displayKeyCombo(combo), c.display, `display ${label}`);
        expectEqual(core.displayKeyCombo(combo, {hyperGlyph: false}), c.displayPlain, `plain display ${label}`);
        expectEqual(isValidKey(combo.key), c.keyIsValid, `valid ${label}`);
      }
    },
    comboParts() {
      for (const c of data.comboParts) {
        countCheck();
        const label = `${show(c.key)} ${show(c.modifiers)}`;
        const input = {key: c.key, modifiers: c.modifiers};
        expectEqual({key: canonicalKey(c.key), modifiers: c.modifiers}, c.combo, label);
        expectEqual(core.formatKeyCombo(input), c.string, `string ${label}`);
        expectEqual(core.displayKeyCombo(input), c.display, `display ${label}`);
        expectEqual(core.displayKeyCombo(input, {hyperGlyph: false}), c.displayPlain, `plain display ${label}`);
        expectEqual(isValidKey(canonicalKey(c.key)), c.keyIsValid, `valid ${label}`);
      }
    },
    keyNames() {
      for (const c of data.keyNames) {
        countCheck();
        const label = show(c.name);
        expectEqual(canonicalKey(c.name), c.canonical, `canonical ${label}`);
        expectEqual(isValidKey(c.name), c.valid, `valid ${label}`);
        expectEqual(keyDisplayName(c.canonical), c.display, `display ${label}`);
        expectEqual(keyDisplayName(c.name), c.displayRaw, `raw display ${label}`);
        expectEqual(core.isModifierKey(c.name), c.modifierKey, `modifier key ${label}`);
        expectEqual(core.isMouseButton(c.name), c.mouseButton, `mouse button ${label}`);
      }
    },
    modifierTokens() {
      for (const c of data.modifierTokens) {
        countCheck();
        expectEqual(modifierToken(c.token), c.modifiers, show(c.token));
      }
    },
    keystrokes() {
      for (const c of data.keystrokes) {
        const outcome = attempt(() => core.parseKeystroke(c.input));
        checkOutcome(show(c.input), outcome, c.error ? c : {parsed: {keys: c.keys, modal: c.modal}}, 'parsed');
      }
    },
  }),

  'screens.json': (data) => ({
    parse() {
      for (const c of data.parse) {
        countCheck();
        const ref = screenRefFromSlate(c.input);
        expectEqual(ref === null ? null : screenRefToSlate(ref), c.ref, show(c.input));
      }
    },
    resolve() {
      for (const group of data.resolve) {
        const setup = data.setups[group.setup];
        const context = {frame: setup.windows[group.window], screens: setup.screens, settings: data.settings[group.settings]};
        for (const [ref, expected] of Object.entries(group.results)) {
          const label = `${ref} from ${group.window} on ${group.setup} (${group.settings})`;
          checkOutcome(label, attempt(() => core.resolveScreen(ref === '(none)' ? null : ref, context)?.name ?? null), {name: expected}, 'name');
        }
      }
    },
    orderedLeftToRight() {
      for (const c of data.orderedLeftToRight) {
        countCheck();
        const screens = c.screens ?? data.setups[c.setup].screens;
        expectEqual(core.orderedLeftToRight(screens).map((s) => s.name), c.names, c.setup ?? show(c.names));
      }
    },
    containing() {
      for (const c of data.containing) {
        countCheck();
        expectEqual(core.screenContaining(data.setups[c.setup].screens, c.rect)?.name ?? null, c.screen, `${show(c.rect)} on ${c.setup}`);
      }
    },
  }),

  'frames.json': (data, files) => {
    const screens = files['screens.json'];
    const contextOf = (group) => {
      const setup = screens.setups[group.setup];
      return {frame: setup.windows[group.window], screens: setup.screens, settings: screens.settings[group.settings]};
    };
    const compare = (fields) => (actual, expected) => {
      const values = fields.map((f) => actual[f]);
      return firstDifference(values, expected);
    };
    return {
      targetFrame() {
        for (const group of data.targetFrame) {
          const context = contextOf(group);
          for (const [op, expected] of Object.entries(group.results)) {
            const label = `${op} from ${group.window} on ${group.setup} (${group.settings})`;
            const outcome = attempt(() => core.targetFrame(data.actions[op], context));
            checkOutcome(label, outcome, Array.isArray(expected) ? {frame: expected} : expected, 'frame', compare(['x', 'y', 'width', 'height']));
          }
        }
      },
      targetOrigin() {
        for (const group of data.targetOrigin) {
          const context = contextOf(group);
          for (const [op, expected] of Object.entries(group.results)) {
            const label = `${op} from ${group.window} on ${group.setup} (${group.settings}) at ${show(group.actualSize)}`;
            const outcome = attempt(() => core.targetOrigin(data.actions[op], context, group.actualSize));
            checkOutcome(label, outcome, Array.isArray(expected) ? {origin: expected} : expected, 'origin', compare(['x', 'y']));
          }
        }
      },
    };
  },

  'slate-config.json': (data) => ({
    parse() {
      for (const c of data.parse) {
        countCheck();
        const files = c.files;
        const result = core.parseSlateConfig(c.text, {
          path: c.path,
          homeDirectory: c.home,
          readFile: (p) => (Object.prototype.hasOwnProperty.call(files, p) ? files[p] : null),
        });
        const expected = revive(c.result);
        const descriptions = expected.diagnostics.map((d) => d.description);
        expected.diagnostics = expected.diagnostics.map(({description, ...rest}) => rest);
        expectEqual(result, expected, c.name);
        expectEqual(result.diagnostics.map(describeDiagnostic), descriptions, `${c.name} (descriptions)`);
      }
    },
    stripComment() {
      for (const c of data.stripComment) {
        countCheck();
        expectEqual(stripComment(c.input), c.output, show(c.input));
      }
    },
    stableUUID() {
      for (const c of data.stableUUID) {
        countCheck();
        expectEqual(stableUUID(c.name), c.uuid, show(c.name.slice(0, 40)));
      }
    },
  }),

  'config.json': (data) => ({
    decode() {
      for (const c of data.decode) checkConfigFiles(c);
    },
    files() {
      for (const c of data.files) checkConfigFiles(c);
    },
  }),

  'starter.json': (data) => ({
    bindings() {
      countCheck();
      const starter = core.starterConfiguration();
      const files = core.encodeConfigurationFiles(starter);
      expectEqual(files.config.replace(UUID, 'RANDOM-UUID'), data.encoded, 'starter configuration (config.json)');
      expectEqual(files.settings, data.encodedSettings, 'starter configuration (settings.json)');
      expectEqual(new Set(starter.bindings.map((b) => b.id)).size, 21, 'distinct random ids');
      for (const [i, b] of data.bindings.entries()) {
        countCheck();
        const actual = starter.bindings[i];
        expectEqual(actual?.name, b.name, `name ${i}`);
        expectEqual(actual?.keys, b.keys, `keys ${b.name}`);
        expectEqual(actual?.action, b.action, `action ${b.name}`);
        expectEqual(core.formatOperation(actual?.action), b.format, `format ${b.name}`);
      }
    },
  }),

  'settings.json': (data) => ({
    fromSlate() {
      for (const c of data.fromSlate) {
        countCheck();
        expectEqual(settingFromSlate(c.input), revive(c.value), show(c.input));
      }
    },
    accessors() {
      for (const c of data.accessors) {
        countCheck();
        const value = revive(c.value);
        expectEqual(settingBool(value), c.bool, `bool ${show(value)}`);
        expectEqual(settingDouble(value), revive(c.double), `double ${show(value)}`);
        expectEqual(settingString(value), c.string, `string ${show(value)}`);
      }
    },
    typed() {
      for (const c of data.typed) {
        countCheck();
        const s = readSettings(revive(c.settings));
        for (const key of Object.keys(c)) {
          if (key !== 'settings') expectEqual(s[key], c[key], `${key} for ${show(c.settings)}`);
        }
      }
    },
  }),

  'hotstrings.json': (data) => ({
    matcher() {
      for (const session of data.matcher) {
        countCheck();
        const m = new core.HotstringMatcher(session.hotstrings);
        session.steps.forEach((step, i) => {
          if (step.backspace) return m.backspace();
          if (step.reset) return m.reset();
          if (step.update) return m.update(step.update);
          const match = m.feed(step.feed, step.app);
          const actual =
            match === null
              ? null
              : {id: match.hotstring.id, trigger: match.hotstring.trigger, deleteCount: match.deleteCount, delimiter: match.delimiter};
          expectEqual(actual, step.match, `${session.name}, step ${i} (${show(step.feed)})`);
        });
      }
    },
    isDelimiter() {
      for (const c of data.isDelimiter) {
        countCheck();
        expectEqual(isDelimiter(c.character), c.delimiter, show(c.character));
        expectEqual(core.HotstringMatcher.isDelimiter(c.character), c.delimiter, `static ${show(c.character)}`);
      }
    },
    templates() {
      for (const c of data.templates) {
        countCheck();
        const result = core.expandTemplate(c.text, {now: c.now * 1000, clipboard: c.clipboard, locale: data.locale, timeZone: data.timeZone});
        expectEqual(result, c.result, `${show(c.text)} at ${c.date}`);
      }
    },
  }),

  'automation.json': (data) => ({
    syntheticInputs() {
      for (const c of data.syntheticInputs) {
        countCheck();
        const input = core.parseSyntheticInput(c.input);
        expectEqual(input === null ? null : core.formatSyntheticInput(input), c.string, show(c.input));
      }
    },
    repeatSchedule() {
      for (const c of data.repeatSchedule) {
        countCheck();
        const [interval, jitter] = [revive(c.interval), revive(c.jitter)];
        const label = `RepeatSchedule(${show(interval)}, ${show(c.times)}, ${show(jitter)})`;
        const schedule = new core.RepeatSchedule({interval, times: c.times, jitter});
        expectEqual({interval: schedule.interval, times: schedule.times, jitter: schedule.jitter}, revive(c.normalized), label);
        for (const {runs, again} of c.shouldRunAgain) expectEqual(schedule.shouldRunAgain(runs), again, `${label}.shouldRunAgain(${runs})`);
        for (const {random, wait} of c.nextInterval) {
          expectEqual(schedule.nextInterval(revive(random)), revive(wait), `${label}.nextInterval(${show(revive(random))})`);
        }
      }
    },
    isAutomation() {
      for (const c of data.isAutomation) {
        countCheck();
        expectEqual(core.isAutomation(c.action), c.isAutomation, show(c.action));
        expectEqual(core.decodeAction(c.action).op, c.name, `name of ${show(c.action)}`);
      }
    },
  }),

  'clipboard.json': (data) => {
    const itemsOf = (history) =>
      history.items.map((i) => ({
        text: i.text, app: i.sourceApp, copiedAt: i.copiedAt, pinned: i.pinned, ...(i.image ? {image: i.image} : {}),
        ...(i.files ? {files: i.files} : {}),
      }));
    let counter = 0;
    const newId = () => `00000000-0000-4000-8000-${String(++counter).padStart(12, '0')}`;
    /** Items listed in a fixture (no ids) as history items, with made-up ids. */
    const fromFixture = (items) =>
      new core.ClipboardHistory(
        items.map((i) => ({id: newId(), text: i.text, copiedAt: i.copiedAt, sourceApp: i.app, pinned: i.pinned, image: i.image, files: i.files})),
        {newId},
      );
    return {
      sessions() {
        for (const session of data.sessions) {
          countCheck();
          const history = fromFixture(session.start);
          // Steps name items by text, images by file (files items by their text, the names).
          const idOf = (key) => history.items.find((i) => (i.image ? i.image.file === key : i.text === key))?.id;
          session.steps.forEach((step, i) => {
            const label = `${session.name}, step ${i}`;
            if (step.add) {
              const added = history.add(step.add.text, {app: step.add.app, at: step.add.at, limit: step.add.limit});
              expectEqual(added, step.added, `${label}: add ${show(step.add.text)}`);
            } else if (step.addImage) {
              const {image, app, at, limit} = step.addImage;
              expectEqual(history.addImage(image, {app, at, limit}), step.added, `${label}: add image ${show(image.file)}`);
            } else if (step.addFiles) {
              const {files, app, at, limit} = step.addFiles;
              expectEqual(history.addFiles(files, {app, at, limit}), step.added, `${label}: add files ${show(files)}`);
            } else if (step.enforce !== undefined) history.enforce(step.enforce);
            else if (step.prune) history.prune(step.prune.days, step.prune.now);
            else if (step.remove !== undefined) history.remove(idOf(step.remove));
            else if (step.togglePin !== undefined) history.togglePin(idOf(step.togglePin));
            else if (step.removeUnknown) history.remove('00000000-0000-4000-8000-000000000999');
            else if (step.togglePinUnknown) history.togglePin('00000000-0000-4000-8000-000000000999');
            else if (step.clear !== undefined) history.clear(step.clear === 'default' ? undefined : {keepPinned: step.clear});
            else if (step.search !== undefined) {
              expectEqual(history.search(step.search).map((item) => item.text), step.results, `${label}: search ${show(step.search)}`);
            } else fail(`${label}: unknown step ${show(step)}`);
            expectEqual(itemsOf(history), step.items, `${label} (items)`);
          });
          expect(new Set(history.items.map((i) => i.id)).size === history.items.length, `${session.name}: ids stay unique`);
        }
      },
      search() {
        const history = fromFixture(data.searchItems);
        for (const c of data.search) {
          countCheck();
          expectEqual(history.search(c.query).map((item) => item.text), c.results, `search ${show(c.query)}`);
        }
      },
      fileNames() {
        for (const c of data.fileNames) {
          countCheck();
          expectEqual(core.fileDisplayName(c.path), c.name, `name of ${show(c.path)}`);
        }
      },
      coding() {
        for (const c of data.coding) {
          const outcome = attempt(() => core.ClipboardHistory.fromJSON(JSON.parse(c.json)).toJSON());
          checkOutcome(c.json, outcome, c, 'history');
        }
      },
    };
  },
  'placement.json': (data) => {
    const {PopupPlacement} = core;
    const gap = (c) => (c.gap === undefined ? [] : [c.gap]);
    const screensOf = (name) =>
      data.screenSets[name].map((frame, i) => ({displayID: i + 1, name: `S${i + 1}`, frame, visibleFrame: frame, isMain: i === 0, scale: 1}));
    return {
      below() {
        for (const c of data.below) {
          countCheck();
          const result = PopupPlacement.below(c.anchor, c.size, data.visibleFrames[c.visible], ...gap(c));
          expectEqual(result, c.result, `below ${show(c.anchor)}, ${show(c.size)} on ${c.visible}`);
        }
      },
      beside() {
        for (const c of data.beside) {
          countCheck();
          const result = PopupPlacement.beside(c.target, c.row, c.size, data.visibleFrames[c.visible], ...gap(c));
          expectEqual(result, c.result, `beside ${show(c.target)}, row ${show(c.row)}, ${show(c.size)} on ${c.visible}`);
        }
      },
      clamp() {
        for (const c of data.clamp) {
          countCheck();
          expectEqual(PopupPlacement.clamp(c.rect, c.bounds), c.result, `clamp ${show(c.rect)} to ${show(c.bounds)}`);
        }
      },
      screen() {
        for (const c of data.screen) {
          countCheck();
          expectEqual(PopupPlacement.screen(c.anchor, screensOf(c.screens))?.name ?? null, c.screen, `${show(c.anchor)} on ${c.screens}`);
        }
      },
      isUsable() {
        for (const c of data.isUsable) {
          countCheck();
          const rect = revive(c.rect);
          const usable = PopupPlacement.isUsable(rect, data.usableScreens[c.screens], {maxHeight: revive(c.maxHeight)});
          expectEqual(usable, c.usable, `${show(rect)} (max height ${show(revive(c.maxHeight))}) on ${c.screens}`);
        }
      },
    };
  },
};


/** Regions are fractions computed from window math: equal within rounding. */
function sameRegion(actual, expected) {
  if (actual === null || expected === null) return actual === expected;
  return ['x', 'y', 'width', 'height'].every((k) => Math.abs(actual[k] - expected[k]) < 1e-9);
}

/** A cheat sheet item with only the fields Swift records (the port adds keys and extraModifiers). */
const swiftItem = (item) => ({id: item.id, label: item.label, title: item.title, region: item.region, symbol: item.symbol});

function checkSheet(label, actual, expected) {
  const strip = (sheet) => ({...sheet, sections: sheet.sections.map((s) => ({title: s.title, items: s.items.map(swiftItem)}))});
  const a = strip(actual);
  const regionsMatch = a.sections.every((s, i) => s.items.every((item, j) => sameRegion(item.region, expected.sections[i]?.items[j]?.region ?? null)));
  const withoutRegions = (sheet) => ({...sheet, sections: sheet.sections.map((s) => ({...s, items: s.items.map((i) => ({...i, region: null}))}))});
  expectEqual(withoutRegions(a), withoutRegions(expected), label);
  expect(regionsMatch, `${label}: regions differ: ${show(a.sections.map((s) => s.items.map((i) => i.region)))}`);
}

checkers['cheatsheet.json'] = (data) => ({
  actions() {
    for (const c of data.actions) {
      countCheck();
      const sheet = core.hyperCheatSheet([{keys: 'hyper+a', action: c.action}], ['ctrl', 'alt', 'shift', 'cmd']);
      const item = sheet.sections[0]?.items[0];
      const label = show(c.action);
      expectEqual({title: item?.title, section: sheet.sections[0]?.title, symbol: item?.symbol}, {title: c.title, section: c.section, symbol: c.symbol}, label);
      expect(sameRegion(item?.region ?? null, c.region), `${label}: region ${show(item?.region)}, expected ${show(c.region)}`);
    }
  },
  names() {
    for (const c of data.names) {
      countCheck();
      const sheet = core.hyperCheatSheet([c.shortcut]);
      const item = sheet.sections[0]?.items[0];
      expectEqual({title: item?.title, section: sheet.sections[0]?.title, symbol: item?.symbol}, {title: c.title, section: c.section, symbol: c.symbol}, show(c.shortcut));
    }
  },
  sheets() {
    for (const c of data.sheets) {
      countCheck();
      const sheet = c.modal ? core.modalCheatSheet(c.modal, c.shortcuts) : core.hyperCheatSheet(c.shortcuts, c.hyperModifiers);
      checkSheet(c.name, sheet, c.sheet);
    }
  },
});

/** Registers one test per fixture section, plus a manifest check, reading files with `readText`. */
export function registerFixtureTests(fixturesDir, readText) {
  const manifest = JSON.parse(readText(`${fixturesDir}/manifest.json`));
  const files = {};
  for (const name of Object.keys(manifest.files)) files[name] = JSON.parse(readText(`${fixturesDir}/${name}`));

  test('fixtures: manifest lists only files the runner checks', () => {
    for (const [name, sections] of Object.entries(manifest.files)) {
      if (!checkers[name]) fail(`no checks for ${name}`);
      else {
        const known = Object.keys(checkers[name](files[name], files));
        for (const section of Object.keys(sections)) if (!known.includes(section)) fail(`no checks for ${name} › ${section}`);
        for (const [section, count] of Object.entries(sections)) {
          if (files[name][section]?.length !== count) fail(`${name} › ${section}: manifest says ${count} cases`);
        }
      }
    }
    for (const name of Object.keys(checkers)) if (!manifest.files[name]) fail(`${name} is missing from the manifest`);
  });

  for (const [name, sections] of Object.entries(manifest.files)) {
    if (!checkers[name]) continue;
    const sectionChecks = checkers[name](files[name], files);
    for (const section of Object.keys(sections)) {
      if (sectionChecks[section]) test(`${name} › ${section}`, () => sectionChecks[section]());
    }
  }
}
