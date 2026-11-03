import {suite, expect, expectEqual} from './harness.mjs';
import {
  FILE_LINKS, fileLinkSegments, fileLinkMarkup, keyLinkMarkup, hasUnlinkedFileName, isLinked, linkForFile, linkPath, linkUri,
  missingText, openFileLink, parseLinkUri,
} from '../../gnome-extension/lib/prefs/filelinks.js';
import {slatedPaths} from '../../gnome-extension/lib/prefs/paths.js';

// The same names, links and words as the Mac's FileLink (Tests/SlatedTests/FileLinkTests.swift).
const links = text => fileLinkSegments(text).filter(s => s.link).map(s => `${s.text}=${s.link}`);

export default suite('File links', [
  ['each name in text links to its file, and only on its own', () => {
    expectEqual(links('Updated from config.json and settings.json'), ['config.json=config', 'settings.json=settings']);
    expectEqual(links('edit them here or in ~/.config/slated/config.json.'), ['~/.config/slated/config.json=config']);
    expectEqual(links('These settings are in ~/.config/slated/settings.json;'), ['~/.config/slated/settings.json=settings']);
    expectEqual(links('Open ~/.config/slated/ in Files'), ['~/.config/slated=folder']);
    expectEqual(links('a copy at config.v1.json, beside it'), ['config.v1.json=backup']);
    expectEqual(links('Its text is in secrets.json (~/.config/slated/secrets.json).'), ['secrets.json=secrets', '~/.config/slated/secrets.json=secrets']);
    expectEqual(links('mysecrets.json, secrets.json.bak'), []);
    expectEqual(links('Slated looks for ~/.slate.js, then ~/.slate.'), ['~/.slate.js=slate-js', '~/.slate=slate']);
    expectEqual(links('No ~/.slate or ~/.slate.js here'), ['~/.slate=slate', '~/.slate.js=slate-js']);
    expectEqual(links('myconfig.json, config.jsonc, config.json.bak, ~/.slated, a.settings.json'), []);
    expectEqual(links('~/.config/slated/other.json'), []);
    expectEqual(links('No files named here.'), []);
    const text = '"config.json" (settings.json) — ~/.slate!';
    expectEqual(fileLinkSegments(text).map(s => s.text).join(''), text);
    expectEqual(links(text), ['config.json=config', 'settings.json=settings', '~/.slate=slate']);
  }],
  ['links are slated-file URIs, read back; any other URI isn\'t one', () => {
    for (const link of Object.keys(FILE_LINKS)) expectEqual(parseLinkUri(linkUri(link)), link);
    expectEqual(linkUri('config'), 'slated-file://config');
    for (const other of ['https://config', 'file:///home/me/.config/slated/config.json', 'slated-file://nothing', null]) {
      expectEqual(parseLinkUri(other), null, String(other));
    }
    expectEqual([linkForFile('config.json'), linkForFile('settings.json'), linkForFile('secrets.json')], ['config', 'settings', 'secrets']);
  }],
  ['which name opens which file', () => {
    const paths = slatedPaths('/home/me');
    expectEqual(Object.keys(FILE_LINKS).map(link => linkPath(link, paths)), [
      '/home/me/.config/slated/config.json', '/home/me/.config/slated/settings.json', '/home/me/.config/slated/secrets.json',
      '/home/me/.config/slated/config.v1.json',
      '/home/me/.config/slated', '/home/me/.slate.js', '/home/me/.slate',
    ]);
    expectEqual(Object.values(FILE_LINKS).map(l => l.logName), ['config.json', 'settings.json', 'secrets.json', 'config.v1.json', 'folder', '.slate.js', '.slate']);
    expectEqual(missingText('secrets'), "There's no secrets.json yet. Slated creates it when you make a hotstring Sensitive.");
    expectEqual(missingText('slate-js'), "There's no ~/.slate.js in your home folder.");
    expectEqual(missingText('settings'), "settings.json isn't there yet. Slated creates it the first time it saves a change.");
  }],
  ['markup: names are links with a tooltip, the rest escaped; a key links only its file', () => {
    expectEqual(fileLinkMarkup('Saved in config.json & <b>'),
      'Saved in <a href="slated-file://config" title="Open config.json">config.json</a> &amp; &lt;b&gt;');
    expectEqual(fileLinkMarkup("Slated's \"files\""), "Slated's \"files\"");
    expectEqual(keyLinkMarkup('settings.json › island.enabled'),
      '<a href="slated-file://settings" title="Open settings.json">settings.json</a> › island.enabled');
    expectEqual(keyLinkMarkup('config.json › hotstrings › "config.json"'),
      '<a href="slated-file://config" title="Open config.json">config.json</a> › hotstrings › "config.json"');
    expectEqual(keyLinkMarkup('secrets.json › pw'), '<a href="slated-file://secrets" title="Open secrets.json">secrets.json</a> › pw');
    expectEqual(keyLinkMarkup('trigger'), 'trigger');
    expect(!hasUnlinkedFileName(fileLinkMarkup('Not saved: config.json and settings.json changed on disk')));
    expect(hasUnlinkedFileName('Saved in config.json'));
    expect(hasUnlinkedFileName('<span>settings.json › island.enabled</span>'));
    expect(!hasUnlinkedFileName('Nothing to open'));
  }],
  ['a Slate file is a link only while there\'s a Slate config', () => {
    expect(isLinked('config', {slateFound: false}) && isLinked('folder', {slateFound: false}));
    expect(!isLinked('slate-js', {slateFound: false}) && !isLinked('slate', {slateFound: false}));
    expect(isLinked('slate-js', {slateFound: true}));
    const options = {linked: link => isLinked(link, {slateFound: false})};
    expectEqual(fileLinkMarkup('No ~/.slate or ~/.slate.js here', options), 'No ~/.slate or ~/.slate.js here');
    expect(!hasUnlinkedFileName('No ~/.slate or ~/.slate.js here', options));
  }],
  ['opening: the pending edit is saved, the file launched and logged by name; a missing one says so', () => {
    const paths = slatedPaths('/home/me');
    const present = new Set([paths.configFile, paths.configDir]);
    const calls = [];
    const io = {
      paths, exists: p => present.has(p), launch: p => calls.push(`launch ${p}`), toast: m => calls.push(`toast ${m}`),
      log: (event, data) => calls.push(`${event} ${JSON.stringify(data)}`), saveNow: () => calls.push('save'),
    };
    expectEqual(openFileLink('config', io), 'default');
    expectEqual(openFileLink('folder', io), 'files');
    expectEqual(openFileLink('slate', io), 'missing');
    expectEqual(openFileLink('nothing', io), null);
    expectEqual(calls, [
      'save', `launch ${paths.configFile}`, 'ui.config_file_opened {"file":"config.json","with":"default"}',
      'save', `launch ${paths.configDir}`, 'ui.config_file_opened {"file":"folder","with":"files"}',
      `toast ${missingText('slate')}`, 'ui.config_file_opened {"file":".slate","with":"missing"}',
    ]);
  }],
]);
