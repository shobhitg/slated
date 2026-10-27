// Unit tests for the preferences' pure modules (linux/gnome-extension/lib/prefs/*.js, minus the
// GTK and Gio parts). Runs unchanged under Node and GJS:
//
//   node linux/tests/prefs/run.mjs [filter]
//   gjs -m linux/tests/prefs/run.mjs [filter]
//
// The engine (lib/core) may still be partly a stub; tests that depend on it check what the
// preferences do in either case (engine result, or the graceful fallback).

import {run, commandLineArgs, exit} from './harness.mjs';
import keys from './keys.test.mjs';
import config from './config.test.mjs';
import actions from './actions.test.mjs';
import validator from './validator.test.mjs';
import status from './status.test.mjs';
import importer from './importer.test.mjs';
import model from './model.test.mjs';
import misc from './misc.test.mjs';
import automation from './automation.test.mjs';

const failed = await run([keys, config, actions, validator, status, importer, model, misc, automation], (await commandLineArgs())[0] ?? '');
await exit(failed ? 1 : 0);
