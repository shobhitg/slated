// Copied files on GNOME: reading what file managers put on the clipboard, writing it back, and what
// the picker shows for a file (its icon or thumbnail, size and kind).
//
// Nautilus (and Nemo, Caja, Thunar) offer copied files as `x-special/gnome-copied-files`: "copy" or
// "cut", then one URI per line. Most also offer `text/uri-list` (RFC 2483: one URI per line, CRLF,
// `#` comments), the only type Dolphin and Qt apps offer. Only local `file://` URIs count, so a copy
// from a network share (smb://, sftp://) stays text.
//
// St.Clipboard reads any type (`get_content`) but writes one per copy (`set_content` makes a
// Meta.SelectionSourceMemory with a single type), so a files item goes back as
// `x-special/gnome-copied-files`, the type Nautilus pastes files from.
//
// The parsing and URIs are pure; the rest reads file information through Gio, cheaply: one stat
// per file, a type guessed from the name (no sniffing of contents), and GNOME's thumbnail cache.

import GdkPixbuf from 'gi://GdkPixbuf';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

export const COPIED_FILES = 'x-special/gnome-copied-files';
export const URI_LIST = 'text/uri-list';
/** The types a copy of files comes as, the one with the most to say first. */
export const FILES_MIME_TYPES = Object.freeze([COPIED_FILES, URI_LIST]);

// --- URIs (pure) -----------------------------------------------------------------------------------

/** Bytes GLib leaves as they are in a file URI's path (g_filename_to_uri): unreserved, plus /&=:@+$,!'()*~. */
const PATH_SAFE = /[A-Za-z0-9\-._~!$&'()*+,=:@/]/;
const utf8 = new TextEncoder();

/** A file URI for an absolute path, escaped the way GLib escapes it (so thumbnails match). */
export function fileUri(path) {
  let out = 'file://';
  for (const byte of utf8.encode(path)) {
    const ch = String.fromCharCode(byte);
    out += byte < 0x80 && PATH_SAFE.test(ch) ? ch : `%${byte.toString(16).toUpperCase().padStart(2, '0')}`;
  }
  return out;
}

/**
 * The local path a `file://` URI names (percent-decoded, UTF-8), or null: another scheme, a remote
 * host, a relative path, or a name that isn't UTF-8 (JSON couldn't hold it).
 */
export function pathFromFileUri(uri) {
  const match = /^file:\/\/([^/]*)(\/[^#]*)$/i.exec(String(uri).trim());
  if (!match || !['', 'localhost'].includes(match[1].toLowerCase())) return null;
  const encoded = match[2];
  const bytes = [];
  for (const [i, part] of encoded.split('%').entries()) {
    let rest = part;
    if (i > 0) {
      if (!/^[0-9a-fA-F]{2}/.test(part)) return null;
      bytes.push(parseInt(part.slice(0, 2), 16));
      rest = part.slice(2);
    }
    bytes.push(...utf8.encode(rest));
  }
  if (bytes.includes(0)) return null;
  try {
    return new TextDecoder('utf-8', {fatal: true}).decode(new Uint8Array(bytes));
  } catch {
    return null;
  }
}

/**
 * The local files a copy names, in order and once each: `x-special/gnome-copied-files` or
 * `text/uri-list` text. Other URIs (web links, network shares) are left out.
 */
export function parseCopiedFiles(text) {
  const paths = [];
  for (const line of String(text ?? '').split(/\r?\n/)) {
    const entry = line.trim();
    if (entry === '' || entry.startsWith('#')) continue;
    const path = pathFromFileUri(entry);
    if (path !== null && !paths.includes(path)) paths.push(path);
  }
  return paths;
}

/** What goes on the clipboard for these files: Nautilus's "copy" list. */
export function copiedFilesText(paths) {
  return ['copy', ...paths.map(fileUri)].join('\n');
}

// --- Files on disk -----------------------------------------------------------------------------------

/** Whether a file (or folder) is still there. */
export function fileExists(path) {
  try {
    return GLib.file_test(path, GLib.FileTest.EXISTS);
  } catch {
    return false;
  }
}

/**
 * What the picker shows about a file, from one stat: {isDirectory, size, contentType}, the type
 * guessed from its name; null when it's gone.
 */
export function describeFile(path) {
  try {
    const info = Gio.File.new_for_path(path).query_info(
      'standard::type,standard::size,standard::fast-content-type', Gio.FileQueryInfoFlags.NONE, null);
    const isDirectory = info.get_file_type() === Gio.FileType.DIRECTORY;
    const contentType = isDirectory ? 'inode/directory' : info.get_attribute_string('standard::fast-content-type') ?? 'application/octet-stream';
    return {isDirectory, size: isDirectory ? null : info.get_size(), contentType};
  } catch {
    return null;
  }
}

/** A file's kind in words ("PDF document", "Folder"), as Files says it. */
export function fileKind(contentType) {
  try {
    return Gio.content_type_get_description(contentType) || '';
  } catch {
    return '';
  }
}

/** The theme's icon for a type of file (a Gio.Icon). */
export function typeIcon(contentType) {
  try {
    return Gio.content_type_get_icon(contentType);
  } catch {
    return Gio.ThemedIcon.new('text-x-generic');
  }
}

/** GNOME's thumbnail folders, smallest first (the freedesktop thumbnail spec). */
const THUMBNAIL_SIZES = Object.freeze(['normal', 'large', 'x-large', 'xx-large']);

/**
 * A thumbnail GNOME already made for the file (Files makes them as you browse), or null: the
 * smallest that's at least `size` pixels (normal 128, large 256…), else the biggest there is.
 */
export function thumbnailPath(path, size = 128) {
  try {
    const hash = GLib.compute_checksum_for_string(GLib.ChecksumType.MD5, fileUri(path), -1);
    const root = `${GLib.get_user_cache_dir()}/thumbnails`;
    const first = Math.max(THUMBNAIL_SIZES.findIndex((_, i) => 128 * 2 ** i >= size), 0);
    const order = [...THUMBNAIL_SIZES.slice(first), ...THUMBNAIL_SIZES.slice(0, first).reverse()];
    for (const folder of order) {
      const candidate = `${root}/${folder}/${hash}.png`;
      if (GLib.file_test(candidate, GLib.FileTest.EXISTS)) return candidate;
    }
  } catch {
    // No thumbnail, then.
  }
  return null;
}

/** An image file's pixel size from its header (GdkPixbuf reads no further); null when it isn't one. */
export function imageFileSize(path) {
  try {
    const [format, width, height] = GdkPixbuf.Pixbuf.get_file_info(path);
    return format && width > 0 && height > 0 ? {width, height} : null;
  } catch {
    return null;
  }
}
