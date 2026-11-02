// The window's side of file links (lib/prefs/filelinks.js; the Mac's Design/FileLinks.swift): text whose
// file names are Pango links, and the activate-link handler that opens what a link names instead of
// letting GTK treat `slated-file://config` as a URI. Labels the window makes get the handler directly;
// libadwaita's rows and groups draw their title, subtitle and description in labels of their own, which
// `wireLinks` finds. The preferences UI test fails when a page shows a file's name that isn't a link.

import {fileLinkMarkup, isLinked, parseLinkUri} from '../filelinks.js';

/** {open(link), slateFound()}: opens a link's file; whether Slated finds a Slate config. Set by the window. */
let context = null;

export function setFileLinkContext(value) {
  context = value;
}

/** Which links to make: a Slate file only while there's a Slate config to open (isLinked). */
function linkOptions() {
  return {linked: link => isLinked(link, {slateFound: context?.slateFound?.() ?? true})};
}

/** `text` as markup: escaped, its file names links. */
export function linkedMarkup(text) {
  return fileLinkMarkup(text, linkOptions());
}

/** A label's activate-link: a file link opens its file (handled); any other URI is GTK's to open. */
export function activateLink(_label, uri) {
  const link = parseLinkUri(uri);
  if (!link) return false;
  context?.open(link);
  return true;
}

/**
 * Gives `widget` and every label in it (once each) the activate-link handler, so a row's own title and
 * subtitle labels open file links too. Returns `widget`.
 */
export function wireLinks(widget) {
  const walk = w => {
    // `in`, not typeof: a GObject wrapper may throw for a method its class doesn't have.
    if ('get_current_uri' in w && !w._slatedLinks) w._slatedLinks = w.connect('activate-link', activateLink);
    for (let child = w.get_first_child(); child; child = child.get_next_sibling()) walk(child);
  };
  walk(widget);
  return widget;
}

/** Shows `text` on a label (markup on) with its file names as links. */
export function setLinkedLabel(widget, text) {
  widget.set_use_markup(true);
  widget.set_label(linkedMarkup(text ?? ''));
  wireLinks(widget);
  return widget;
}

/**
 * A row's title and subtitle (plain text) with their file names as links: markup on, everything else
 * escaped. Leave one out to keep it. Returns the row.
 */
export function setLinkedRow(row, {title, subtitle} = {}) {
  row.set_use_markup(true);
  row._slatedLinkedText = {...row._slatedLinkedText};
  if (title !== undefined) {
    row.set_title(linkedMarkup(title));
    row._slatedLinkedText.title = title ?? '';
  }
  if (subtitle !== undefined) {
    row.set_subtitle(linkedMarkup(subtitle));
    row._slatedLinkedText.subtitle = subtitle ?? '';
  }
  return wireLinks(row);
}

/**
 * An Adw.PreferencesGroup's description with its file names as links. The group keeps the plain text
 * (what screen readers get); the label libadwaita shows it in gets the markup (`markup`, else the text's
 * links). Returns the group.
 */
export function setLinkedDescription(group, text, markup = null) {
  const plain = text ?? '';
  // Plain again while libadwaita sets the new text, so it's never parsed as markup.
  group._slatedDescriptionLabel?.set_use_markup(false);
  group.set_description(plain);
  group._slatedLinkedText = {description: plain};
  group._slatedDescriptionLabel ??= findLabel(group, plain);
  const shown = group._slatedDescriptionLabel;
  if (shown) {
    shown.set_use_markup(true);
    shown.set_label(plain ? markup ?? linkedMarkup(plain) : '');
    wireLinks(shown);
  }
  return group;
}

/** The label under `root` that shows `text`, or null. */
function findLabel(root, text) {
  if (!text) return null;
  for (let child = root.get_first_child(); child; child = child.get_next_sibling()) {
    if ('get_current_uri' in child && child.get_label() === text) return child;
    const found = findLabel(child, text);
    if (found) return found;
  }
  return null;
}
