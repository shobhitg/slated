// "Import Slate Config into Slated…" (the Mac's menu command): shows what importing ~/.slate.js (or
// ~/.slate) would do, then does it. Slated doesn't read Slate files; importing converts their
// shortcuts, layouts and settings into config.json and settings.json once. A shortcut whose keys
// Slated already uses is left alone, so importing again only brings over what's new.

import Adw from 'gi://Adw';
import Gtk from 'gi://Gtk';

import {importSummary, unconvertibleLabel} from '../migration.js';
import {plural} from '../util.js';
import {box, label} from './widgets.js';

export const IMPORT_TITLE = 'Import Slate Config into Slated…';

/** The dialog's heading, text and the list of what couldn't be converted, from a plan. */
export function importDialogText(plan) {
  const summary = importSummary(plan);
  const lines = [];
  if (!plan.files.length) {
    return {heading: 'No Slate config found', body: 'Slated looks for ~/.slate.js, then ~/.slate.', items: [], canImport: false};
  }
  if (summary.imported) lines.push(`${plural(summary.imported, 'shortcut')} will be added to Slated, where you can edit them.`);
  if (summary.skipped) lines.push(`${plural(summary.skipped, 'shortcut')} Slated already has will be left alone.`);
  if (summary.unconvertible.length) lines.push(`${summary.unconvertible.length} couldn't be converted: they need JavaScript while they run.`);
  lines.push(`Slated doesn't read ${plan.files.join(' and ')}, and doesn't change it.`);
  return {
    heading: summary.imported ? `Import ${plural(summary.imported, 'shortcut')}?` : 'Nothing new to import',
    body: lines.join('\n\n'),
    items: summary.unconvertible.map(item => `${unconvertibleLabel(item)}: ${item.reason}`),
    canImport: summary.imported > 0,
  };
}

/** Shows what importing would do, then does it. `onDone(plan)` runs after an import. */
export function importSlateDialog(ctx, {onDone = null} = {}) {
  const model = ctx.model;
  model.saveNow();
  const plan = model.planSlateImport();
  const text = importDialogText(plan);
  const dialog = new Adw.AlertDialog({heading: text.heading, body: text.body});
  if (text.items.length) {
    const details = box('vertical', 4);
    for (const item of text.items) details.append(label(item, {wrap: true, selectable: true, classes: ['caption']}));
    dialog.set_extra_child(new Gtk.ScrolledWindow({child: details, max_content_height: 200, propagate_natural_height: true,
      hscrollbar_policy: Gtk.PolicyType.NEVER}));
  }
  dialog.add_response('cancel', text.canImport ? 'Cancel' : 'Close');
  if (text.canImport) {
    dialog.add_response('import', 'Import');
    dialog.set_response_appearance('import', Adw.ResponseAppearance.SUGGESTED);
    dialog.set_default_response('import');
  }
  dialog.set_close_response('cancel');
  dialog.connect('response', (_d, response) => {
    if (response !== 'import') return;
    model.applySlateImport(plan);
    model.saveNow();
    ctx.toast(`Imported ${plural(plan.added.length, 'shortcut')} into Slated`);
    onDone?.(plan);
  });
  model.log('ui.import_slate', {importable: plan.added.length, unconvertible: text.items.length});
  dialog.present(ctx.window);
  return dialog;
}
