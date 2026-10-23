// Slate's expression language (port of SlateExpression.swift).
//
// Numbers, variables, `+ - * / **`, unary minus, parentheses and the functions `sum count min max
// average median stddev sqrt log ln exp floor ceiling abs trunc random randomn`. Like NSExpression
// (which Slate used): `**` binds tighter than `*` and is left-associative, unary minus binds tighter
// than `**`, and `/` is floating-point division. Unlike Slate, spaces are allowed and the result must
// be a finite number. Errors say what is wrong and where (1-based column, in characters).

import {invalidExpression} from './errors.js';
import {
  characterCount,
  compareStrings,
  graphemes,
  hasPrefix,
  isASCIIDigit,
  isLetter,
  isNumber,
  isWhitespace,
  lowercased,
  parseDouble,
  shortNumber,
} from './text.js';

/** Variables describing the window and its target screen, available to every window operation. */
export const windowVariableNames = Object.freeze([
  'screenOriginX', 'screenOriginY', 'screenSizeX', 'screenSizeY', 'windowTopLeftX', 'windowTopLeftY',
  'windowSizeX', 'windowSizeY', 'newWindowSizeX', 'newWindowSizeY',
]);

/** Every variable Slate documents (adds the window-hint sizes used by the hint settings). */
export const variableNames = Object.freeze([...windowVariableNames, 'windowHintsWidth', 'windowHintsHeight']);

const FUNCTIONS = [
  'sum', 'count', 'min', 'max', 'average', 'median', 'stddev', 'sqrt', 'log', 'ln', 'exp', 'floor', 'ceiling', 'abs',
  'trunc', 'random', 'randomn',
];
const AGGREGATES = new Set(['sum', 'count', 'min', 'max', 'average', 'median', 'stddev']);
const arity = (f) => (f === 'random' ? 0 : 1);
const MAXIMUM_DEPTH = 200;

/**
 * Evaluates `expression` with `variables` supplying each variable it mentions.
 * @param {string} expression
 * @param {Object<string, number>} variables
 * @returns {number}
 * @throws {SlatedError} kind "invalidExpression"
 */
export function evaluateExpression(expression, variables) {
  const parsed = parse(expression);
  const value = new Evaluator(expression, variables).value(parsed);
  if (!Number.isFinite(value)) throw invalidExpression(`"${expression}" doesn't evaluate to a finite number`);
  return value;
}

/**
 * Checks that `expression` parses and only mentions `variables` (default: the window variables),
 * without evaluating it. Throws SlatedError("invalidExpression").
 */
export function validateExpression(expression, variables = windowVariableNames) {
  const parsed = parse(expression);
  const known = new Set(variables);
  forEachVariable(parsed, (name, column) => {
    if (!known.has(name)) throw unknownVariable(name, column, expression, known);
  });
}

// --- Lexer -----------------------------------------------------------------------------------------

function tokenDisplay(token) {
  switch (token.kind) {
    case 'number': return shortNumber(token.value);
    case 'identifier': return token.name;
    case 'symbol': return token.symbol;
    default: return 'end';
  }
}

function lex(source) {
  const chars = graphemes(source);
  const tokens = [];
  let i = 0;
  while (i < chars.length) {
    const c = chars[i];
    const column = i + 1;
    if (isWhitespace(c)) {
      i++;
    } else if (isASCIIDigit(c) || c === '.') {
      // digits [. digits] [e [+-] digits], or .digits
      let j = i;
      while (j < chars.length && isASCIIDigit(chars[j])) j++;
      if (j < chars.length && chars[j] === '.') {
        j++;
        while (j < chars.length && isASCIIDigit(chars[j])) j++;
      }
      if (j < chars.length && (chars[j] === 'e' || chars[j] === 'E')) {
        let k = j + 1;
        if (k < chars.length && (chars[k] === '+' || chars[k] === '-')) k++;
        if (k < chars.length && isASCIIDigit(chars[k])) {
          while (k < chars.length && isASCIIDigit(chars[k])) k++;
          j = k;
        }
      }
      const text = chars.slice(i, j).join('');
      const value = parseDouble(text);
      if (value === null || text === '.') throw invalidExpression(`Invalid number "${text}" at column ${column} in "${source}"`);
      tokens.push({kind: 'number', value, column});
      i = j;
    } else if (isLetter(c) || c === '_') {
      let j = i;
      while (j < chars.length && (isLetter(chars[j]) || isNumber(chars[j]) || chars[j] === '_')) j++;
      tokens.push({kind: 'identifier', name: chars.slice(i, j).join(''), column});
      i = j;
    } else if (c === '*' && chars[i + 1] === '*') {
      tokens.push({kind: 'symbol', symbol: '**', column});
      i += 2;
    } else if (c.length === 1 && '+-*/(){},'.includes(c)) {
      tokens.push({kind: 'symbol', symbol: c, column});
      i++;
    } else {
      throw invalidExpression(`Unexpected character "${c}" at column ${column} in "${source}"`);
    }
  }
  tokens.push({kind: 'end', column: chars.length + 1});
  return tokens;
}

// --- Parser ----------------------------------------------------------------------------------------
//
//     expression := term (('+' | '-') term)*
//     term       := power (('*' | '/') power)*
//     power      := unary ('**' unary)*            -- left-associative, like NSExpression
//     unary      := ('-' | '+') unary | primary    -- binds tighter than '**', like NSExpression
//     primary    := number | variable | function '(' arguments ')' | '(' expression ')'
//     argument   := expression | '{' (expression (',' expression)*)? '}'

function parse(source) {
  const tokens = lex(source);
  let position = 0;
  let depth = 0;
  if (tokens.length === 1) throw invalidExpression('The expression is empty');

  const current = () => tokens[position];
  const advance = () => {
    const token = tokens[position];
    if (position < tokens.length - 1) position++;
    return token;
  };
  const isSymbol = (s) => current().kind === 'symbol' && current().symbol === s;
  const consume = (s) => {
    if (!isSymbol(s)) return false;
    advance();
    return true;
  };
  const unexpected = (token, expecting) => {
    if (token.kind === 'end') return invalidExpression(`"${source}" ends too early; expected ${expecting}`);
    return invalidExpression(`Unexpected "${tokenDisplay(token)}" at column ${token.column} in "${source}"; expected ${expecting}`);
  };
  const tooDeep = () => invalidExpression(`"${source}" is nested too deeply`);

  function parseExpression() {
    depth++;
    try {
      if (depth > MAXIMUM_DEPTH) throw tooDeep();
      let lhs = parseTerm();
      while (isSymbol('+') || isSymbol('-')) {
        const op = advance();
        const rhs = parseTerm();
        lhs = {kind: 'binary', op: op.symbol, lhs, rhs, column: op.column};
      }
      return lhs;
    } finally {
      depth--;
    }
  }

  function parseTerm() {
    let lhs = parsePower();
    while (isSymbol('*') || isSymbol('/')) {
      const op = advance();
      const rhs = parsePower();
      lhs = {kind: 'binary', op: op.symbol, lhs, rhs, column: op.column};
    }
    return lhs;
  }

  function parsePower() {
    let lhs = parseUnary();
    while (isSymbol('**')) {
      const op = advance();
      const rhs = parseUnary();
      lhs = {kind: 'binary', op: '**', lhs, rhs, column: op.column};
    }
    return lhs;
  }

  function parseUnary() {
    if (isSymbol('-') || isSymbol('+')) {
      const op = advance();
      depth++;
      try {
        if (depth > MAXIMUM_DEPTH) throw tooDeep();
        const operand = parseUnary();
        return op.symbol === '-' ? {kind: 'negate', operand} : operand;
      } finally {
        depth--;
      }
    }
    return parsePrimary();
  }

  function parsePrimary() {
    const token = current();
    if (token.kind === 'number') {
      advance();
      return {kind: 'number', value: token.value};
    }
    if (token.kind === 'identifier') {
      advance();
      if (isSymbol('(')) return parseCall(token.name, token.column);
      const lowered = lowercased(token.name);
      if (FUNCTIONS.includes(lowered)) {
        const example = lowered === 'random' ? 'random()' : `${lowered}(…)`;
        throw invalidExpression(`"${token.name}" at column ${token.column} in "${source}" is a function; call it like ${example}`);
      }
      return {kind: 'variable', name: token.name, column: token.column};
    }
    if (token.kind === 'symbol' && token.symbol === '(') {
      const open = advance();
      const inner = parseExpression();
      if (!isSymbol(')')) {
        if (current().kind === 'end') {
          throw invalidExpression(`Missing ")" for the "(" at column ${open.column} in "${source}"`);
        }
        throw unexpected(current(), '")"');
      }
      advance();
      return inner;
    }
    if (token.kind === 'symbol' && token.symbol === '{') {
      throw invalidExpression(
        `A list like {1,2} at column ${token.column} in "${source}" can only be passed to ` +
          'sum, count, min, max, average, median or stddev',
      );
    }
    throw unexpected(token, 'a number, a variable or "("');
  }

  function parseCall(name, column) {
    const lowered = lowercased(name);
    if (!FUNCTIONS.includes(lowered)) {
      let message = `Unknown function "${name}" at column ${column} in "${source}"`;
      const suggestion = closestName(name, FUNCTIONS);
      if (suggestion !== null) message += `. Did you mean "${suggestion}"?`;
      throw invalidExpression(message);
    }
    advance(); // (
    const args = [];
    if (!isSymbol(')')) {
      do {
        if (isSymbol('{')) args.push({list: parseList()});
        else args.push({value: parseExpression()});
      } while (consume(','));
    }
    if (!isSymbol(')')) {
      if (current().kind === 'end') {
        throw invalidExpression(`Missing ")" after the arguments of "${name}" at column ${column} in "${source}"`);
      }
      throw unexpected(current(), '"," or ")"');
    }
    advance();
    if (AGGREGATES.has(lowered)) return {kind: 'call', fn: lowered, args, column};
    if (args.some((a) => a.list)) {
      throw invalidExpression(`"${lowered}" at column ${column} in "${source}" takes a number, not a list`);
    }
    if (args.length !== arity(lowered)) {
      const expected = arity(lowered) === 1 ? '1 argument' : 'no arguments';
      throw invalidExpression(`"${lowered}" takes ${expected} but got ${args.length} at column ${column} in "${source}"`);
    }
    return {kind: 'call', fn: lowered, args, column};
  }

  function parseList() {
    const open = advance(); // {
    const items = [];
    if (!isSymbol('}')) {
      do {
        if (isSymbol('{')) throw invalidExpression(`Lists can't be nested (column ${current().column} in "${source}")`);
        items.push(parseExpression());
      } while (consume(','));
    }
    if (!isSymbol('}')) {
      if (current().kind === 'end') throw invalidExpression(`Missing "}" for the "{" at column ${open.column} in "${source}"`);
      throw unexpected(current(), '"," or "}"');
    }
    advance();
    return items;
  }

  const node = parseExpression();
  if (current().kind !== 'end') throw unexpected(current(), 'an operator such as + or *');
  return node;
}

function forEachVariable(node, body) {
  switch (node.kind) {
    case 'variable':
      body(node.name, node.column);
      break;
    case 'negate':
      forEachVariable(node.operand, body);
      break;
    case 'binary':
      forEachVariable(node.lhs, body);
      forEachVariable(node.rhs, body);
      break;
    case 'call':
      for (const a of node.args) {
        if (a.list) a.list.forEach((n) => forEachVariable(n, body));
        else forEachVariable(a.value, body);
      }
      break;
    default:
      break;
  }
}

function unknownVariable(name, column, source, known) {
  let message = `Unknown variable "${name}" at column ${column} in "${source}"`;
  const suggestion = closestName(name, [...known].sort(compareStrings));
  if (suggestion !== null) message += `. Did you mean "${suggestion}"?`;
  return invalidExpression(message);
}

/** The candidate closest to `name` (ignoring case), if it is close enough to be a likely typo. */
export function closestName(name, candidates) {
  const lowered = lowercased(name);
  let best = null;
  for (const candidate of candidates) {
    const distance = editDistance(lowered, lowercased(candidate));
    if (best === null || distance < best.distance) best = {name: candidate, distance};
  }
  const allowed = Math.max(1, Math.min(3, Math.floor(characterCount(name) / 3)));
  if (best !== null && best.distance <= allowed) return best.name;
  // An abbreviation, like "ceil" for "ceiling".
  if (characterCount(lowered) < 3) return null;
  return candidates.find((c) => hasPrefix(lowercased(c), lowered)) ?? null;
}

/** Levenshtein distance between two strings, by characters (canonically equivalent ones match). */
export function editDistance(a, b) {
  const x = graphemes(a).map((c) => c.normalize('NFC'));
  const y = graphemes(b).map((c) => c.normalize('NFC'));
  if (x.length === 0) return y.length;
  if (y.length === 0) return x.length;
  let previous = Array.from({length: y.length + 1}, (_, k) => k);
  let row = new Array(y.length + 1).fill(0);
  for (let i = 1; i <= x.length; i++) {
    row[0] = i;
    for (let j = 1; j <= y.length; j++) {
      const substitution = previous[j - 1] + (x[i - 1] === y[j - 1] ? 0 : 1);
      row[j] = Math.min(substitution, previous[j] + 1, row[j - 1] + 1);
    }
    [previous, row] = [row, previous];
  }
  return previous[y.length];
}

// --- Evaluator -------------------------------------------------------------------------------------

/** C's pow (Foundation's): unlike Math.pow, pow(1, y) is 1 for any y and pow(-1, ±∞) is 1. */
function cPow(x, y) {
  if (x === 1) return 1;
  if (x === -1 && (y === Infinity || y === -Infinity)) return 1;
  return Math.pow(x, y);
}

class Evaluator {
  constructor(source, variables) {
    this.source = source;
    this.variables = variables ?? {};
  }

  value(node) {
    switch (node.kind) {
      case 'number':
        return node.value;
      case 'variable': {
        const v = this.variables;
        if (!Object.prototype.hasOwnProperty.call(v, node.name) || typeof v[node.name] !== 'number') {
          const known = new Set([...Object.keys(v), ...variableNames]);
          throw unknownVariable(node.name, node.column, this.source, known);
        }
        return v[node.name];
      }
      case 'negate':
        return -this.value(node.operand);
      case 'binary': {
        const lhs = this.value(node.lhs);
        const rhs = this.value(node.rhs);
        switch (node.op) {
          case '+': return lhs + rhs;
          case '-': return lhs - rhs;
          case '*': return lhs * rhs;
          case '/':
            if (rhs === 0) throw invalidExpression(`Division by zero at column ${node.column} in "${this.source}"`);
            return lhs / rhs;
          default: return cPow(lhs, rhs);
        }
      }
      default:
        return this.call(node);
    }
  }

  call({fn, args, column}) {
    if (AGGREGATES.has(fn)) {
      const values = [];
      for (const a of args) {
        if (a.list) for (const n of a.list) values.push(this.value(n));
        else values.push(this.value(a.value));
      }
      return this.aggregate(fn, values, column);
    }
    const operands = args.map((a) => this.value(a.value));
    const x = operands[0];
    switch (fn) {
      case 'sqrt': return Math.sqrt(x);
      case 'log': return Math.log10(x);
      case 'ln': return Math.log(x);
      case 'exp': return Math.exp(x);
      case 'floor': return Math.floor(x);
      case 'ceiling': return Math.ceil(x);
      case 'abs': return Math.abs(x);
      case 'trunc': return Math.trunc(x);
      case 'random': return Math.random();
      default: {
        // randomn: like NSExpression, a random integer from 0 to n-1, with n truncated to an integer.
        const n = Math.trunc(x);
        if (!(n >= 1 && n < 1e15)) {
          throw invalidExpression(`"randomn" at column ${column} in "${this.source}" needs a number of at least 1`);
        }
        return Math.floor(Math.random() * n);
      }
    }
  }

  aggregate(fn, values, column) {
    if (fn === 'sum') return values.reduce((a, b) => a + b, 0);
    if (fn === 'count') return values.length;
    if (values.length === 0) {
      throw invalidExpression(`"${fn}" at column ${column} in "${this.source}" needs at least one value`);
    }
    switch (fn) {
      case 'min': return values.reduce((result, e) => (e < result ? e : result));
      case 'max': return values.reduce((result, e) => (result < e ? e : result));
      case 'average': return values.reduce((a, b) => a + b, 0) / values.length;
      case 'median': {
        const sorted = [...values].sort((a, b) => a - b);
        const middle = Math.floor(sorted.length / 2);
        return sorted.length % 2 === 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
      }
      default: {
        const mean = values.reduce((a, b) => a + b, 0) / values.length;
        const variance = values.reduce((sum, v) => sum + (v - mean) * (v - mean), 0) / values.length;
        return Math.sqrt(variance);
      }
    }
  }
}
