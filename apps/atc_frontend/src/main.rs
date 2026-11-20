//! Tower window for one running AirTrafficControl server.
//!
//! `make serve` binds 127.0.0.1:7878. This program attaches, draws the
//! runway strips, and submits the same clearance commands the tower accepts.

mod protocol;
mod session;

use std::collections::HashSet;
use std::time::Duration;

use eframe::egui::{
    self, Align2, Color32, ComboBox, FontId, RichText, ScrollArea, SidePanel, TextEdit,
    TopBottomPanel, ViewportBuilder, ViewportCommand,
};
use protocol::{Aircraft, Hello, Incoming, Picture, RunwayInfo};
use session::{spawn, ServerEvent, Worker, WorkerCmd};

fn main() -> eframe::Result<()> {
    let mut args = std::env::args().skip(1);
    let host = args.next().unwrap_or_else(|| "127.0.0.1".into());
    let port = args.next().unwrap_or_else(|| "7878".into());
    if host == "-h" || host == "--help" {
        eprintln!("Usage: atc_frontend [HOST [PORT]]");
        eprintln!("Attaches to a tower started with: make serve");
        eprintln!("Default: 127.0.0.1 7878");
        std::process::exit(0);
    }

    let options = eframe::NativeOptions {
        viewport: ViewportBuilder::default()
            .with_inner_size([1200.0, 780.0])
            .with_min_inner_size([880.0, 560.0])
            .with_title("Tower front"),
        ..Default::default()
    };
    eframe::run_native(
        "Tower front",
        options,
        Box::new(move |cc| {
            style_context(&cc.egui_ctx);
            Ok(Box::new(AtcApp::attach_to(host, port)))
        }),
    )
}

fn style_context(ctx: &egui::Context) {
    let mut visuals = egui::Visuals::dark();
    visuals.window_fill = Color32::from_rgb(14, 20, 27);
    visuals.panel_fill = Color32::from_rgb(18, 26, 34);
    visuals.extreme_bg_color = Color32::from_rgb(10, 14, 18);
    visuals.faint_bg_color = Color32::from_rgb(24, 34, 44);
    visuals.override_text_color = Some(Color32::from_rgb(226, 232, 236));
    ctx.set_visuals(visuals);
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Intent {
    Departure,
    Arrival,
}

impl Intent {
    fn as_str(self) -> &'static str {
        match self {
            Intent::Departure => "departure",
            Intent::Arrival => "arrival",
        }
    }
}

enum Attach {
    Connecting,
    Live,
    Down(String),
}

struct AtcApp {
    host: String,
    port: String,
    attach: Attach,
    note: String,
    note_ok: bool,
    hello: Option<Hello>,
    picture: Option<Picture>,
    callsign: String,
    runway: String,
    intent: Intent,
    neighbor: String,
    accept_handoff: bool,
    worker: Option<Worker>,
}

impl AtcApp {
    fn attach_to(host: String, port: String) -> Self {
        let mut app = Self {
            host,
            port,
            attach: Attach::Connecting,
            note: String::new(),
            note_ok: true,
            hello: None,
            picture: None,
            callsign: "N123AB".into(),
            runway: String::new(),
            intent: Intent::Departure,
            neighbor: String::new(),
            accept_handoff: true,
            worker: None,
        };
        app.spawn_worker();
        app
    }

    fn endpoint(&self) -> String {
        let host = if self.host.trim() == "localhost" {
            "127.0.0.1"
        } else {
            self.host.trim()
        };
        format!("{host}:{}", self.port.trim())
    }

    fn spawn_worker(&mut self) {
        if let Some(worker) = self.worker.take() {
            let _ = worker.tx.send(WorkerCmd::Stop);
        }
        self.hello = None;
        self.picture = None;
        self.note.clear();
        self.attach = Attach::Connecting;
        self.worker = Some(spawn(self.endpoint()));
    }

    fn detach(&mut self) {
        if let Some(worker) = self.worker.take() {
            let _ = worker.tx.send(WorkerCmd::Stop);
        }
        self.attach = Attach::Down("detached".into());
    }

    fn drain(&mut self) {
        let Some(worker) = self.worker.as_mut() else {
            return;
        };
        let mut events = Vec::new();
        while let Ok(event) = worker.rx.try_recv() {
            events.push(event);
        }
        let finished = worker.handle.is_finished();
        let mut failed = false;
        for event in events {
            match event {
                ServerEvent::Failed(text) => {
                    self.attach = Attach::Down(text);
                    failed = true;
                }
                ServerEvent::Message(incoming) => self.apply(incoming),
            }
        }
        if failed {
            self.worker = None;
        } else if finished && !matches!(self.attach, Attach::Down(_)) {
            self.attach = Attach::Down("tower connection ended".into());
            self.worker = None;
        }
    }

    fn apply(&mut self, incoming: Incoming) {
        match incoming {
            Incoming::Hello(hello) => self.apply_hello(hello),
            Incoming::Snapshot(picture) => self.picture = Some(picture),
            Incoming::Result(outcome) => {
                self.note_ok = outcome.accepted;
                self.note = if outcome.accepted {
                    format!("Accepted  {}", outcome.summary)
                } else {
                    format!(
                        "Refused {}  {}",
                        outcome.reason.as_deref().unwrap_or("unknown"),
                        outcome.summary
                    )
                };
                if let Some(picture) = outcome.snapshot {
                    self.picture = Some(picture);
                }
            }
            Incoming::Problem(text) => {
                self.note_ok = false;
                self.note = text;
            }
        }
    }

    fn apply_hello(&mut self, hello: Hello) {
        let open: Vec<String> = hello
            .runways
            .iter()
            .filter(|runway| runway.designation != "closed")
            .map(|runway| runway.id.clone())
            .collect();
        if !open.iter().any(|id| id == &self.runway) {
            if let Some(first) = open.first() {
                self.runway = first.clone();
            }
        }
        let neighbors: Vec<String> = hello
            .neighbors
            .iter()
            .filter(|neighbor| neighbor.selected)
            .map(|neighbor| neighbor.icao.clone())
            .collect();
        if !neighbors.iter().any(|id| id == &self.neighbor) {
            self.neighbor = neighbors.first().cloned().unwrap_or_default();
        }
        self.hello = Some(hello);
        self.attach = Attach::Live;
    }

    fn send(&self, line: String) {
        if let Some(worker) = &self.worker {
            let _ = worker.tx.send(WorkerCmd::Line(line));
        }
    }

    fn live(&self) -> bool {
        matches!(self.attach, Attach::Live)
    }

    fn callsign(&self) -> String {
        self.callsign.trim().to_ascii_uppercase()
    }

    fn can_command(&self) -> bool {
        self.live() && valid_ident(&self.callsign())
    }

    fn select_aircraft(&mut self, aircraft: &Aircraft) {
        self.callsign = aircraft.id.clone();
        if let Some(runway) = &aircraft.runway {
            if runway_is_open(self.hello.as_ref(), runway) {
                self.runway = runway.clone();
            }
        }
        self.intent = if aircraft.intent.as_deref() == Some("arrival") {
            Intent::Arrival
        } else {
            Intent::Departure
        };
    }
}

impl eframe::App for AtcApp {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        self.drain();
        if let Some(hello) = &self.hello {
            ctx.send_viewport_cmd(ViewportCommand::Title(format!("Tower {}", hello.icao)));
        }
        self.top_bar(ctx);
        self.log_panel(ctx);
        self.pad(ctx);
        self.strips(ctx);
        ctx.request_repaint_after(Duration::from_millis(200));
    }
}

impl AtcApp {
    fn top_bar(&mut self, ctx: &egui::Context) {
        let status = self.status_line();
        let note = self.note.clone();
        let note_ok = self.note_ok;
        let attach = match &self.attach {
            Attach::Live => AttachKind::Live,
            Attach::Connecting => AttachKind::Connecting,
            Attach::Down(_) => AttachKind::Down,
        };
        TopBottomPanel::top("status").show(ctx, |ui| {
            ui.add_space(6.0);
            ui.horizontal_wrapped(|ui| {
                ui.label(RichText::new("TOWER").strong().size(18.0));
                ui.add(
                    TextEdit::singleline(&mut self.host)
                        .desired_width(140.0)
                        .hint_text("127.0.0.1"),
                );
                ui.add(
                    TextEdit::singleline(&mut self.port)
                        .desired_width(64.0)
                        .hint_text("7878"),
                );
                if ui.button("Attach").clicked() {
                    self.spawn_worker();
                }
                if self.worker.is_some() && ui.button("Detach").clicked() {
                    self.detach();
                }
                ui.label(status_color(attach, status));
            });
            if !note.is_empty() {
                let color = if note_ok {
                    Color32::from_rgb(126, 196, 138)
                } else {
                    Color32::from_rgb(214, 112, 104)
                };
                ui.label(RichText::new(note).monospace().color(color));
            }
            ui.label(
                RichText::new("Mock tower front. Not a live facility.")
                    .small()
                    .weak(),
            );
            ui.add_space(4.0);
        });
    }

    fn status_line(&self) -> String {
        match &self.attach {
            Attach::Connecting => format!("Attaching to {}", self.endpoint()),
            Attach::Down(text) => text.clone(),
            Attach::Live => {
                let Some(hello) = &self.hello else {
                    return format!("Attached {}", self.endpoint());
                };
                let computers = if hello.computers == 1 {
                    "1 computer".to_string()
                } else {
                    format!("{} computers", hello.computers)
                };
                let wind = hello
                    .wind
                    .as_ref()
                    .map(|wind| format!("   wind {wind}"))
                    .unwrap_or_default();
                let active = self
                    .picture
                    .as_ref()
                    .map(|picture| {
                        picture
                            .aircraft
                            .iter()
                            .filter(|aircraft| aircraft.phase != "gone")
                            .count()
                    })
                    .unwrap_or(0);
                format!(
                    "{}   {computers}   {active}/{} aircraft{wind}",
                    hello.icao, hello.max_aircraft
                )
            }
        }
    }

    fn log_panel(&self, ctx: &egui::Context) {
        let audit = self
            .picture
            .as_ref()
            .map(|picture| picture.audit.clone())
            .unwrap_or_default();
        TopBottomPanel::bottom("log")
            .resizable(true)
            .default_height(190.0)
            .show(ctx, |ui| {
                let issued = self
                    .picture
                    .as_ref()
                    .map(|picture| picture.issued.len())
                    .unwrap_or(0);
                ui.label(RichText::new(format!("Clearance log  ({issued} issued)")).strong());
                if audit.is_empty() {
                    ui.label(RichText::new("No clearances yet.").weak());
                    return;
                }
                ScrollArea::vertical().id_salt("log").show(ui, |ui| {
                    for entry in audit.iter().rev() {
                        let color = if entry.decision == "refused" {
                            Color32::from_rgb(214, 112, 104)
                        } else {
                            Color32::from_rgb(186, 214, 196)
                        };
                        let aircraft = entry.aircraft.as_deref().unwrap_or("-");
                        let reason = entry
                            .reason
                            .as_ref()
                            .map(|reason| format!("  ({reason})"))
                            .unwrap_or_default();
                        let runway = entry.runway.as_deref().unwrap_or("-");
                        ui.label(
                            RichText::new(format!(
                                "{:<8} {:<10} {:<6} {:<11} {}{}  {}",
                                entry.decision,
                                aircraft,
                                runway,
                                entry.command.kind,
                                entry.command.text,
                                reason,
                                entry.uid
                            ))
                            .monospace()
                            .color(color),
                        );
                    }
                });
            });
    }

    fn pad(&mut self, ctx: &egui::Context) {
        let runway_ids = open_runway_ids(self.hello.as_ref());
        let neighbors = selected_neighbors(self.hello.as_ref());
        let links = self
            .picture
            .as_ref()
            .map(|picture| picture.links.clone())
            .unwrap_or_default();
        let outside = unselected_neighbors(self.hello.as_ref());

        SidePanel::right("pad")
            .resizable(true)
            .default_width(300.0)
            .show(ctx, |ui| {
                ScrollArea::vertical().id_salt("pad").show(ui, |ui| {
                    ui.add_space(4.0);
                    ui.label(RichText::new("Clearance").strong().size(16.0));
                    ui.label("Call sign");
                    ui.add(
                        TextEdit::singleline(&mut self.callsign)
                            .desired_width(f32::INFINITY)
                            .font(egui::TextStyle::Monospace)
                            .hint_text("N123AB"),
                    );
                    if !self.callsign.trim().is_empty() && !valid_ident(&self.callsign()) {
                        ui.label(
                            RichText::new("Use 1 to 16 letters or digits.")
                                .small()
                                .color(Color32::from_rgb(214, 112, 104)),
                        );
                    }

                    ui.add_space(8.0);
                    ui.label("Assign to runway");
                    ComboBox::from_id_salt("assign-runway")
                        .selected_text(if self.runway.is_empty() {
                            "Runway".to_string()
                        } else {
                            self.runway.clone()
                        })
                        .width(ui.available_width())
                        .show_ui(ui, |ui| {
                            for id in &runway_ids {
                                ui.selectable_value(&mut self.runway, id.clone(), id);
                            }
                        });
                    ui.horizontal(|ui| {
                        ui.selectable_value(&mut self.intent, Intent::Departure, "Departure");
                        ui.selectable_value(&mut self.intent, Intent::Arrival, "Arrival");
                    });
                    let callsign = self.callsign();
                    let runway = self.runway.clone();
                    let intent = self.intent.as_str();
                    ui.label(
                        RichText::new(format!(
                            "assign {callsign} {} {intent}",
                            if runway.is_empty() {
                                "-"
                            } else {
                                runway.as_str()
                            }
                        ))
                        .monospace()
                        .weak(),
                    );
                    let can_command = self.can_command();
                    let can_assign = can_command && valid_ident(&self.runway);
                    let neighbor_ready = valid_ident(&self.neighbor);
                    let mut action = None;
                    if ui
                        .add_enabled(can_assign, egui::Button::new("Assign"))
                        .clicked()
                    {
                        action = Some(PadAction::Assign);
                    }
                    ui.add_space(6.0);
                    ui.horizontal_wrapped(|ui| {
                        if ui
                            .add_enabled(can_command, egui::Button::new("Hold short"))
                            .clicked()
                        {
                            action = Some(PadAction::HoldShort);
                        }
                        if ui
                            .add_enabled(can_command, egui::Button::new("Line up"))
                            .clicked()
                        {
                            action = Some(PadAction::LineUp);
                        }
                        if ui
                            .add_enabled(can_command, egui::Button::new("Takeoff"))
                            .clicked()
                        {
                            action = Some(PadAction::Takeoff);
                        }
                        if ui
                            .add_enabled(can_command, egui::Button::new("Land"))
                            .clicked()
                        {
                            action = Some(PadAction::Land);
                        }
                        if ui
                            .add_enabled(can_command, egui::Button::new("Go around"))
                            .clicked()
                        {
                            action = Some(PadAction::GoAround);
                        }
                        if ui
                            .add_enabled(can_command, egui::Button::new("Vacate"))
                            .clicked()
                        {
                            action = Some(PadAction::Vacate);
                        }
                    });

                    ui.add_space(12.0);
                    ui.separator();
                    ui.label(RichText::new("Handoff").strong());
                    if neighbors.is_empty() {
                        ui.label(RichText::new("No neighbor in range.").weak());
                    } else {
                        ComboBox::from_id_salt("handoff-neighbor")
                            .selected_text(if self.neighbor.is_empty() {
                                "Neighbor".to_string()
                            } else {
                                self.neighbor.clone()
                            })
                            .width(ui.available_width())
                            .show_ui(ui, |ui| {
                                for id in &neighbors {
                                    ui.selectable_value(&mut self.neighbor, id.clone(), id);
                                }
                            });
                        ui.checkbox(&mut self.accept_handoff, "Neighbor accepts");
                        if ui
                            .add_enabled(
                                can_command && neighbor_ready,
                                egui::Button::new("Hand off"),
                            )
                            .clicked()
                        {
                            action = Some(PadAction::Handoff);
                        }
                    }

                    ui.add_space(12.0);
                    ui.separator();
                    ui.label(RichText::new("Neighbor links").strong());
                    if links.is_empty() && outside.is_empty() {
                        ui.label(RichText::new("This airport has no neighbors.").weak());
                    }
                    let mut link_change = None;
                    for link in &links {
                        let place = neighbor_place(self.hello.as_ref(), &link.icao);
                        ui.horizontal(|ui| {
                            let state = if link.up {
                                "up"
                            } else if link.stale {
                                "down, stale"
                            } else {
                                "down"
                            };
                            let color = if link.up {
                                Color32::from_rgb(126, 196, 138)
                            } else {
                                Color32::from_rgb(214, 164, 84)
                            };
                            ui.label(RichText::new(format!("{}  {state}", link.icao)).color(color))
                                .on_hover_text(place);
                            let label = if link.up { "Mark down" } else { "Mark up" };
                            if ui
                                .add_enabled(self.live(), egui::Button::new(label))
                                .clicked()
                            {
                                link_change = Some((link.icao.clone(), !link.up));
                            }
                        });
                    }
                    for icao in &outside {
                        ui.label(
                            RichText::new(format!("{icao}  outside communications distance"))
                                .small()
                                .weak(),
                        );
                    }
                    self.finish_pad(action, link_change);
                });
            });
    }

    fn finish_pad(&self, action: Option<PadAction>, link_change: Option<(String, bool)>) {
        if let Some((icao, up)) = link_change {
            self.send(protocol::link(&icao, up));
        }
        let Some(action) = action else {
            return;
        };
        let callsign = self.callsign();
        let line = match action {
            PadAction::Assign => protocol::assign(&callsign, &self.runway, self.intent.as_str()),
            PadAction::HoldShort => protocol::hold_short(&callsign),
            PadAction::LineUp => protocol::line_up(&callsign),
            PadAction::Takeoff => protocol::takeoff(&callsign),
            PadAction::Land => protocol::land(&callsign),
            PadAction::GoAround => protocol::go_around(&callsign),
            PadAction::Vacate => protocol::vacate(&callsign),
            PadAction::Handoff => protocol::handoff(&callsign, &self.neighbor, self.accept_handoff),
        };
        self.send(line);
    }

    fn strips(&mut self, ctx: &egui::Context) {
        let hello = self.hello.clone();
        let picture = self.picture.clone();
        let selected = self.callsign();
        let mut picked = None;
        egui::CentralPanel::default().show(ctx, |ui| {
            ui.horizontal_wrapped(|ui| {
                ui.label(RichText::new("Strips").strong().size(16.0));
                legend(ui);
            });
            ui.add_space(6.0);
            let Some(hello) = hello else {
                ui.label("Waiting for the tower to accept the attach.");
                return;
            };
            ScrollArea::vertical().id_salt("strips").show(ui, |ui| {
                let mut shown = HashSet::new();
                for runway in &hello.runways {
                    runway_bay(
                        ui,
                        runway,
                        picture.as_ref(),
                        &selected,
                        &mut shown,
                        &mut picked,
                    );
                    ui.add_space(10.0);
                }
                let extras = picture.as_ref().map(|picture| {
                    picture
                        .aircraft
                        .iter()
                        .filter(|aircraft| !shown.contains(&aircraft.id))
                        .cloned()
                        .collect::<Vec<_>>()
                });
                if let Some(extras) = extras {
                    if !extras.is_empty() {
                        ui.label(RichText::new("Off the strips").strong());
                        for aircraft in extras {
                            let text = format!(
                                "    {:<10} {:<12} {}",
                                aircraft.id,
                                phase_label(&aircraft.phase),
                                intent_label(aircraft.intent.as_deref())
                            );
                            if strip_row(
                                ui,
                                selected == aircraft.id,
                                phase_color(&aircraft.phase),
                                &text,
                            ) {
                                picked = Some(aircraft.id);
                            }
                            ui.add_space(4.0);
                        }
                    }
                }
            });
        });
        if let Some(id) = picked {
            if let Some(aircraft) = self
                .picture
                .as_ref()
                .and_then(|picture| picture.aircraft.iter().find(|aircraft| aircraft.id == id))
                .cloned()
            {
                self.select_aircraft(&aircraft);
            } else {
                self.callsign = id;
            }
        }
    }
}

#[derive(Clone, Copy)]
enum PadAction {
    Assign,
    HoldShort,
    LineUp,
    Takeoff,
    Land,
    GoAround,
    Vacate,
    Handoff,
}

fn runway_bay(
    ui: &mut egui::Ui,
    runway: &RunwayInfo,
    picture: Option<&Picture>,
    selected: &str,
    shown: &mut HashSet<String>,
    picked: &mut Option<String>,
) {
    let closed = runway.designation == "closed";
    ui.horizontal(|ui| {
        ui.label(
            RichText::new(format!("RWY {}", runway.id))
                .strong()
                .size(18.0),
        );
        let designation = runway.designation.to_ascii_uppercase();
        let color = if closed {
            Color32::from_rgb(196, 112, 108)
        } else {
            Color32::from_rgb(150, 176, 196)
        };
        ui.label(RichText::new(designation).color(color));
        if !runway.independent {
            ui.label(RichText::new("dependent").small().weak());
        }
    });
    if !runway.intersects.is_empty() {
        ui.label(
            RichText::new(format!("intersects {}", runway.intersects.join(", ")))
                .small()
                .weak(),
        );
    }
    if closed {
        ui.label(RichText::new("closed").weak());
        return;
    }
    let queue = picture
        .and_then(|picture| {
            picture
                .queues
                .iter()
                .find(|queue| queue.runway == runway.id)
        })
        .map(|queue| queue.aircraft.clone())
        .unwrap_or_default();
    if queue.is_empty() {
        ui.label(RichText::new("empty").weak());
    }
    for (index, id) in queue.iter().enumerate() {
        shown.insert(id.clone());
        let aircraft = find_aircraft(picture, id);
        let phase = aircraft.map(|item| item.phase.as_str()).unwrap_or("queued");
        let intent = aircraft.and_then(|item| item.intent.as_deref());
        let text = format!(
            "{:>2}  {:<10} {:<12} {}",
            index + 1,
            id,
            phase_label(phase),
            intent_label(intent)
        );
        if strip_row(ui, selected == id, phase_color(phase), &text) {
            *picked = Some(id.clone());
        }
        ui.add_space(4.0);
    }
    if let Some(picture) = picture {
        for aircraft in &picture.aircraft {
            if aircraft.phase == "air" && aircraft.runway.as_deref() == Some(runway.id.as_str()) {
                if !shown.insert(aircraft.id.clone()) {
                    continue;
                }
                let text = format!(
                    "    {:<10} {:<12} {}",
                    aircraft.id,
                    phase_label(&aircraft.phase),
                    intent_label(aircraft.intent.as_deref())
                );
                if strip_row(
                    ui,
                    selected == aircraft.id,
                    phase_color(&aircraft.phase),
                    &text,
                ) {
                    *picked = Some(aircraft.id.clone());
                }
                ui.add_space(4.0);
            }
        }
    }
}

fn strip_row(ui: &mut egui::Ui, selected: bool, color: Color32, text: &str) -> bool {
    let width = ui.available_width().max(280.0);
    let (rect, response) = ui.allocate_exact_size(egui::vec2(width, 30.0), egui::Sense::click());
    if ui.is_rect_visible(rect) {
        let fill = if selected {
            Color32::from_rgb(38, 58, 74)
        } else if response.hovered() {
            Color32::from_rgb(30, 42, 54)
        } else {
            Color32::from_rgb(22, 32, 42)
        };
        ui.painter().rect_filled(rect, 4.0, fill);
        let bar = egui::Rect::from_min_max(rect.min, egui::pos2(rect.min.x + 4.0, rect.max.y));
        ui.painter().rect_filled(bar, 0.0, color);
        ui.painter().text(
            rect.min + egui::vec2(12.0, 7.0),
            Align2::LEFT_TOP,
            text,
            FontId::monospace(14.0),
            Color32::from_rgb(232, 236, 240),
        );
    }
    response.clicked()
}

fn legend(ui: &mut egui::Ui) {
    for (label, phase) in [
        ("queued", "queued"),
        ("hold short", "hold"),
        ("on runway", "occupying"),
        ("airborne", "air"),
        ("released", "gone"),
    ] {
        ui.label(RichText::new("▍").color(phase_color(phase)));
        ui.label(RichText::new(label).small());
    }
}

fn find_aircraft<'a>(picture: Option<&'a Picture>, id: &str) -> Option<&'a Aircraft> {
    picture.and_then(|picture| picture.aircraft.iter().find(|aircraft| aircraft.id == id))
}

fn phase_label(phase: &str) -> &'static str {
    match phase {
        "queued" => "queued",
        "hold" => "hold short",
        "occupying" => "on runway",
        "air" => "airborne",
        "gone" => "released",
        _ => "unknown",
    }
}

fn intent_label(intent: Option<&str>) -> &'static str {
    match intent {
        Some("departure") => "DEP",
        Some("arrival") => "ARR",
        _ => "",
    }
}

fn phase_color(phase: &str) -> Color32 {
    match phase {
        "occupying" => Color32::from_rgb(214, 168, 64),
        "hold" => Color32::from_rgb(72, 176, 196),
        "queued" => Color32::from_rgb(148, 164, 176),
        "air" => Color32::from_rgb(88, 186, 122),
        "gone" => Color32::from_rgb(110, 118, 126),
        _ => Color32::from_rgb(196, 112, 108),
    }
}

#[derive(Clone, Copy)]
enum AttachKind {
    Connecting,
    Live,
    Down,
}

fn status_color(attach: AttachKind, text: String) -> RichText {
    let color = match attach {
        AttachKind::Live => Color32::from_rgb(186, 214, 196),
        AttachKind::Connecting => Color32::from_rgb(214, 186, 120),
        AttachKind::Down => Color32::from_rgb(214, 112, 104),
    };
    RichText::new(text).color(color)
}

fn valid_ident(value: &str) -> bool {
    !value.is_empty() && value.len() <= 16 && value.bytes().all(|byte| byte.is_ascii_alphanumeric())
}

fn open_runway_ids(hello: Option<&Hello>) -> Vec<String> {
    hello
        .map(|hello| {
            hello
                .runways
                .iter()
                .filter(|runway| runway.designation != "closed")
                .map(|runway| runway.id.clone())
                .collect()
        })
        .unwrap_or_default()
}

fn runway_is_open(hello: Option<&Hello>, id: &str) -> bool {
    hello
        .map(|hello| {
            hello
                .runways
                .iter()
                .any(|runway| runway.id == id && runway.designation != "closed")
        })
        .unwrap_or(false)
}

fn selected_neighbors(hello: Option<&Hello>) -> Vec<String> {
    hello
        .map(|hello| {
            hello
                .neighbors
                .iter()
                .filter(|neighbor| neighbor.selected)
                .map(|neighbor| neighbor.icao.clone())
                .collect()
        })
        .unwrap_or_default()
}

fn unselected_neighbors(hello: Option<&Hello>) -> Vec<String> {
    hello
        .map(|hello| {
            hello
                .neighbors
                .iter()
                .filter(|neighbor| !neighbor.selected)
                .map(|neighbor| neighbor.icao.clone())
                .collect()
        })
        .unwrap_or_default()
}

fn neighbor_place(hello: Option<&Hello>, icao: &str) -> String {
    hello
        .and_then(|hello| {
            hello
                .neighbors
                .iter()
                .find(|neighbor| neighbor.icao == icao)
        })
        .map(|neighbor| format!("{:.3}, {:.3}", neighbor.latitude, neighbor.longitude))
        .unwrap_or_else(|| icao.to_string())
}
