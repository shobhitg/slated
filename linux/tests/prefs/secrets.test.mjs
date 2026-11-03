// Sensitive hotstrings in the settings window: secrets.json beside config.json, edited through the
// model (the Sensitive switch, the masked field, a missing text), saved in a safe order, hand edits and
// conflicts, a broken file that quotes nothing, the validator and Overview; and the shared loader
// (migration.js) that the extension uses too.

import {suite, expect, expectEqual} from './harness.mjs';
import {PrefsModel, savableSecrets} from '../../gnome-extension/lib/prefs/model.js';
import {changedFiles, gainsSecretName, loadConfigFiles, redactedError, writeConfigFiles} from '../../gnome-extension/lib/prefs/migration.js';
import {validate, MISSING_SECRET} from '../../gnome-extension/lib/prefs/validator.js';
import {runningSummary, emptyStatus} from '../../gnome-extension/lib/prefs/status.js';
import {decodeConfiguration} from '../../gnome-extension/lib/prefs/engine.js';
import {memoryIO, CONFIG, SECRETS, writtenPaths} from './memoryio.mjs';
import {appendKey, hotstringKey, keyDisplay, keyPath, secretKey, valueText} from '../../gnome-extension/lib/core/index.js';

const testId = n => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const v2 = object => JSON.stringify({version: 2, ...object});
const PW = testId(0x501);
const BANK = testId(0x502);

function harness(files = {}) {
  const disk = {...files};
  const writes = [];
  const logged = [];
  const timers = new Map();
  let next = 1;
  let n = 0;
  const scheduler = {
    setTimeout: (fn) => {
      const id = next++;
      timers.set(id, fn);
      return id;
    },
    clearTimeout: id => timers.delete(id),
  };
  const model = new PrefsModel({
    io: memoryIO(disk, writes), scheduler, log: (event, data, level) => logged.push({event, data, level}), makeId: () => testId(0x900 + n++),
  });
  const tick = () => {
    for (const [id, fn] of [...timers]) {
      timers.delete(id);
      fn();
    }
  };
  return {model, disk, writes, logged, tick};
}

const json = text => JSON.parse(text);
const plainConfig = v2({hotstrings: [{id: PW, trigger: ';pw', replacement: 'hunter2'}, {id: BANK, trigger: ';bank', replacement: 'plain'}]});

export default suite('Sensitive hotstrings and secrets.json', [
  ['the Sensitive switch moves the text into secrets.json, written first; off moves it back, config.json first', () => {
    const {model, disk, writes, logged, tick} = harness({[CONFIG]: plainConfig});
    model.load();
    model.setHotstringSensitive(PW, true);
    expectEqual(model.hotstring(PW).replacement, {secret: 'pw'});
    expectEqual(model.secrets, {pw: 'hunter2'});
    expectEqual(model.hotstringText(PW), 'hunter2');
    tick();
    expectEqual(writtenPaths(writes), ['.config/slated/secrets.json', '.config/slated/config.json'], 'the text is on disk before config.json refers to it');
    expectEqual(json(disk[SECRETS]), {secrets: {pw: 'hunter2'}, version: 1});
    expect(!disk[CONFIG].includes('hunter2'), 'config.json has the reference only');
    expectEqual(json(disk[CONFIG]).hotstrings[0].replacement, {secret: 'pw'});
    const saved = logged.find(e => e.event === 'config.saved');
    expectEqual(saved.data.files, ['config.json', 'secrets.json']);
    expect(saved.data.changes.includes('secrets: 1'), `a count: ${saved.data.changes}`);
    expect(!JSON.stringify(logged).includes('hunter2') && !JSON.stringify(logged).includes('"pw"'), 'no text, no name in the log');
    expectEqual(logged.filter(e => e.event === 'ui.hotstring_sensitive').map(e => e.data), [{sensitive: true}]);
    // Edits in the masked field go to secrets.json only.
    writes.length = 0;
    model.setHotstringSecretText(PW, 'changed ✓');
    tick();
    expectEqual(writtenPaths(writes), ['.config/slated/secrets.json']);
    expectEqual(json(disk[SECRETS]).secrets.pw, 'changed ✓');
    // Off: the text comes back to config.json before secrets.json lets it go.
    writes.length = 0;
    model.setHotstringSensitive(PW, false);
    tick();
    expectEqual(writtenPaths(writes), ['.config/slated/config.json', '.config/slated/secrets.json']);
    expectEqual(json(disk[CONFIG]).hotstrings[0].replacement, 'changed ✓');
    expectEqual(json(disk[SECRETS]).secrets, {});
    expectEqual(model.saveState.kind, 'saved');
  }],
  ['names come from the trigger and stay unique; a duplicate gets its own secret; deleting forgets an unused one', () => {
    const {model, disk, tick} = harness({[CONFIG]: v2({hotstrings: [{id: PW, trigger: ';pw', replacement: 'one'}, {id: BANK, trigger: ';pw', replacement: 'two'}]})});
    model.load();
    model.setHotstringSensitive(PW, true);
    model.setHotstringSensitive(BANK, true);
    expectEqual(model.configuration.hotstrings.map(h => h.replacement), [{secret: 'pw'}, {secret: 'pw-2'}]);
    const copy = model.duplicateHotstring(PW);
    expectEqual(model.hotstring(copy).replacement, {secret: 'pw2'}, 'its trigger is ";pw2"');
    model.setHotstringSecretText(copy, 'the copy');
    expectEqual([model.hotstringText(PW), model.hotstringText(copy)], ['one', 'the copy'], 'editing the copy leaves the original alone');
    model.deleteHotstring(BANK);
    tick();
    expectEqual(Object.keys(json(disk[SECRETS]).secrets).sort(), ['pw', 'pw2'], 'its secret went with it');
  }],
  ['a missing secret: no text, a warning (still saved), Overview counts it; typing it in fixes it', () => {
    const {model, disk, tick} = harness({[CONFIG]: v2({hotstrings: [{id: PW, trigger: ';pw', replacement: {secret: 'pw'}}]})});
    model.load();
    expect(model.isMissingSecret(PW));
    expectEqual(model.hotstringText(PW), null);
    expectEqual(model.missingSecretCount, 1);
    const issues = model.issuesFor(`hotstring:${PW}`);
    expectEqual(issues.map(i => [i.severity, i.message]), [['warning', MISSING_SECRET]]);
    model.status = {...emptyStatus(), present: true, running: true};
    model.shell = {reachable: true, known: true, enabled: true, state: 'active', userExtensionsEnabled: true};
    const summary = model.summary();
    expectEqual([summary.level, summary.action, summary.title], ['warning', 'hotstrings', 'A hotstring needs its text']);
    model.setHotstringSecretText(PW, 'typed on this computer');
    tick();
    expect(!model.isMissingSecret(PW));
    expectEqual(json(disk[SECRETS]).secrets, {pw: 'typed on this computer'});
    expectEqual(model.missingSecretCount, 0);
    expectEqual(model.summary().level, 'ok');
  }],
  ['hand edits to secrets.json are adopted; with an unsaved edit in it, the banner asks', () => {
    const {model, disk, tick} = harness({
      [CONFIG]: v2({hotstrings: [{id: PW, trigger: ';pw', replacement: {secret: 'pw'}}]}),
      [SECRETS]: '{"version": 1, "secrets": {"pw": "first"}}',
    });
    model.load();
    disk[SECRETS] = '{"version": 1, "secrets": {"pw": "edited by hand"}}';
    model.syncFromDisk();
    expectEqual(model.hotstringText(PW), 'edited by hand');
    expectEqual(model.updatedFromDisk, ['secrets.json']);
    model.setHotstringSecretText(PW, 'unsaved here');
    disk[SECRETS] = '{"version": 1, "secrets": {"pw": "edited again"}}';
    model.syncFromDisk();
    expectEqual(model.conflict, ['secrets.json']);
    expectEqual(model.saveState.kind, 'conflict');
    model.reloadConflictingFiles();
    expectEqual(model.hotstringText(PW), 'edited again', 'the file wins');
    model.setHotstringSecretText(PW, 'mine');
    disk[SECRETS] = '{"version": 1, "secrets": {"pw": "theirs"}}';
    model.syncFromDisk();
    model.keepMyChanges();
    tick();
    expectEqual(json(disk[SECRETS]).secrets.pw, 'mine', 'Keep My Changes writes the window’s');
    // Deleted by hand: the hotstring waits for its text.
    delete disk[SECRETS];
    model.syncFromDisk();
    expect(model.isMissingSecret(PW));
  }],
  ['a broken secrets.json blocks saving and names the file, quoting nothing from it', () => {
    const {model, disk, tick, writes} = harness({
      [CONFIG]: v2({hotstrings: [{id: PW, trigger: ';pw', replacement: {secret: 'pw'}}]}),
      [SECRETS]: '{"secrets": {"pw": 12345}}',
    });
    model.load();
    expectEqual(model.loadErrorFile, 'secrets.json');
    expect(model.loadError.includes('secrets.pw') && !model.loadError.includes('12345'), model.loadError);
    model.update(config => {
      config.general.showActionHUD = true;
    });
    tick();
    expectEqual(model.saveState.kind, 'blocked');
    expectEqual(writes.length, 0, 'nothing written over it');
    disk[SECRETS] = '{"secrets": {"pw": "fixed"}}';
    model.syncFromDisk();
    expectEqual([model.loadError, model.hotstringText(PW)], [null, 'fixed']);
    expectEqual(redactedError("Unexpected character 'h' (at offset 3)", 'secrets.json'), 'Unexpected character (at offset 3)');
    expectEqual(redactedError("Unexpected character 'h'", 'config.json'), "Unexpected character 'h'", 'other files as they are');
  }],
  ['a hotstring held back for an error keeps its saved secret on disk until it can be saved', () => {
    const {model, disk, tick} = harness({[CONFIG]: v2({hotstrings: [{id: PW, trigger: ';pw', replacement: 'hunter2'}]})});
    model.load();
    model.setHotstringSensitive(PW, true);
    tick();
    // Now an error (no trigger), then Sensitive off: the saved, sensitive version is what stays on disk.
    model.setHotstring(PW, h => {
      h.trigger = '';
    });
    model.setHotstringSensitive(PW, false);
    tick();
    expectEqual(json(disk[CONFIG]).hotstrings[0].replacement, {secret: 'pw'}, 'held back');
    expectEqual(json(disk[SECRETS]).secrets, {pw: 'hunter2'}, 'so its text stays');
    expectEqual(savableSecrets({hotstrings: [{replacement: {secret: 'a'}}]}, {}, {a: 'x', b: 'y'}), {a: 'x'});
  }],
  ['the shared loader reads secrets.json, never creates it, and orders the writes', () => {
    const disk = {[CONFIG]: v2({hotstrings: [{id: PW, trigger: ';pw', replacement: {secret: 'pw'}}]}), [SECRETS]: '{"secrets": {"pw": "x"}}'};
    const writes = [];
    const io = memoryIO(disk, writes);
    const loaded = loadConfigFiles(io);
    expectEqual([loaded.secrets, loaded.secretsText], [{pw: 'x'}, '{"secrets": {"pw": "x"}}']);
    expectEqual(writes.length, 0);
    const firstRun = loadConfigFiles(memoryIO({[SECRETS]: '{"secrets": {"a": "b"}}'}, []));
    expectEqual(firstRun.secrets, {a: 'b'}, 'a first run keeps a secrets.json that\'s there');
    const empty = loadConfigFiles(memoryIO({}, writes));
    expectEqual(empty.secrets, {});
    expect(!writtenPaths(writes).includes('.config/slated/secrets.json'), 'a first run never writes it');
    const broken = loadConfigFiles(memoryIO({[CONFIG]: '{}', [SECRETS]: '['}, []));
    expectEqual(broken.error.file, 'secrets.json');
    const failing = memoryIO({[CONFIG]: '{}'}, []);
    failing.readSecrets = () => {
      throw new Error('permission denied');
    };
    expectEqual(loadConfigFiles(failing).error.file, 'secrets.json');
    // Order: a new name first, otherwise last.
    expect(gainsSecretName({}, {a: '1'}) && !gainsSecretName({a: '1'}, {a: '2'}) && !gainsSecretName({a: '1', b: '2'}, {a: '1'}));
    const config = decodeConfiguration('{}');
    const order = [];
    const recording = {writeConfig: () => order.push('config'), writeSettings: () => order.push('settings'), writeSecrets: () => order.push('secrets')};
    writeConfigFiles(recording, config, {}, {config: true, settings: false, secrets: true}, {before: {}, after: {a: '1'}});
    writeConfigFiles(recording, config, {}, {config: true, settings: false, secrets: true}, {before: {a: '1'}, after: {}});
    expectEqual(order, ['secrets', 'config', 'config', 'secrets']);
    expectEqual(changedFiles(config, config, {}, {before: {a: '1'}, after: {a: '1'}}).secrets, false);
    expectEqual(changedFiles(config, config, {}, {before: {}, after: {a: '1'}}).secrets, true);
    expectEqual(changedFiles(config, config, {}).secrets, false, 'without secrets, secrets.json is never written');
  }],
  ['Copy Value on a sensitive hotstring copies its reference; secrets.json\'s keys copy nothing', () => {
    const config = decodeConfiguration(v2({hotstrings: [{id: PW, trigger: ';pw', replacement: {secret: 'pw'}}]}));
    const key = appendKey(hotstringKey(config, 0), 'replacement');
    expectEqual(keyPath(key), 'hotstrings[0].replacement');
    expectEqual(JSON.parse(valueText(config, key)), {secret: 'pw'});
    expectEqual(valueText(config, secretKey('pw')), null, 'never a secret\'s text');
    expectEqual([keyDisplay(secretKey('pw')), keyPath(secretKey('pw'))], ['secrets.json › pw', 'secrets.pw']);
  }],
  ['the validator: a missing secret warns, an empty one warns as an empty replacement, others as before', () => {
    const config = decodeConfiguration(v2({hotstrings: [
      {id: PW, trigger: ';pw', replacement: {secret: 'pw'}}, {id: BANK, trigger: ';bank', replacement: {secret: 'bank'}},
      {id: testId(3), trigger: ';ok', replacement: {secret: 'ok'}},
    ]}));
    const issues = validate(config, {secrets: {bank: '', ok: 'fine'}});
    expectEqual(issues.map(i => [i.target, i.message]), [
      [`hotstring:${PW}`, MISSING_SECRET], [`hotstring:${BANK}`, 'The replacement is empty, so the trigger will just be deleted.'],
    ]);
    expect(issues.every(i => i.severity === 'warning'), 'never an error: the reference is saved');
    expectEqual(runningSummary({status: {...emptyStatus(), present: true, running: true}, shell: {reachable: true, known: true}, missingSecrets: 2}).title,
      'Some hotstrings need their text');
  }],
]);
