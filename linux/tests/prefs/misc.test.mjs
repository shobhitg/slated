import {suite, expect, expectEqual} from './harness.mjs';
import {formatEvent, parseEvents, lastStart, sanitize} from '../../gnome-extension/lib/prefs/eventlog.js';
import {expandTyping, espansoGuidance, isDelimiter, gnomeScopeNote} from '../../gnome-extension/lib/prefs/hotstrings.js';
import {formatList, plural, truncate, tildify, expandHome, uuid, sessionId, Emitter, editDistance, escapeMarkup} from '../../gnome-extension/lib/prefs/util.js';

const hotstring = fields => ({trigger: ';s', replacement: '¯\\_(ツ)_/¯', caseSensitive: true, fire: 'immediately', wordBoundary: false, ...fields});

export default suite('Event log, hotstrings and helpers', [
  ['log lines use the macOS format: sorted keys, ISO time, session', () => {
    const line = formatEvent('ui.pane', {session: 'abcd1234', data: {pane: 'windows', ratio: 0.333}, now: new Date('2026-10-22T18:00:00.123Z')});
    expectEqual(line, '{"data":{"pane":"windows","ratio":0.3},"event":"ui.pane","level":"info","session":"abcd1234","ts":"2026-10-22T18:00:00.123Z"}\n');
    expectEqual(formatEvent('ui.reload', {session: 's', now: new Date(0)}), '{"event":"ui.reload","level":"info","session":"s","ts":"1970-01-01T00:00:00.000Z"}\n');
    expectEqual(JSON.parse(formatEvent('x', {session: 's', level: 'bogus'})).level, 'info');
    expectEqual(sanitize({a: [1, 2.25, Infinity], b: undefined, c: new Error('e')}), {a: [1, 2.3, 'Infinity'], c: 'e'});
  }],
  ['finds the running build in the log', () => {
    const log = [
      '{"data":{"commit":"aaa"},"event":"app.start","level":"notice","session":"one","ts":"1"}',
      'garbage',
      '{"data":{"commit":"bbb"},"event":"app.start","level":"notice","session":"two","ts":"2"}',
      '{"event":"ui.pane","session":"two","ts":"3"}',
      '{"data":{"commit":"ccc"},"event":"app.st',
    ].join('\n');
    expectEqual(parseEvents(log).length, 3);
    expectEqual(lastStart(log).data.commit, 'bbb');
    expectEqual(lastStart(log, 'one').data.commit, 'aaa');
    expectEqual(lastStart(log, 'three'), null);
  }],
  ['the try-it field expands like the engine', () => {
    expectEqual(expandTyping('hi ;', 'hi ;s', hotstring()), 'hi ¯\\_(ツ)_/¯');
    expectEqual(expandTyping('hi ;', 'hi ;S', hotstring()), null, 'case-sensitive by default');
    expectEqual(expandTyping('hi ;', 'hi ;S', hotstring({caseSensitive: false})), 'hi ¯\\_(ツ)_/¯');
    const brb = hotstring({trigger: 'brb', replacement: 'be right back', fire: 'afterDelimiter', wordBoundary: true});
    expectEqual(expandTyping('ok brb', 'ok brb.', brb), 'ok be right back.');
    expectEqual(expandTyping('ok brb', 'ok brbx', brb), null);
    expectEqual(expandTyping('xbrb', 'xbrb ', brb), null, 'word boundary');
    expectEqual(expandTyping('ab', 'a', hotstring()), null, 'deleting never expands');
    expect(isDelimiter(' ') && isDelimiter('.') && !isDelimiter('é') && !isDelimiter('3'));
  }],
  ['espanso guidance follows status.json', () => {
    expectEqual(espansoGuidance({}, false).level, 'info');
    const missing = espansoGuidance({engine: 'none', espansoInstalled: false}, true);
    expectEqual([missing.level, missing.link], ['warning', 'https://espanso.org/install/linux/']);
    expectEqual(espansoGuidance({engine: 'none', espansoInstalled: true}, true).level, 'warning');
    expectEqual(espansoGuidance({engine: 'espanso', espansoInstalled: true, count: 1, matchFile: '/m.yml'}, true).detail,
      'Slated keeps 1 hotstring in sync with espanso (/m.yml).');
    const stopped = espansoGuidance({engine: 'espanso', espansoInstalled: true, count: 1}, true, false);
    expectEqual([stopped.level, stopped.title, stopped.command], ['warning', "espanso isn't running", 'espanso start']);
    expectEqual(espansoGuidance({engine: 'espanso', espansoInstalled: true, count: 1}, true, null).level, 'ok', 'unknown: no claim');
  }],
  ['app filters are Mac-only: espanso can\'t tell apps apart on GNOME', () => {
    expectEqual(gnomeScopeNote({trigger: ';a', onlyInApps: [], exceptInApps: []}), null);
    expectEqual(gnomeScopeNote(null), null);
    const only = gnomeScopeNote({onlyInApps: ['com.apple.mail', 'com.apple.Notes']});
    expectEqual(only.caption, 'Mac only: in com.apple.mail, com.apple.Notes');
    expect(/doesn't expand here/.test(only.detail), only.detail);
    const except = gnomeScopeNote({exceptInApps: ['com.apple.Terminal']});
    expectEqual(except.caption, 'Everywhere here; not in com.apple.Terminal on the Mac');
    expect(/expands in every app/.test(except.detail), except.detail);
  }],
  ['helpers', () => {
    expectEqual(escapeMarkup(`Unexpected token '<' in "a & b"`), 'Unexpected token &#39;&lt;&#39; in &quot;a &amp; b&quot;');
    expectEqual(escapeMarkup(null), '');
    expectEqual(formatList(['a', 'b', 'c']), 'a, b and c');
    expectEqual(formatList(['a']), 'a');
    expectEqual(plural(1, 'binding'), '1 binding');
    expectEqual(plural(2, 'binding'), '2 bindings');
    expectEqual(truncate('abcdef', 4), 'abc…');
    expectEqual(tildify('/home/me/.slate.js', '/home/me/'), '~/.slate.js');
    expectEqual(expandHome('~/.slate', '/home/me'), '/home/me/.slate');
    expect(/^[0-9A-F]{8}-[0-9A-F]{4}-4[0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}$/.test(uuid()));
    expect(/^[0-9a-f]{8}$/.test(sessionId()));
    expectEqual(editDistance('screnSizeX', 'screenSizeX'), 1);
    const emitter = new Emitter();
    const seen = [];
    const off = emitter.on('x', v => seen.push(v));
    emitter.on('x', () => {
      throw new Error('a broken listener');
    });
    const quiet = globalThis.logError;
    globalThis.logError = () => {};
    emitter.emit('x', 1);
    off();
    emitter.emit('x', 2);
    globalThis.logError = quiet;
    expectEqual(seen, [1], 'listeners can unsubscribe, and a failing one does not stop the rest');
  }],
]);
