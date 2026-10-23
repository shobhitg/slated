// Ids for new bindings and hotstrings. config.json's ids must be UUIDs (Swift's decoder and the
// engine reject anything else), so new ones come from the engine's randomUUID, in Swift's uppercase
// form; the local generator is only a stand-in for an engine without it.
//
// Pure ES module.

import * as core from '../core/index.js';
import {uuid as localUUID} from './util.js';

/** A new binding or hotstring id, e.g. "3F2A9C1E-…". */
export function newId() {
  return typeof core.randomUUID === 'function' ? core.randomUUID() : localUUID();
}
