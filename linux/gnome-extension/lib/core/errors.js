// Errors thrown by Slated's engine, mirroring SlatedCore's `SlatedError` (Swift).
//
// `message` is the Swift error's description, so the text matches the macOS app word for word, e.g.
// `Unknown direction "sideways" in "push sideways"; use up, down, left or right`.

export class SlatedError extends Error {
  /**
   * @param {"invalidSyntax"|"invalidExpression"|"unknownOperation"|"screenNotFound"|"notImplemented"|"invalidConfiguration"} kind
   *   `invalidConfiguration` is for config.json (and Action JSON) that can't be decoded; Swift
   *   reports those as DecodingError. Its `codingPath` lists the keys and indexes leading to the
   *   problem, e.g. ["bindings", 0, "keys"].
   * @param {string} message
   * @param {Object} [details] extra fields: `codingPath`, `name` (unknownOperation), `ref` (screenNotFound)
   */
  constructor(kind, message, details = undefined) {
    super(message);
    this.name = 'SlatedError';
    this.kind = kind;
    if (details) Object.assign(this, details);
  }
}

export const invalidSyntax = (message) => new SlatedError('invalidSyntax', message);
export const invalidExpression = (message) => new SlatedError('invalidExpression', message);
export const unknownOperation = (name) => new SlatedError('unknownOperation', `Unknown operation "${name}"`, {operation: name});
export const screenNotFound = (ref) => new SlatedError('screenNotFound', `No screen matches "${ref}"`, {ref});
export const notImplemented = (what) => new SlatedError('notImplemented', `Not implemented yet: ${what}`);
