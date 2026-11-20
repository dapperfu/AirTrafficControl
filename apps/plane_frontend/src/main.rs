//! Instrument panel for one configured aircraft.
//!
//! The window loads an aircraft TOML file, flies that pattern, and keeps the
//! radio transcript. It does not attach to the tower process.

use std::path::Path;
use std::time::Duration;

use eframe::egui::{
    self, Color32, RichText, ScrollArea, SidePanel, TextEdit, TopBottomPanel, ViewportBuilder,
    ViewportCommand,
};
use plane_frontend::instruments;
use plane_frontend::radio::{
    format_clock, parse_frequency_input, parse_request, same_channel, Request, Session,
    SpeakerKind, View,
};

fn main() -> eframe::Result<()> {
    let mut args = std::env::args().skip(1);
    let first = args.next();
    if matches!(first.as_deref(), Some("-h") | Some("--help")) {
        eprintln!("Usage: plane_frontend [AIRCRAFT_TOML]");
        eprintln!("Loads one aircraft file and opens the instrument panel.");
        eprintln!("Default: config/n123ab.toml");
        std::process::exit(0);
    }
    if args.next().is_some() {
        eprintln!("Usage: plane_frontend [AIRCRAFT_TOML]");
        std::process::exit(2);
    }
    let path = first.unwrap_or_else(default_config_path);

    let options = eframe::NativeOptions {
        viewport: ViewportBuilder::default()
            .with_inner_size([1280.0, 820.0])
            .with_min_inner_size([980.0, 640.0])
            .with_title("Plane instruments"),
        ..Default::default()
    };
    eframe::run_native(
        "Plane instruments",
        options,
        Box::new(move |cc| {
            style_context(&cc.egui_ctx);
            Ok(Box::new(PlaneApp::open(path)))
        }),
    )
}

fn style_context(ctx: &egui::Context) {
    let mut visuals = egui::Visuals::dark();
    visuals.window_fill = Color32::from_rgb(10, 12, 14);
    visuals.panel_fill = Color32::from_rgb(14, 16, 18);
    visuals.extreme_bg_color = Color32::from_rgb(6, 8, 10);
    visuals.faint_bg_color = Color32::from_rgb(24, 28, 32);
    visuals.override_text_color = Some(Color32::from_rgb(214, 220, 224));
    ctx.set_visuals(visuals);
}

fn default_config_path() -> String {
    let candidates = [
        Path::new("config/n123ab.toml").to_path_buf(),
        Path::new("../config/n123ab.toml").to_path_buf(),
        Path::new("../../config/n123ab.toml").to_path_buf(),
    ];
    for candidate in &candidates {
        if candidate.is_file() {
            return candidate.display().to_string();
        }
    }
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            let bundled = dir.join("../../../../config/n123ab.toml");
            if bundled.is_file() {
                return bundled.display().to_string();
            }
        }
    }
    "config/n123ab.toml".into()
}

struct PlaneApp {
    path: String,
    draft: String,
    standby_draft: String,
    note: String,
    note_ok: bool,
    show_tuned_only: bool,
    session: Option<Session>,
}

impl PlaneApp {
    fn open(path: String) -> Self {
        let mut app = Self {
            path,
            draft: String::new(),
            standby_draft: String::new(),
            note: String::new(),
            note_ok: true,
            show_tuned_only: false,
            session: None,
        };
        app.load_path();
        app
    }

    fn load_path(&mut self) {
        match Session::from_file(Path::new(self.path.trim())) {
            Ok(session) => {
                self.standby_draft = format!("{:.3}", session.view().standby_mhz);
                self.session = Some(session);
                self.note_ok = true;
                self.note = "Loaded the aircraft file.".into();
            }
            Err(error) => {
                self.note_ok = false;
                self.note = error;
            }
        }
    }

    fn submit_draft(&mut self) {
        let draft = self.draft.trim().to_string();
        if draft.is_empty() {
            return;
        }
        let Some(session) = self.session.as_mut() else {
            return;
        };
        if let Some(mhz) = parse_frequency_input(&draft) {
            session.tune(mhz);
            self.note_ok = true;
            self.note = format!("Tuned {mhz:.3}");
            self.draft.clear();
            return;
        }
        match parse_request(&draft) {
            Some(request) => {
                session.request(request);
                self.note_ok = true;
                self.note.clear();
                self.draft.clear();
            }
            None => {
                self.note_ok = false;
                self.note =
                    "Use a request such as taxi, takeoff, or land, or a frequency such as 118.700."
                        .into();
            }
        }
    }
}

impl eframe::App for PlaneApp {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        let dt = ctx.input(|input| input.stable_dt as f64);
        if let Some(session) = &mut self.session {
            session.advance(dt);
        }
        let view = self.session.as_ref().map(Session::view);
        if let Some(view) = &view {
            ctx.send_viewport_cmd(ViewportCommand::Title(format!(
                "{}  {}",
                view.call_sign, view.airport
            )));
        }
        self.top_bar(ctx, view.as_ref());
        self.radio_panel(ctx, view.as_ref());
        self.instrument_panel(ctx, view.as_ref());
        let paused = self
            .session
            .as_ref()
            .map(|session| session.paused)
            .unwrap_or(true);
        ctx.request_repaint_after(Duration::from_millis(if paused { 250 } else { 16 }));
    }
}

impl PlaneApp {
    fn top_bar(&mut self, ctx: &egui::Context, view: Option<&View>) {
        let note = self.note.clone();
        let note_ok = self.note_ok;
        TopBottomPanel::top("status").show(ctx, |ui| {
            ui.add_space(6.0);
            ui.horizontal_wrapped(|ui| {
                ui.label(RichText::new("PLANE").strong().size(18.0));
                if let Some(view) = view {
                    ui.label(RichText::new(&view.call_sign).monospace().size(16.0));
                    ui.label(RichText::new(&view.airport).strong());
                    ui.label(RichText::new(&view.phase).color(Color32::from_rgb(232, 186, 96)));
                    ui.label(
                        RichText::new(format_clock(view.clock_s))
                            .monospace()
                            .color(Color32::from_rgb(150, 210, 170)),
                    );
                }
                let paused = self
                    .session
                    .as_ref()
                    .map(|session| session.paused)
                    .unwrap_or(true);
                let pause_label = if paused { "Run" } else { "Pause" };
                if ui
                    .add_enabled(self.session.is_some(), egui::Button::new(pause_label))
                    .clicked()
                {
                    if let Some(session) = &mut self.session {
                        session.paused = !session.paused;
                    }
                }
                for rate in [1.0_f64, 5.0, 10.0, 20.0] {
                    let selected = self
                        .session
                        .as_ref()
                        .map(|session| (session.scale - rate).abs() < 0.01)
                        .unwrap_or(false);
                    if ui
                        .add_enabled(
                            self.session.is_some(),
                            egui::Button::selectable(selected, format!("{rate:.0}x")),
                        )
                        .clicked()
                    {
                        if let Some(session) = &mut self.session {
                            session.scale = rate;
                        }
                    }
                }
                if ui
                    .add_enabled(self.session.is_some(), egui::Button::new("Reset flight"))
                    .clicked()
                {
                    if let Some(session) = &mut self.session {
                        if let Err(error) = session.reset() {
                            self.note_ok = false;
                            self.note = error;
                        } else {
                            self.note_ok = true;
                            self.note = "Flight reset.".into();
                        }
                    }
                }
            });
            ui.horizontal_wrapped(|ui| {
                ui.label("Aircraft file");
                ui.add(
                    TextEdit::singleline(&mut self.path)
                        .desired_width(360.0)
                        .font(egui::TextStyle::Monospace)
                        .hint_text("config/n123ab.toml"),
                );
                if ui.button("Load").clicked() {
                    self.load_path();
                }
            });
            if !note.is_empty() {
                let color = if note_ok {
                    Color32::from_rgb(126, 196, 138)
                } else {
                    Color32::from_rgb(214, 112, 104)
                };
                ui.label(RichText::new(note).color(color));
            }
            ui.label(
                RichText::new(
                    "Mock cockpit for one aircraft file. Not a live radio or a live aircraft.",
                )
                .small()
                .weak(),
            );
            ui.add_space(4.0);
        });
    }

    fn instrument_panel(&mut self, ctx: &egui::Context, view: Option<&View>) {
        egui::CentralPanel::default().show(ctx, |ui| {
            let Some(view) = view else {
                ui.label("Load an aircraft file to open the instruments.");
                return;
            };
            ui.horizontal(|ui| {
                ui.label(RichText::new("Instruments").strong().size(16.0));
                ui.label(RichText::new(&view.detail).monospace());
            });
            ui.add_space(8.0);
            egui::ScrollArea::vertical()
                .id_salt("gauges")
                .show(ui, |ui| {
                    instruments::draw(ui, &view.gauges);
                });
        });
    }

    fn radio_panel(&mut self, ctx: &egui::Context, view: Option<&View>) {
        SidePanel::right("radio")
            .resizable(true)
            .default_width(460.0)
            .show(ctx, |ui| {
                let Some(view) = view else {
                    ui.label("The radio opens with the aircraft file.");
                    return;
                };
                radio_head(ui, view);
                ui.add_space(6.0);
                ui.horizontal(|ui| {
                    ui.label(format!("STBY  {:.3}", view.standby_mhz));
                    ui.add(
                        TextEdit::singleline(&mut self.standby_draft)
                            .desired_width(90.0)
                            .font(egui::TextStyle::Monospace)
                            .hint_text("121.900"),
                    );
                    if ui.button("Set").clicked() {
                        if let Some(mhz) = parse_frequency_input(&self.standby_draft) {
                            if let Some(session) = &mut self.session {
                                session.set_standby(mhz);
                            }
                            self.standby_draft = format!("{mhz:.3}");
                            self.note_ok = true;
                            self.note.clear();
                        } else {
                            self.note_ok = false;
                            self.note = "Standby must be a channel from 118.000 to 136.975.".into();
                        }
                    }
                    if ui.button("Flip").clicked() {
                        if let Some(session) = &mut self.session {
                            session.swap();
                            self.standby_draft = format!("{:.3}", session.view().standby_mhz);
                        }
                    }
                });
                ui.add_space(4.0);
                for service in &view.services {
                    let label = format!("{:.3}   {}", service.mhz, service.name);
                    let selected = same_channel(service.mhz, view.active_mhz);
                    if ui.selectable_label(selected, label).clicked() {
                        if let Some(session) = &mut self.session {
                            session.tune(service.mhz);
                        }
                    }
                }
                ui.add_space(6.0);
                ui.separator();
                ui.horizontal(|ui| {
                    let title = if self.show_tuned_only {
                        format!("{:.3}  {}", view.active_mhz, view.tuned_label)
                    } else {
                        "Full transcript".into()
                    };
                    ui.label(RichText::new(title).strong());
                    ui.checkbox(&mut self.show_tuned_only, "Only the tuned frequency");
                });
                let height = (ui.available_height() - 230.0).max(140.0);
                let mut shown = 0;
                ScrollArea::vertical()
                    .id_salt("transcript")
                    .stick_to_bottom(true)
                    .max_height(height)
                    .show(ui, |ui| {
                        ui.set_width(ui.available_width());
                        for line in &view.lines {
                            if self.show_tuned_only && !same_channel(line.mhz, view.active_mhz) {
                                continue;
                            }
                            shown += 1;
                            let header = if self.show_tuned_only {
                                format!("{}   {}", format_clock(line.time_s), line.speaker)
                            } else {
                                format!(
                                    "{}   {:.3}   {}",
                                    format_clock(line.time_s),
                                    line.mhz,
                                    line.speaker
                                )
                            };
                            let color = speaker_color(line.kind);
                            ui.label(RichText::new(header).monospace().small().color(color));
                            ui.label(RichText::new(&line.text).monospace().color(color));
                            ui.add_space(4.0);
                        }
                        if shown == 0 {
                            let quiet = if self.show_tuned_only {
                                "This frequency is quiet."
                            } else {
                                "No calls yet."
                            };
                            ui.label(RichText::new(quiet).weak());
                        }
                    });
                ui.separator();
                ui.label(RichText::new(&view.hint).small().weak());
                ui.add_space(4.0);
                ui.horizontal_wrapped(|ui| {
                    for (label, request) in REQUESTS {
                        if ui.button(*label).clicked() {
                            if let Some(session) = &mut self.session {
                                session.request(*request);
                                self.note_ok = true;
                                self.note.clear();
                            }
                        }
                    }
                });
                ui.add_space(6.0);
                ui.horizontal(|ui| {
                    let response = ui.add(
                        TextEdit::singleline(&mut self.draft)
                            .desired_width(ui.available_width() - 70.0)
                            .hint_text("taxi, takeoff, land, or 118.700"),
                    );
                    let enter = response.lost_focus()
                        && ui.input(|input| input.key_pressed(egui::Key::Enter));
                    if ui.button("Send").clicked() || enter {
                        self.submit_draft();
                    }
                });
            });
    }
}

const REQUESTS: &[(&str, Request)] = &[
    ("ATIS", Request::Atis),
    ("Pattern", Request::Pattern),
    ("Taxi", Request::Taxi),
    ("Hold short", Request::HoldShort),
    ("Takeoff", Request::Ready),
    ("Land", Request::Landing),
    ("Option", Request::Option),
    ("Touch and go", Request::TouchAndGo),
    ("Stop and go", Request::StopAndGo),
    ("Go around", Request::GoAround),
    ("Position", Request::Position),
    ("Frequency", Request::Frequency),
];

fn radio_head(ui: &mut egui::Ui, view: &View) {
    let (rect, _) =
        ui.allocate_exact_size(egui::vec2(ui.available_width(), 78.0), egui::Sense::hover());
    let painter = ui.painter();
    painter.rect_filled(rect, 6.0, Color32::from_rgb(6, 12, 10));
    let frequency_color = if view.tuned_live {
        Color32::from_rgb(110, 230, 150)
    } else {
        Color32::from_rgb(214, 176, 96)
    };
    painter.text(
        rect.min + egui::vec2(14.0, 8.0),
        egui::Align2::LEFT_TOP,
        "COM",
        egui::FontId::proportional(12.0),
        Color32::from_rgb(120, 150, 130),
    );
    painter.text(
        rect.min + egui::vec2(14.0, 24.0),
        egui::Align2::LEFT_TOP,
        format!("{:.3}", view.active_mhz),
        egui::FontId::monospace(28.0),
        frequency_color,
    );
    painter.text(
        rect.min + egui::vec2(150.0, 36.0),
        egui::Align2::LEFT_TOP,
        &view.tuned_label,
        egui::FontId::proportional(16.0),
        Color32::from_rgb(186, 214, 196),
    );
}

fn speaker_color(kind: SpeakerKind) -> Color32 {
    match kind {
        SpeakerKind::Pilot => Color32::from_rgb(186, 214, 196),
        SpeakerKind::Tower => Color32::from_rgb(240, 208, 140),
        SpeakerKind::Ground => Color32::from_rgb(150, 198, 220),
        SpeakerKind::Atis => Color32::from_rgb(196, 176, 230),
        SpeakerKind::Departure => Color32::from_rgb(220, 176, 140),
        SpeakerKind::Note => Color32::from_rgb(160, 148, 132),
    }
}
