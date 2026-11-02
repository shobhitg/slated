// The move from version 1's single config.json to config.json + settings.json (lib/prefs/migration.js),
// first runs, and the one-time notice, on in-memory files.

import {suite, expect, expectEqual, readText} from './harness.mjs';
import {
  loadConfigFiles, findSlateFiles, migrationNotice, importedText, changedFiles, parseRecord,
} from '../../gnome-extension/lib/prefs/migration.js';
import {decodeConfigurationFiles, starterConfiguration} from '../../gnome-extension/lib/core/index.js';
import {PrefsModel} from '../../gnome-extension/lib/prefs/model.js';
import {memoryIO, writtenPaths, HOME, CONFIG, SETTINGS, BACKUP, RECORD, SLATE_JS, SLATE} from './memoryio.mjs';

const author = await readText('./fixtures/slate-author-like.js', import.meta.url);

const testId = n => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const half = {op: 'move', x: 'screenOriginX', y: 'screenOriginY', width: 'screenSizeX/2', height: 'screenSizeY'};

/** Version 1's config.json as the Mac app wrote it: everything in one file, Slate files loading. */
function legacy({general = {}, extra = {}} = {}) {
  return JSON.stringify({
    version: 1,
    general: {launchAtLogin: false, loadSlateConfigs: true, slateConfigPaths: ['~/.slate.js', '~/.slate'], showActionHUD: true,
      hotstringsEnabled: true, ...general},
    settings: {secondsBeforeRepeat: 0.2},
    keyboard: {capsLock: 'hyper', capsLockAlone: 'escape'},
    bindings: [{id: testId(1), keys: 'hyper+a', name: 'Mine', action: {op: 'undo'}}],
    hotstrings: [{id: testId(2), trigger: ';sig', replacement: 'Best'}],
    clipboard: {maxItems: 50},
    island: {cheatSheetDelay: 0.8},
    automation: {maxRunMinutes: 5},
    ...extra,
  }, null, 2);
}

function run(files, options = {}) {
  const disk = {...files};
  const writes = [];
  const logged = [];
  let n = 100;
  const io = memoryIO(disk, writes);
  const result = loadConfigFiles(io, {by: 'test', makeId: () => testId(n++), log: (event, data, level) => logged.push({event, data, level}),
    now: () => new Date('2026-10-29T12:00:00Z'), ...options});
  return {result, disk, writes, logged, io};
}

const files = disk => decodeConfigurationFiles(disk[CONFIG], disk[SETTINGS] ?? null);

export default suite('Config files and migration', [
  ['a version 1 config.json with settings sections and ~/.slate.js becomes two files, with the Slate shortcuts imported', () => {
    const original = legacy();
    const {result, disk, writes, logged} = run({[CONFIG]: original, [SLATE_JS]: author});
    expectEqual(writtenPaths(writes), ['.config/slated/config.v1.json', '.config/slated/settings.json', '.config/slated/config.json',
      '.local/state/slated/config-migration.json'], 'backup, settings.json, then config.json, then the record');
    expectEqual(disk[BACKUP], original, 'the backup is the file as it was');
    expect(result.migrated && !result.error && !result.writeError);
    const config = JSON.parse(disk[CONFIG]);
    const settings = JSON.parse(disk[SETTINGS]);
    expectEqual(Object.keys(config).sort(), ['bindings', 'defaults', 'hotstrings', 'keyboard', 'layouts', 'version']);
    expectEqual(Object.keys(settings).sort(), ['automation', 'clipboard', 'general', 'island', 'version', 'windows']);
    expectEqual([config.version, settings.version], [2, 2]);
    expectEqual(settings.general, {hotstringsEnabled: true, launchAtLogin: false, showActionHUD: true, showStatusIcon: true, showConfigKeys: true}, 'no Slate loading keys');
    expectEqual([settings.windows.secondsBeforeRepeat, settings.clipboard.maxItems, settings.island.cheatSheetDelay, settings.automation.maxRunMinutes],
      [0.2, 50, 0.8, 5], '`settings` became `windows`; the other sections moved as they were');
    expectEqual(config.keyboard.capsLockAlone, 'escape', 'the Hyper key stays in config.json');
    expectEqual(config.hotstrings[0].trigger, ';sig', 'and the hotstrings');
    // hyper+a was Slated's own: it stays, and the Slate file's hyper+a is skipped.
    expectEqual(config.bindings[0], {action: {op: 'undo'}, enabled: true, id: testId(1), keys: 'hyper+a', name: 'Mine'});
    expectEqual(config.bindings.length, 21, "the Slate file's 20 other shortcuts, imported");
    expectEqual(config.bindings.filter(b => b.keys === 'hyper+a').length, 1);
    const migrated = logged.find(e => e.event === 'config.migrated');
    expectEqual(migrated.data, {by: 'test', from: 1, to: 2, settingsMoved: true, settingsKept: false, backup: true,
      slate: {files: 1, imported: 20, skipped: 1, unconvertible: 0}}, 'counts only');
    expect(!JSON.stringify(logged).includes('Best') && !JSON.stringify(logged).includes('screenSizeX'), 'never content');
    const record = parseRecord(disk[RECORD]);
    expectEqual([record.kind, record.settingsMoved, record.slate.files, record.slate.imported, record.noticeDismissed],
      ['migration', true, ['~/.slate.js'], 20, false]);
    expectEqual(result.configuration, files(disk).configuration, 'what was written is what is in memory');
  }],
  ['an existing settings.json wins over version 1 sections, and is only rewritten when the import adds to it', () => {
    const settings = JSON.stringify({version: 2, island: {enabled: false}, general: {showActionHUD: false}});
    const {disk, writes, logged} = run({[CONFIG]: legacy(), [SETTINGS]: settings});
    expectEqual(disk[SETTINGS], settings, 'kept as it was');
    expectEqual(writtenPaths(writes), ['.config/slated/config.v1.json', '.config/slated/config.json']);
    const read = files(disk).configuration;
    expectEqual([read.island.enabled, read.island.cheatSheetDelay, read.general.showActionHUD, read.windows, read.clipboard.maxItems],
      [false, 0.5, false, {}, 200], "the legacy sections are dropped; settings.json's values and defaults count");
    expectEqual(logged.find(e => e.event === 'config.migrated').data.settingsKept, true);
    // A Slate file that sets window settings adds them to settings.json, which is written then.
    const slateSettings = run({[CONFIG]: legacy(), [SETTINGS]: settings, [SLATE]: 'config defaultToCurrentScreen true\nbind b:ctrl undo'});
    expectEqual(JSON.parse(slateSettings.disk[SETTINGS]).windows, {defaultToCurrentScreen: true});
    expectEqual(JSON.parse(slateSettings.disk[SETTINGS]).island.enabled, false);
  }],
  ['migrating is idempotent: the next load reads version 2 and writes nothing', () => {
    const first = run({[CONFIG]: legacy(), [SLATE_JS]: author});
    const second = run(first.disk);
    expectEqual(second.writes, [], 'nothing written');
    expect(!second.result.migrated && !second.result.created);
    expectEqual(second.result.configuration, first.result.configuration);
    expectEqual(second.logged, []);
  }],
  ['config.v1.json is never overwritten', () => {
    const {disk, result} = run({[CONFIG]: legacy(), [BACKUP]: 'an older copy'});
    expectEqual(disk[BACKUP], 'an older copy');
    expect(result.migrated, 'the migration still happens');
    expectEqual(parseRecord(disk[RECORD]), null, 'no Slate file: nothing to tell');
  }],
  ['a file that does not parse is not migrated, and nothing is written', () => {
    for (const [name, disk, file] of [
      ['broken config.json', {[CONFIG]: '{"version": 1, "general": {', [SLATE_JS]: author}, 'config.json'],
      ['invalid config.json', {[CONFIG]: legacy({extra: {bindings: [{keys: 'hyper+a', action: {op: 'teleport'}}]}})}, 'config.json'],
      ['broken settings.json', {[CONFIG]: legacy(), [SETTINGS]: '{"island": '}, 'settings.json'],
    ]) {
      const run1 = run(disk);
      expectEqual(run1.writes, [], `${name}: nothing written, not even the backup`);
      expectEqual(run1.result.error?.file, file, `${name}: says which file`);
    }
    const unreadable = run({[CONFIG]: legacy()}, {});
    unreadable.io.readSettings = () => {
      throw new Error('permission denied');
    };
    const result = loadConfigFiles(unreadable.io, {log: () => {}});
    expectEqual([result.error.file, result.error.message], ['settings.json', "Couldn't read settings.json: permission denied"]);
  }],
  ['the Slate merge rule: triggers Slated has win, earlier imports stay out, and loading turned off imports nothing', () => {
    const slate = 'bind a:ctrl,alt,shift,cmd undo\nbind b:ctrl,alt,shift,cmd hint\nbind c:ctrl,alt,shift,cmd undo\nbind d:ctrl undo';
    const general = {importedSlateShortcuts: ['hyper+c'], slateConfigPaths: ['~/.slate']};
    const extra = {bindings: [
      {id: testId(1), keys: 'hyper+a', action: half},
      {id: testId(3), keys: 'ctrl+d', action: half, onlyInApps: ['steam_app_1']},
    ]};
    const {disk, logged} = run({[CONFIG]: legacy({general, extra}), [SLATE]: slate});
    const keys = JSON.parse(disk[CONFIG]).bindings.map(b => `${b.keys}${b.onlyInApps ? ' (app)' : ''}`);
    expectEqual(keys, ['hyper+a', 'ctrl+d (app)', 'hyper+b', 'ctrl+d'], "hyper+a is Slated's; hyper+c was imported before; ctrl+d in an app is another trigger");
    expectEqual(logged.find(e => e.event === 'config.migrated').data.slate, {files: 1, imported: 2, skipped: 2, unconvertible: 0});
    const off = run({[CONFIG]: legacy({general: {loadSlateConfigs: false}}), [SLATE_JS]: author});
    expectEqual(JSON.parse(off.disk[CONFIG]).bindings.length, 1, 'loadSlateConfigs false: no import');
    expectEqual(off.logged.find(e => e.event === 'config.migrated').data.slate, null);
    const none = run({[CONFIG]: legacy({general: {slateConfigPaths: []}}), [SLATE_JS]: author});
    expectEqual(JSON.parse(none.disk[CONFIG]).bindings.length, 1, 'no paths: version 1 loaded nothing, so nothing is imported');
    // Without slateConfigPaths: ~/.slate.js, else ~/.slate.
    const io = memoryIO({[SLATE_JS]: 'x', [SLATE]: 'y'});
    expectEqual(findSlateFiles(io).map(f => f.displayPath), ['~/.slate.js']);
    expectEqual(findSlateFiles(memoryIO({[SLATE]: 'y'})).map(f => f.displayPath), ['~/.slate']);
    expectEqual(findSlateFiles(io, ['~/.slate', '~/.nope']).map(f => [f.displayPath, f.kind]), [['~/.slate', 'classic']]);
  }],
  ['what a migration couldn\'t convert is named by its keys, and the notice says so once', () => {
    const script = 'slate.bind("a:ctrl,alt,shift,cmd", slate.operation("push", {"direction": "left"}));\n'
      + 'slate.bind("x:ctrl,alt,shift,cmd", function (win) { win.move({"x": 1, "y": 2, "width": 3, "height": 4}); win.move({"x": 5, "y": 6, "width": 7, "height": 8}); });\n';
    const {disk} = run({[CONFIG]: legacy({extra: {bindings: []}}), [SLATE_JS]: script});
    const record = parseRecord(disk[RECORD]);
    expectEqual(record.slate.unconvertible.map(u => [u.keys, u.modal]), [['hyper+x', null]]);
    expect(!JSON.stringify(record).includes('function') && !JSON.stringify(record).includes('width'), 'never the script');
    const notice = migrationNotice(record, {configPath: '~/.config/slated/config.json'});
    expectEqual(notice.text, "Your ~/.slate.js shortcuts are now part of Slated's config. Slated doesn't read ~/.slate.js any more: "
      + 'edit them here or in ~/.config/slated/config.json.');
    expectEqual(notice.unconvertible, "1 couldn't be converted: ✦ X.");
    expectEqual(notice.items[0].reason, 'uses win.move, which needs the script');
    expectEqual(migrationNotice({...record, noticeDismissed: true}), null, 'dismissed: never again');
    expectEqual(migrationNotice({...record, kind: 'first-run'}), null, 'a first run says it in Get Started');
    expectEqual(migrationNotice({...record, slate: null}), null, 'no Slate import: nothing to say');
    expect(importedText(record).startsWith('Slated imported 1 shortcut from ~/.slate.js.'), importedText(record));
    // The settings window shows it until dismissed, and remembers that in the record.
    const model = new PrefsModel({io: memoryIO(disk), log: () => {}});
    model.load();
    expectEqual(model.migrationNotice('~/.config/slated/config.json')?.unconvertible, "1 couldn't be converted: ✦ X.");
    model.dismissMigrationNotice();
    expectEqual(model.migrationNotice('~/.config/slated/config.json'), null);
    expectEqual(parseRecord(disk[RECORD]).noticeDismissed, true);
    const reopened = new PrefsModel({io: memoryIO(disk), log: () => {}});
    reopened.load();
    expectEqual(reopened.migrationNotice('~/.config/slated/config.json'), null, 'still dismissed in the next window');
    // A later migration that imports nothing new doesn't bring it back.
    disk[CONFIG] = legacy({extra: {bindings: JSON.parse(disk[CONFIG]).bindings}});
    run(disk);
    expectEqual(parseRecord(disk[RECORD]).noticeDismissed, true);
  }],
  ['first run: the Slate config imported, else the starter set; both files written; a settings.json there is kept', () => {
    const slate = run({[SLATE_JS]: author});
    expectEqual(writtenPaths(slate.writes), ['.config/slated/settings.json', '.config/slated/config.json', '.local/state/slated/config-migration.json']);
    expectEqual(files(slate.disk).configuration.bindings.length, 21);
    expectEqual(files(slate.disk).configuration.keyboard.capsLock, 'off', 'the import keeps the default keyboard');
    expectEqual(parseRecord(slate.disk[RECORD]).kind, 'first-run');
    expectEqual(slate.logged.map(e => [e.event, e.data.from]), [['config.created', 'Slate config']]);
    const fresh = run({});
    const starter = starterConfiguration();
    expectEqual(files(fresh.disk).configuration.bindings.map(b => b.keys), starter.bindings.map(b => b.keys));
    expectEqual(files(fresh.disk).configuration.keyboard.capsLock, 'hyper');
    expectEqual(fresh.disk[RECORD], undefined, 'nothing to tell');
    const kept = '{"version": 2, "island": {"enabled": false}, "future": true}';
    const withSettings = run({[SETTINGS]: kept});
    expectEqual(withSettings.disk[SETTINGS], kept, 'settings.json is left as it was');
    expectEqual(writtenPaths(withSettings.writes), ['.config/slated/config.json']);
    expectEqual(withSettings.result.configuration.island.enabled, false);
    expect(run({}, {}).result.created, 'created');
    const failing = run({__failWrites: true});
    expect(failing.result.created && failing.result.writeError, 'a failed write is reported with what would have been written');
  }],
  ['a save writes only the file whose content changed', () => {
    const before = decodeConfigurationFiles('{"version": 2}', null).configuration;
    const island = {...before, island: {...before.island, enabled: false}};
    const binding = {...before, bindings: [{id: testId(1), keys: 'hyper+a', action: half, enabled: true}]};
    expectEqual([changedFiles(before, island).config, changedFiles(before, island).settings], [false, true]);
    expectEqual([changedFiles(before, binding).config, changedFiles(before, binding).settings], [true, false]);
    expectEqual([changedFiles(before, before).config, changedFiles(before, before).settings], [false, false]);
    expectEqual(HOME, '/home/me');
  }],
]);
