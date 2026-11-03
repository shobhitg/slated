// Secrets (port of Sources/SlatedCore/Engine/SecretDetection.swift and Model/Secrets.swift, pinned by
// fixtures/secrets.json):
//
// - Which clipboard copies are secrets, kept in the history but masked and in memory only: marked by
//   their app (`concealed`), copied from a password manager (`PASSWORD_MANAGERS`), or looking like one
//   (`secretPattern`). Every pattern works on ASCII, as UTF-16 code units, so Swift and JavaScript see
//   the same characters.
// - Sensitive hotstrings, whose text lives in secrets.json under a name (`secretName`), and the
//   Sensitive switch that moves it there and back (`makeSensitive`, `makeNotSensitive`…). These work on
//   a configuration's `hotstrings` (as config.js decodes them: a sensitive one's `replacement` is
//   `{secret: "<name>"}`) and a separate `secrets` object (name → text), returning new values.

import {trimWhitespaceAndNewlines} from './text.js';

/** Why a clipboard item is hidden: the app marked it, a password manager copied it, its look, or by hand. */
export const SECRET_REASONS = Object.freeze(['marked', 'app', 'pattern', 'manual']);

/** Marked by its app or copied from a password manager: always hidden, and "Show Contents" can't change that. */
export const isLockedReason = (reason) => reason === 'marked' || reason === 'app';

const RANK = {marked: 4, app: 3, manual: 2, pattern: 1};

/** The reason that wins when the same text is copied again: the more certain one (null for none). */
export function strongerReason(a, b) {
  if (!a) return b ?? null;
  if (!b) return a;
  return RANK[a] >= RANK[b] ? a : b;
}

/** Password managers by macOS bundle id and Linux app id: one list for both platforms (Swift's PasswordManagers.ids). */
export const PASSWORD_MANAGERS = Object.freeze([
  'com.1password.1password', 'com.agilebits.onepassword7', 'com.agilebits.onepassword4', '1password',
  'com.bitwarden.desktop', 'bitwarden', 'bitwarden_bitwarden',
  'com.apple.Passwords', 'com.apple.Passwords.MenuBarExtra', 'com.apple.keychainaccess',
  'org.keepassxc.keepassxc', 'keepassxc', 'keepass2', 'com.hicknhacksoftware.MacPass', 'com.markmcguill.strongbox.mac',
  'com.dashlane.dashlanephonefinal', 'com.lastpass.LastPass', 'com.lastpass.lastpassmacdesktop',
  'me.proton.pass.electron', 'proton-pass', 'me.proton.Pass',
  'in.sinew.Enpass-Desktop', 'enpass', 'com.nordsec.nordpass', 'nordpass', 'com.keepersecurity.passwordmanager',
  'org.gnome.World.Secrets', 'org.gnome.seahorse.Application',
]);

const LOWERCASED_MANAGERS = new Set(PASSWORD_MANAGERS.map((id) => id.toLowerCase()));

/** Whether `appId` is a password manager. Case doesn't matter (KeePassXC is `org.keepassxc.KeePassXC` on Linux). */
export function isPasswordManager(appId) {
  return typeof appId === 'string' && LOWERCASED_MANAGERS.has(appId.toLowerCase());
}

/**
 * Why a copy of `text` is a secret, or null: `concealed` (the app marked it secret), then a password
 * manager (`app`), then its look (`pattern`, when `patterns` is on).
 */
export function secretReason({text = '', concealed = false, app = null, patterns = true} = {}) {
  if (concealed) return 'marked';
  if (app && isPasswordManager(app)) return 'app';
  if (patterns && secretPattern(text) !== null) return 'pattern';
  return null;
}

// --- Patterns ----------------------------------------------------------------------------------------

/** Text longer than this is searched only this far (UTF-16 units) for tokens and keys. */
const SCAN_LIMIT = 100_000;

const isUpper = (c) => c >= 65 && c <= 90;
const isLower = (c) => c >= 97 && c <= 122;
const isDigit = (c) => c >= 48 && c <= 57;
const isAlnum = (c) => isUpper(c) || isLower(c) || isDigit(c);
const isHex = (c) => isDigit(c) || (c >= 65 && c <= 70) || (c >= 97 && c <= 102);
const isVisible = (c) => c >= 0x21 && c <= 0x7e;

const unitsOf = (s) => Array.from({length: s.length}, (_, i) => s.charCodeAt(i));

/**
 * What makes `text` look like a secret, or null: 'private-key', 'token', 'jwt' or 'url-password'
 * anywhere in it, or 'card-number', 'generated-password' or 'random' for the whole trimmed text.
 */
export function secretPattern(text) {
  const s = String(text ?? '');
  const units = unitsOf(s.length > SCAN_LIMIT ? s.slice(0, SCAN_LIMIT) : s);
  if (hasPrivateKey(units)) return 'private-key';
  if (hasToken(units)) return 'token';
  if (hasJWT(units)) return 'jwt';
  if (hasURLPassword(units)) return 'url-password';
  const whole = unitsOf(trimWhitespaceAndNewlines(s));
  if (isCardNumber(whole)) return 'card-number';
  if (isGeneratedPassword(whole)) return 'generated-password';
  if (isRandom(whole)) return 'random';
  return null;
}

function occurs(pattern, text, index) {
  if (index < 0 || index + pattern.length > text.length) return false;
  for (let k = 0; k < pattern.length; k++) if (text[index + k] !== pattern[k]) return false;
  return true;
}

function indicesOf(pattern, text) {
  const found = [];
  for (let i = 0; i + pattern.length <= text.length; i++) if (text[i] === pattern[0] && occurs(pattern, text, i)) found.push(i);
  return found;
}

const PEM_START = unitsOf('-----BEGIN ');
const DASHES = unitsOf('-----');

/** `-----BEGIN … PRIVATE KEY-----` or `… PRIVATE KEY BLOCK-----`: a label of capitals, digits and spaces (at most 40). */
function hasPrivateKey(text) {
  for (const start of indicesOf(PEM_START, text)) {
    let end = start + PEM_START.length;
    while (end < text.length && end - start - PEM_START.length <= 40 && (isUpper(text[end]) || isDigit(text[end]) || text[end] === 32)) end += 1;
    if (!occurs(DASHES, text, end)) continue;
    const label = String.fromCharCode(...text.slice(start + PEM_START.length, end));
    if (label.endsWith('PRIVATE KEY') || label.endsWith('PRIVATE KEY BLOCK')) return true;
  }
  return false;
}

const CHARSETS = {
  alnum: isAlnum,
  urlSafe: (c) => isAlnum(c) || c === 95 || c === 45,
  word: (c) => isAlnum(c) || c === 95,
  upperAlnum: (c) => isUpper(c) || isDigit(c),
  hex: isHex,
  lowerHex: (c) => isDigit(c) || (c >= 97 && c <= 102),
  dashed: (c) => isAlnum(c) || c === 45,
  dotted: (c) => isAlnum(c) || c === 95 || c === 45 || c === 46,
};

const rule = (prefix, charset, min, max, {mixed = false, digit = false} = {}) => ({prefix, charset: CHARSETS[charset], min, max, mixed, digit});

/** Well-known API tokens: a prefix, then min…max characters of a charset (Swift's tokenRules). */
const TOKEN_RULES = [
  rule('sk-', 'urlSafe', 20, 250, {mixed: true}),
  rule('github_pat_', 'word', 22, 255),
  rule('glpat-', 'urlSafe', 20, 64),
  rule('AKIA', 'upperAlnum', 16, 16),
  rule('ASIA', 'upperAlnum', 16, 16),
  rule('whsec_', 'alnum', 24, 64),
  rule('AIza', 'urlSafe', 35, 35),
  rule('npm_', 'alnum', 36, 36),
  rule('pypi-', 'urlSafe', 50, 255),
  rule('SG.', 'dotted', 60, 70),
  rule('hf_', 'alnum', 30, 40, {mixed: true}),
  rule('dckr_pat_', 'urlSafe', 20, 64),
  rule('dop_v1_', 'lowerHex', 64, 64),
  rule('lin_api_', 'alnum', 40, 40),
  rule('ntn_', 'alnum', 40, 64, {digit: true}),
  rule('secret_', 'alnum', 43, 43),
  rule('ATATT', 'urlSafe', 100, 300),
  rule('ya29.', 'urlSafe', 30, 2048),
  rule('AGE-SECRET-KEY-1', 'upperAlnum', 58, 58),
  rule('sq0atp-', 'urlSafe', 22, 64),
  rule('sq0csp-', 'urlSafe', 40, 64),
  ...['ghp_', 'gho_', 'ghu_', 'ghs_', 'ghr_'].map((p) => rule(p, 'alnum', 36, 36)),
  ...['xoxa-', 'xoxb-', 'xoxe-', 'xoxp-', 'xoxr-', 'xoxs-', 'xapp-'].map((p) => rule(p, 'dashed', 10, 255, {digit: true})),
  ...['sk_live_', 'sk_test_', 'rk_live_', 'rk_test_'].map((p) => rule(p, 'alnum', 16, 255)),
  ...['shpat_', 'shpss_', 'shpca_', 'shppa_'].map((p) => rule(p, 'hex', 32, 32)),
].map((r) => ({...r, units: unitsOf(r.prefix)}));

const RULES_BY_FIRST = new Map();
for (const r of TOKEN_RULES) {
  if (!RULES_BY_FIRST.has(r.units[0])) RULES_BY_FIRST.set(r.units[0], []);
  RULES_BY_FIRST.get(r.units[0]).push(r);
}

/** A token anywhere: at the start or after a non-alphanumeric character, its whole body the right length. */
function hasToken(text) {
  for (let start = 0; start < text.length; start++) {
    if (start > 0 && isAlnum(text[start - 1])) continue;
    const rules = RULES_BY_FIRST.get(text[start]);
    if (!rules) continue;
    for (const r of rules) {
      if (!occurs(r.units, text, start)) continue;
      let end = start + r.units.length;
      while (end < text.length && r.charset(text[end])) end += 1;
      const body = text.slice(start + r.units.length, end);
      if (body.length < r.min || body.length > r.max || (end < text.length && isAlnum(text[end]))) continue;
      if (r.mixed && !(body.some(isLower) && body.some(isUpper) && body.some(isDigit))) continue;
      if (r.digit && !body.some(isDigit)) continue;
      return true;
    }
  }
  return false;
}

const JWT_START = unitsOf('eyJ');

/** `header.payload.signature`: header and payload of 10+ characters starting `eyJ`, the signature possibly empty. */
function hasJWT(text) {
  const isPart = (c) => isAlnum(c) || c === 95 || c === 45;
  for (const start of indicesOf(JWT_START, text)) {
    if (start > 0 && (isPart(text[start - 1]) || text[start - 1] === 46)) continue;
    let end = start;
    while (end < text.length && (isPart(text[end]) || text[end] === 46)) end += 1;
    const parts = [];
    let from = start;
    for (let i = start; i <= end; i++) {
      if (i === end || text[i] === 46) {
        parts.push(text.slice(from, i));
        from = i + 1;
      }
    }
    if (parts.length !== 3) continue;
    if (parts[0].length >= 10 && parts[1].length >= 10 && occurs(JWT_START, parts[1], 0)) return true;
  }
  return false;
}

const SCHEME_SEPARATOR = unitsOf('://');

/** `scheme://user:password@host…` with a password that isn't a placeholder (`*`, `$`, `<`, `{` first). */
function hasURLPassword(text) {
  for (const index of indicesOf(SCHEME_SEPARATOR, text)) {
    let schemeStart = index;
    while (schemeStart > 0 && (isAlnum(text[schemeStart - 1]) || [43, 45, 46].includes(text[schemeStart - 1]))) schemeStart -= 1;
    if (!(schemeStart < index && (isUpper(text[schemeStart]) || isLower(text[schemeStart])))) continue;
    let end = index + SCHEME_SEPARATOR.length;
    while (end < text.length && isVisible(text[end]) && ![47, 63, 35, 34, 39, 60, 62, 96].includes(text[end])) end += 1;
    const authority = text.slice(index + SCHEME_SEPARATOR.length, end);
    const at = authority.lastIndexOf(64);
    if (at < 0) continue;
    const userinfo = authority.slice(0, at);
    const colon = userinfo.indexOf(58);
    if (colon < 0) continue;
    const password = userinfo.slice(colon + 1);
    if (password.length === 0 || [42, 36, 60, 123].includes(password[0])) continue;
    return true;
  }
  return false;
}

/** 13–19 digits in groups of one separator kind, a card network's prefix and length, and the Luhn check. */
function isCardNumber(text) {
  if (text.length === 0 || !isDigit(text[0]) || !isDigit(text[text.length - 1])) return false;
  const digits = [];
  let separator = null;
  let previousWasSeparator = false;
  for (const c of text) {
    if (isDigit(c)) {
      digits.push(c - 48);
      previousWasSeparator = false;
    } else if (c === 32 || c === 45) {
      if (previousWasSeparator || (separator !== null && separator !== c)) return false;
      separator = c;
      previousWasSeparator = true;
    } else {
      return false;
    }
  }
  return digits.length >= 13 && digits.length <= 19 && hasCardPrefix(digits) && luhn(digits);
}

function hasCardPrefix(digits) {
  const prefix = (n) => digits.slice(0, n).reduce((a, d) => a * 10 + d, 0);
  const length = digits.length;
  const p2 = prefix(2);
  const p3 = prefix(3);
  const p4 = prefix(4);
  const within = (v, lo, hi) => v >= lo && v <= hi;
  if (digits[0] === 4) return [13, 16, 19].includes(length);
  if (within(p2, 51, 55) || within(p4, 2221, 2720)) return length === 16;
  if (p2 === 34 || p2 === 37) return length === 15;
  if (p4 === 6011 || p2 === 65 || within(p3, 644, 649) || within(p4, 3528, 3589) || p2 === 62) return within(length, 16, 19);
  if (within(p3, 300, 305) || p2 === 36 || p2 === 38 || p2 === 39) return within(length, 14, 19);
  if (p2 === 50 || within(p2, 56, 69)) return within(length, 13, 19);
  return false;
}

function luhn(digits) {
  let sum = 0;
  digits.slice().reverse().forEach((digit, i) => {
    if (i % 2 === 1) {
      const doubled = digit * 2;
      sum += doubled > 9 ? doubled - 9 : doubled;
    } else {
      sum += digit;
    }
  });
  return sum % 10 === 0;
}

/** Apple's suggested passwords: `abcdef-ghijk1-mnoPqr`, with a lowercase letter, a capital and a digit. */
function isGeneratedPassword(text) {
  if (text.length !== 20 || text[6] !== 45 || text[13] !== 45) return false;
  const groups = [text.slice(0, 6), text.slice(7, 13), text.slice(14, 20)];
  if (!groups.every((g) => g.every(isAlnum))) return false;
  return text.some(isLower) && text.some(isUpper) && text.some(isDigit);
}

/** One random-looking word: Swift's isRandom, rule for rule. */
function isRandom(text) {
  const n = text.length;
  if (n < 16 || n > 256 || !text.every(isVisible)) return false;
  if (indicesOf(SCHEME_SEPARATOR, text).length > 0) return false;
  if (looksLikeEmail(text) || looksLikePath(text) || isHexID(text) || looksLikeVersion(text)) return false;
  if (String.fromCharCode(...text.slice(0, 4)).toLowerCase() === 'www.') return false;
  const lower = text.some(isLower);
  const upper = text.some(isUpper);
  const digit = text.some(isDigit);
  const symbol = text.some((c) => !isAlnum(c));
  const kinds = [lower, upper, digit, symbol].filter(Boolean).length;
  if (kinds < 3 || !(lower || upper) || !digit) return false;
  if (entropy(text) < entropyThreshold(n)) return false;
  return !isWordLike(text);
}

function entropyThreshold(n) {
  if (n < 20) return 3.6;
  if (n < 28) return 3.9;
  if (n < 40) return 4.2;
  return 4.4;
}

/** Shannon entropy in bits per character, its counts summed smallest first as in Swift. */
function entropy(text) {
  const counts = new Map();
  for (const c of text) counts.set(c, (counts.get(c) ?? 0) + 1);
  let sum = 0;
  for (const count of [...counts.values()].sort((a, b) => a - b)) sum += count * Math.log2(count);
  return Math.log2(text.length) - sum / text.length;
}

/** Whether 40% or more of the characters are in words of four letters or more (camelCase and acronyms split). */
function isWordLike(text) {
  let inWords = 0;
  let i = 0;
  const n = text.length;
  while (i < n) {
    if (isUpper(text[i])) {
      let j = i;
      while (j < n && isUpper(text[j])) j += 1;
      const capitals = j - i;
      if (j < n && isLower(text[j])) {
        if (capitals - 1 >= 4) inWords += capitals - 1;
        let k = j;
        while (k < n && isLower(text[k])) k += 1;
        if (1 + k - j >= 4) inWords += 1 + k - j;
        i = k;
      } else {
        if (capitals >= 4) inWords += capitals;
        i = j;
      }
    } else if (isLower(text[i])) {
      let k = i;
      while (k < n && isLower(text[k])) k += 1;
      if (k - i >= 4) inWords += k - i;
      i = k;
    } else {
      i += 1;
    }
  }
  return inWords * 5 >= n * 2;
}

function looksLikeEmail(text) {
  const at = text.lastIndexOf(64);
  if (at <= 0) return false;
  const host = text.slice(at + 1);
  return host.includes(46) && host.every((c) => isAlnum(c) || c === 46 || c === 45);
}

function looksLikePath(text) {
  if (text.length === 0) return false;
  const first = text[0];
  if (first === 47 || first === 126 || text.includes(92)) return true;
  if (occurs(unitsOf('./'), text, 0) || occurs(unitsOf('../'), text, 0)) return true;
  return text.length >= 3 && (isUpper(text[0]) || isLower(text[0])) && text[1] === 58 && text[2] === 92;
}

function isHexID(text) {
  const digits = text.filter((c) => ![45, 58, 46, 95, 35].includes(c));
  return digits.length > 0 && digits.every(isHex);
}

function looksLikeVersion(text) {
  let i = text[0] === 118 || text[0] === 86 ? 1 : 0;
  const start = i;
  while (i < text.length && isDigit(text[i])) i += 1;
  if (!(i > start && i < text.length && text[i] === 46 && i + 1 < text.length)) return false;
  return isDigit(text[i + 1]);
}

// --- Sensitive hotstrings ----------------------------------------------------------------------------

/** A sensitive hotstring's secret name (`replacement: {secret}`), or null. */
export function hotstringSecret(hotstring) {
  const r = hotstring?.replacement;
  return r !== null && typeof r === 'object' && typeof r.secret === 'string' ? r.secret : null;
}

/**
 * The name a new secret gets from its hotstring's trigger: ASCII letters, digits and underscores, other
 * characters between them as one dash, at most 40 characters, "secret" when nothing's left; then "-2",
 * "-3"… while it's in `taken` (a Set or an array).
 */
export function secretName(trigger, taken = []) {
  const used = taken instanceof Set ? taken : new Set(taken);
  let base = '';
  let gap = false;
  const s = String(trigger ?? '');
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    if (!(isAlnum(c) || c === 95)) {
      gap = true;
      continue;
    }
    if (gap && base !== '') base += '-';
    gap = false;
    base += s[i];
  }
  base = base.slice(0, 40).replace(/-+$/, '');
  if (base === '') base = 'secret';
  let name = base;
  for (let suffix = 2; used.has(name); suffix++) name = `${base}-${suffix}`;
  return name;
}

const has = (object, key) => Object.prototype.hasOwnProperty.call(object, key);

/** Every name in use: the secrets', and those hotstrings refer to (even ones missing from secrets.json). */
export function secretNamesInUse(hotstrings, secrets) {
  return new Set([...Object.keys(secrets ?? {}), ...(hotstrings ?? []).map(hotstringSecret).filter((n) => n !== null)]);
}

/** The text a hotstring types: its secret for a sensitive one (null while missing), else its replacement. */
export function hotstringText(hotstring, secrets) {
  const name = hotstringSecret(hotstring);
  if (name === null) return typeof hotstring?.replacement === 'string' ? hotstring.replacement : '';
  return secrets && has(secrets, name) ? secrets[name] : null;
}

/** A sensitive hotstring whose text isn't on this computer: it doesn't expand until it's entered. */
export function isMissingSecret(hotstring, secrets) {
  const name = hotstringSecret(hotstring);
  return name !== null && !(secrets && has(secrets, name));
}

const copySecrets = (secrets) => Object.assign(Object.create(null), secrets ?? {});
const plainSecrets = (secrets) => Object.fromEntries(Object.entries(secrets));
const valid = (hotstrings, index) => Number.isInteger(index) && index >= 0 && index < hotstrings.length;

/**
 * The Sensitive switch, on: the text moves into secrets under a new name. Returns {hotstrings, secrets}
 * (new arrays and objects; the inputs are left alone). One already sensitive stays as it is.
 */
export function makeSensitive(hotstrings, secrets, index) {
  if (!valid(hotstrings, index) || hotstringSecret(hotstrings[index]) !== null) return {hotstrings: [...hotstrings], secrets: {...secrets}};
  const name = secretName(hotstrings[index].trigger, secretNamesInUse(hotstrings, secrets));
  const next = copySecrets(secrets);
  next[name] = typeof hotstrings[index].replacement === 'string' ? hotstrings[index].replacement : '';
  const list = hotstrings.map((h, i) => (i === index ? {...h, replacement: {secret: name}} : h));
  return {hotstrings: list, secrets: plainSecrets(next)};
}

/** The switch, off: the text moves back (empty when missing); the secret goes unless another hotstring uses it. */
export function makeNotSensitive(hotstrings, secrets, index) {
  const name = valid(hotstrings, index) ? hotstringSecret(hotstrings[index]) : null;
  if (name === null) return {hotstrings: [...hotstrings], secrets: {...secrets}};
  const text = secrets && has(secrets, name) ? secrets[name] : '';
  const list = hotstrings.map((h, i) => (i === index ? {...h, replacement: text} : h));
  return {hotstrings: list, secrets: forgetSecret(list, secrets, name)};
}

/** A sensitive hotstring's new text, into secrets. Returns the new secrets (the same for one not sensitive). */
export function setSecretText(hotstrings, secrets, index, text) {
  const name = valid(hotstrings, index) ? hotstringSecret(hotstrings[index]) : null;
  const next = copySecrets(secrets);
  if (name !== null) next[name] = String(text);
  return plainSecrets(next);
}

/** A copy of a sensitive hotstring (Duplicate) gets its own secret with the same text. Returns {hotstrings, secrets}. */
export function giveOwnSecret(hotstrings, secrets, index) {
  const name = valid(hotstrings, index) ? hotstringSecret(hotstrings[index]) : null;
  if (name === null) return {hotstrings: [...hotstrings], secrets: {...secrets}};
  const own = secretName(hotstrings[index].trigger, secretNamesInUse(hotstrings, secrets));
  const next = copySecrets(secrets);
  if (has(next, name)) next[own] = next[name];
  const list = hotstrings.map((h, i) => (i === index ? {...h, replacement: {secret: own}} : h));
  return {hotstrings: list, secrets: plainSecrets(next)};
}

/** The secrets without `name`, unless a hotstring still refers to it (after deleting one in the window). */
export function forgetSecret(hotstrings, secrets, name) {
  const next = copySecrets(secrets);
  if (!hotstrings.some((h) => hotstringSecret(h) === name)) delete next[name];
  return plainSecrets(next);
}

/** For tests: the pieces Swift's tests check directly. */
export const secretInternals = Object.freeze({luhn, hasCardPrefix, entropy, isWordLike});
