// Copied images on disk (port of ClipboardImageStore.swift): one file each, named by the SHA-256 of
// its bytes, so the same image copied twice is one file. The folder is readable only by you (0700,
// files 0600): a screenshot can be as private as any text. GNOME apps offer copied images as PNG
// (image/png); a history from the Mac may also name TIFF files, which are kept and pasted as such.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

import {listDirectory, remove} from './files.js';

/** Bigger images aren't kept: a 5K screenshot as PNG is a few MB. */
export const MAX_IMAGE_BYTES = 20 * 1024 * 1024;

const PNG_SIGNATURE = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

/** A PNG's pixel size from its header (the IHDR chunk), without decoding it; null when it isn't a PNG. */
export function pngSize(bytes) {
  if (!bytes || bytes.length < 24) return null;
  if (PNG_SIGNATURE.some((value, i) => bytes[i] !== value)) return null;
  if (String.fromCharCode(bytes[12], bytes[13], bytes[14], bytes[15]) !== 'IHDR') return null;
  const u32 = (at) => bytes[at] * 0x1000000 + bytes[at + 1] * 0x10000 + bytes[at + 2] * 0x100 + bytes[at + 3];
  return {width: u32(16), height: u32(20)};
}

/** Only names this store writes, so nothing else in the folder is ever read or deleted. */
export function isImageFile(name) {
  return typeof name === 'string' && !name.includes('/') && !name.startsWith('.') && (name.endsWith('.png') || name.endsWith('.tiff'));
}

/** The MIME type an image file goes back on the clipboard as. */
export function imageMimeType(file) {
  return file.endsWith('.tiff') ? 'image/tiff' : 'image/png';
}

const PRIVATE_FILE = 0o600;
const PRIVATE_DIRECTORY = 0o700;

function setMode(path, mode) {
  Gio.File.new_for_path(path).set_attribute_uint32('unix::mode', mode, Gio.FileQueryInfoFlags.NONE, null);
}

export class ClipboardImageStore {
  /**
   * @param {string} directory  `clipboard-images` beside clipboard.json.
   * @param {{maxBytes?: number}} [options]
   */
  constructor(directory, {maxBytes = MAX_IMAGE_BYTES} = {}) {
    this.directory = directory;
    this.maxBytes = maxBytes;
  }

  /** The file's path, or null for a name this store doesn't write (a hand-edited history). */
  path(file) {
    return isImageFile(file) ? `${this.directory}/${file}` : null;
  }

  /** Whether an image's file is there. */
  has(image) {
    const path = this.path(image?.file);
    return path !== null && GLib.file_test(path, GLib.FileTest.EXISTS);
  }

  /**
   * What a copied PNG (a Uint8Array) would be stored as, without writing it: {image} with its file
   * name, size and pixel size; {tooLarge, bytes, width, height} over `maxBytes`; {failed, bytes}
   * when it isn't a PNG with pixels.
   */
  describe(bytes) {
    const size = pngSize(bytes);
    if (bytes.length > this.maxBytes) return {tooLarge: true, bytes: bytes.length, width: size?.width ?? 0, height: size?.height ?? 0};
    if (!size || !(size.width > 0) || !(size.height > 0)) return {failed: true, bytes: bytes.length};
    const hash = GLib.compute_checksum_for_data(GLib.ChecksumType.SHA256, bytes);
    return {image: {file: `${hash}.png`, width: size.width, height: size.height, bytes: bytes.length}};
  }

  /** Writes the image (unless the same bytes are there already), privately. False when it can't. */
  write(bytes, image) {
    const path = this.path(image.file);
    if (path === null) return false;
    try {
      GLib.mkdir_with_parents(this.directory, PRIVATE_DIRECTORY);
      setMode(this.directory, PRIVATE_DIRECTORY);
      if (!GLib.file_test(path, GLib.FileTest.EXISTS)) {
        Gio.File.new_for_path(path).replace_contents(
          bytes, null, false, Gio.FileCreateFlags.PRIVATE | Gio.FileCreateFlags.REPLACE_DESTINATION, null);
      }
      setMode(path, PRIVATE_FILE);
      return true;
    } catch {
      return false;
    }
  }

  /** The image's bytes, as they go back on the clipboard; null when its file is gone. */
  load(image) {
    const path = this.path(image?.file);
    if (path === null) return null;
    try {
      const [ok, bytes] = Gio.File.new_for_path(path).load_contents(null);
      return ok ? bytes : null;
    } catch {
      return null;
    }
  }

  /** Deletes these files (their items were deleted, pruned, pushed out or cleared). */
  remove(files) {
    for (const file of files) {
      const path = this.path(file);
      if (path !== null) remove(path);
    }
  }

  /**
   * Deletes every image file the history doesn't name (`keep`, a Set): left behind by a crash, or by
   * history that wasn't kept. Returns how many went.
   */
  removeFilesExcept(keep) {
    const orphans = listDirectory(this.directory).filter((name) => isImageFile(name) && !keep.has(name));
    this.remove(orphans);
    return orphans.length;
  }
}
