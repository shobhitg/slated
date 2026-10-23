// The preferences window's stylesheet. Uses libadwaita's named colors (@accent_color, @success_color…)
// rather than CSS variables, which GTK only supports from 4.16 (GNOME 47); libadwaita 1.6–1.8 still
// define the named colors.

import Gdk from 'gi://Gdk';
import Gtk from 'gi://Gtk';

const CSS = `
.slated-keycap {
  min-width: 14px;
  padding: 1px 6px;
  border-radius: 5px;
  background-color: alpha(currentColor, 0.07);
  border: 1px solid alpha(currentColor, 0.16);
  box-shadow: inset 0 -1px alpha(currentColor, 0.16);
  font-size: 0.85em;
  font-weight: 600;
}
.slated-keycap.hyper { color: @accent_color; border-color: alpha(@accent_color, 0.45); }
.slated-keycap.large { min-width: 26px; min-height: 26px; padding: 4px 10px; border-radius: 8px; font-size: 1.15em; }
.slated-keycaps.dim { opacity: 0.55; }

.slated-pill { padding: 1px 8px; border-radius: 99px; font-size: 0.8em; font-weight: 700; }
.slated-pill.success { color: @success_color; background-color: alpha(@success_color, 0.12); }
.slated-pill.warning { color: @warning_color; background-color: alpha(@warning_color, 0.14); }
.slated-pill.error { color: @error_color; background-color: alpha(@error_color, 0.12); }
.slated-pill.accent { color: @accent_color; background-color: alpha(@accent_color, 0.12); }
.slated-pill.dim { color: alpha(currentColor, 0.65); background-color: alpha(currentColor, 0.07); }

.slated-badge { font-size: 0.8em; font-weight: 700; padding: 0 7px; border-radius: 99px;
  background-color: alpha(currentColor, 0.08); }
.slated-badge.warning { color: @warning_color; background-color: alpha(@warning_color, 0.16); }

.slated-notice { padding: 12px 14px; }
.slated-notice.info > image { color: @accent_color; }
.slated-notice.ok > image { color: @success_color; }
.slated-notice.warning > image { color: @warning_color; }
.slated-notice.error > image { color: @error_color; }

.slated-hero { padding: 22px 24px; }
.slated-hero .slated-greeting { color: @accent_color; font-weight: 700; font-size: 0.8em; letter-spacing: 1px; }

.slated-trigger { font-family: monospace; color: @accent_color; background-color: alpha(@accent_color, 0.1);
  border-radius: 6px; padding: 1px 6px; }
.slated-mono, .slated-mono text { font-family: monospace; }
.slated-mono-subtitle .subtitle { font-family: monospace; }
.slated-mono-title .title { font-family: monospace; }
.slated-invalid .subtitle { color: @error_color; opacity: 1; }
.slated-warning-row .subtitle { color: @warning_color; opacity: 1; }
.slated-warning-text { color: @warning_color; }
.slated-error-text { color: @error_color; }

.slated-preview { border-radius: 12px; background-color: alpha(currentColor, 0.04); }
.slated-preview-message { padding: 6px 12px; border-radius: 10px; }

.slated-preset { padding: 3px; min-width: 0; min-height: 0; border-radius: 7px; }
.slated-preset.selected { background-color: alpha(@accent_color, 0.16); box-shadow: inset 0 0 0 1px @accent_color; }

.slated-recorder { min-height: 30px; padding: 2px 10px; }
.slated-recorder.recording { box-shadow: inset 0 0 0 2px @accent_color; }

.slated-textview { padding: 8px; border-radius: 10px; }
.slated-textview text { background-color: transparent; }

.slated-sidebar-status { padding: 10px 16px; font-size: 0.85em; }
`;

let installed = null;

/** Adds the stylesheet to the display once per process. */
export function installStyles() {
  if (installed) return;
  const provider = new Gtk.CssProvider();
  if ('load_from_string' in provider) provider.load_from_string(CSS); // GTK 4.12+ (GNOME 46 has 4.14)
  else provider.load_from_data(CSS, -1);
  Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
  installed = provider;
}
