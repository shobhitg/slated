// Settings → About: the mark, version, credits and license (port of AboutPane.swift), plus GNOME's
// own About dialog with debug information for bug reports.

import Adw from 'gi://Adw';
import Gtk from 'gi://Gtk';
import Cairo from 'cairo';

import {box, label, button, group, launchUri, roundedRect} from './widgets.js';

const STOPS = [[0.29, 0.55, 1.0], [0.45, 0.38, 1.0], [0.76, 0.40, 0.98]];
export const REPOSITORY = 'https://github.com/shobhit-aida/slated';

/** Slated's mark: tiled window panes on the accent gradient squircle (SlatedMark.swift). */
export function slatedMark(size = 96) {
  const area = new Gtk.DrawingArea({content_width: size, content_height: size, halign: Gtk.Align.CENTER});
  area.set_draw_func((_area, cr, w, h) => {
    const s = Math.min(w, h);
    const x0 = (w - s) / 2;
    const y0 = (h - s) / 2;
    const gradient = new Cairo.LinearGradient(x0, y0, x0 + s, y0 + s);
    STOPS.forEach(([r, g, b], i) => gradient.addColorStopRGB(i / (STOPS.length - 1), r, g, b));
    roundedRect(cr, x0, y0, s, s, s * 0.27);
    cr.setSource(gradient);
    cr.fillPreserve();
    const shine = new Cairo.LinearGradient(0, y0, 0, y0 + s / 2);
    shine.addColorStopRGBA(0, 1, 1, 1, 0.28);
    shine.addColorStopRGBA(1, 1, 1, 1, 0);
    cr.setSource(shine);
    cr.fill();
    const inset = s * 0.2;
    const gap = s * 0.07;
    const inner = s - inset * 2;
    const leftWidth = (inner - gap) * 0.56;
    const rightWidth = inner - gap - leftWidth;
    const halfHeight = (inner - gap) / 2;
    const radius = s * 0.07;
    roundedRect(cr, x0 + inset, y0 + inset, leftWidth, inner, radius);
    cr.setSourceRGBA(1, 1, 1, 1);
    cr.fill();
    roundedRect(cr, x0 + inset + leftWidth + gap, y0 + inset, rightWidth, halfHeight, radius);
    cr.setSourceRGBA(1, 1, 1, 0.78);
    cr.fill();
    roundedRect(cr, x0 + inset + leftWidth + gap, y0 + inset + halfHeight + gap, rightWidth, halfHeight, radius);
    cr.setSourceRGBA(1, 1, 1, 0.5);
    cr.fill();
    cr.$dispose();
  });
  return area;
}

export function createAboutPane(ctx) {
  const model = ctx.model;
  const version = () => model.build?.version ?? ctx.ext.metadata?.['version-name'] ?? 'Development build';

  const prefs = new Adw.PreferencesPage();
  const hero = group();
  const column = box('vertical', 10);
  column.set_margin_top(12);
  column.append(slatedMark(96));
  const name = label('Slated', {classes: ['title-1']});
  name.set_xalign(0.5);
  column.append(name);
  const versionLabel = label('', {classes: ['slated-pill', 'dim']});
  versionLabel.set_halign(Gtk.Align.CENTER);
  column.append(versionLabel);
  const blurb = label('Keyboard-first window management, a Hyper key and text expansion — for GNOME, from the same configuration as the Mac app.',
    {wrap: true, classes: ['dim-label']});
  blurb.set_xalign(0.5);
  blurb.set_justify(Gtk.Justification.CENTER);
  blurb.set_max_width_chars(52);
  column.append(blurb);
  hero.add(column);
  prefs.add(hero);

  const credits = group();
  const slate = new Adw.ActionRow({
    use_markup: false,
    title: 'Inspired by Slate by Jigish Patel',
    subtitle: "Slate pioneered configurable, keyboard-driven window management. Slated is an independent reimplementation and contains none of Slate's code.",
  });
  slate.set_subtitle_lines(0);
  slate.add_suffix(button('Slate on GitHub', () => launchUri('https://github.com/jigish/slate', prefs), {classes: ['flat']}));
  credits.add(slate);
  const license = new Adw.ActionRow({use_markup: false, title: 'MIT License', subtitle: 'Slated is free and open source. Use it, change it and share it.'});
  credits.add(license);
  const more = new Adw.ActionRow({use_markup: false, title: 'Credits, links and debug information', activatable: true});
  more.add_suffix(new Gtk.Image({icon_name: 'go-next-symbolic'}));
  more.connect('activated', () => {
    const build = model.build ?? {};
    const summary = model.summary();
    const dialog = new Adw.AboutDialog({
      application_name: 'Slated',
      version: version(),
      developer_name: 'The Slated authors',
      license_type: Gtk.License.MIT_X11,
      website: REPOSITORY,
      issue_url: `${REPOSITORY}/issues`,
      comments: 'Keyboard-first window management, a Hyper key and text expansion. A modern successor to Slate.',
      debug_info: [
        `Version: ${version()}`, `Commit: ${build.commit ?? 'unknown'}`, `Built: ${build.builtAt ?? 'unknown'}`,
        `Extension: ${ctx.ext.uuid} (${model.shell.state})`, `Status: ${summary.title}`, `Session: ${model.status.session ?? 'none'}`,
        `Hyper: ${model.status.hyper.mode}${model.status.hyper.active ? ' (active)' : ''}`,
        `Hotstrings: ${model.status.hotstrings.engine}, ${model.status.hotstrings.count}`,
        `Config: ${ctx.paths.configFile}`, `Settings: ${ctx.paths.settingsFile}`, `Log: ${ctx.paths.logFile}`,
      ].join('\n'),
      debug_info_filename: 'slated-debug-info.txt',
    });
    dialog.present(ctx.window);
    model.log('ui.about');
  });
  credits.add(more);
  prefs.add(credits);

  const sync = () => versionLabel.set_label(model.build?.commit ? `${version()} · ${model.build.commit}` : version());
  model.on('status', sync);
  sync();

  const page = new Adw.NavigationPage({title: 'About', tag: 'about'});
  const toolbar = new Adw.ToolbarView({content: prefs});
  toolbar.add_top_bar(new Adw.HeaderBar());
  page.set_child(toolbar);
  return {id: 'about', title: 'About', iconName: 'help-about-symbolic', page, badge: () => null};
}
