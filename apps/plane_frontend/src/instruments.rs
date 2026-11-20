//! Six flight instruments drawn from the point-mass state.
//!
//! There is no map. Airspeed is ground speed because the model has no wind.

use eframe::egui::{self, pos2, vec2, Align2, Color32, FontId, Painter, Pos2, Rect, Sense, Stroke};

use crate::sim::Gauges;

fn pen(width: f32, color: Color32) -> Stroke {
    Stroke::new(width, color)
}

const FACE: Color32 = Color32::from_rgb(12, 14, 16);
const METAL: Color32 = Color32::from_rgb(32, 36, 40);
const BEZEL: Color32 = Color32::from_rgb(58, 64, 70);
const MARK: Color32 = Color32::from_rgb(214, 220, 216);
const DIM: Color32 = Color32::from_rgb(150, 158, 164);
const AMBER: Color32 = Color32::from_rgb(232, 164, 72);
const SKY: Color32 = Color32::from_rgb(58, 122, 184);
const GROUND: Color32 = Color32::from_rgb(146, 96, 54);
const ARC: Color32 = Color32::from_rgb(78, 186, 112);
const BUG: Color32 = Color32::from_rgb(120, 210, 220);

pub fn draw(ui: &mut egui::Ui, gauges: &Gauges) {
    ui.horizontal_wrapped(|ui| {
        ui.spacing_mut().item_spacing = vec2(14.0, 8.0);
        gauge(
            ui,
            "AIRSPEED",
            &format!("{:.0} KT", gauges.airspeed_kt),
            |painter, center, radius| {
                draw_airspeed(painter, center, radius, gauges);
            },
        );
        gauge(
            ui,
            "ATTITUDE",
            &format!("P {:+.0}   B {:+.0}", gauges.pitch_deg, gauges.bank_deg),
            |painter, center, radius| {
                draw_attitude(painter, center, radius, gauges.pitch_deg, gauges.bank_deg);
            },
        );
        gauge(
            ui,
            "ALTIMETER",
            &format!("{:.0} FT", gauges.altitude_ft),
            |painter, center, radius| {
                draw_altimeter(painter, center, radius, gauges.altitude_ft);
            },
        );
        gauge(
            ui,
            "TURN",
            &format!("{:+.1} DEG/S", gauges.turn_rate_deg_s),
            |painter, center, radius| {
                draw_turn(painter, center, radius, gauges.turn_rate_deg_s);
            },
        );
        gauge(
            ui,
            "HEADING",
            &format!("{:03.0}", gauges.heading_deg.rem_euclid(360.0)),
            |painter, center, radius| {
                draw_heading(
                    painter,
                    center,
                    radius,
                    gauges.heading_deg,
                    gauges.runway_heading_deg,
                );
            },
        );
        gauge(
            ui,
            "VERTICAL SPEED",
            &format!("{:+.0} FPM", gauges.vertical_fpm),
            |painter, center, radius| {
                draw_vertical_speed(
                    painter,
                    center,
                    radius,
                    gauges.vertical_fpm,
                    gauges.vertical_limit_fpm,
                );
            },
        );
    });
}

fn gauge(ui: &mut egui::Ui, title: &str, value: &str, draw_face: impl FnOnce(&Painter, Pos2, f32)) {
    let (rect, _) = ui.allocate_exact_size(vec2(214.0, 252.0), Sense::hover());
    let center = pos2(rect.center().x, rect.min.y + 104.0);
    let radius = 96.0;
    {
        let painter = ui.painter();
        painter.circle_filled(center, radius + 8.0, METAL);
        draw_face(painter, center, radius);
    }
    let painter = ui.painter();
    painter.circle_stroke(center, radius + 3.0, pen(8.0, BEZEL));
    painter.circle_stroke(
        center,
        radius - 1.0,
        pen(1.0, Color32::from_rgb(150, 158, 166)),
    );
    painter.text(
        pos2(rect.center().x, rect.min.y + 214.0),
        Align2::CENTER_TOP,
        title,
        FontId::proportional(13.0),
        DIM,
    );
    painter.text(
        pos2(rect.center().x, rect.min.y + 232.0),
        Align2::CENTER_TOP,
        value,
        FontId::monospace(14.0),
        Color32::from_rgb(232, 236, 230),
    );
}

fn draw_airspeed(painter: &Painter, center: Pos2, radius: f32, gauges: &Gauges) {
    painter.circle_filled(center, radius, FACE);
    let white_start = sweep(gauges.taxi_kt, 200.0);
    let white_end = sweep(gauges.rotation_kt, 200.0);
    let green_end = sweep(gauges.pattern_kt, 200.0);
    draw_arc(
        painter,
        center,
        radius * 0.9,
        white_start,
        white_end,
        pen(4.0, MARK),
    );
    draw_arc(
        painter,
        center,
        radius * 0.9,
        white_end,
        green_end,
        pen(4.0, ARC),
    );
    for kt in (0..=200).step_by(20) {
        let angle = sweep(kt as f64, 200.0);
        let inner = if kt % 40 == 0 {
            radius * 0.76
        } else {
            radius * 0.84
        };
        painter.line_segment(
            [
                from_up(center, angle, inner),
                from_up(center, angle, radius * 0.92),
            ],
            pen(1.4, MARK),
        );
        if kt % 40 == 0 && kt > 0 && kt < 200 {
            painter.text(
                from_up(center, angle, radius * 0.60),
                Align2::CENTER_CENTER,
                format!("{kt}"),
                FontId::monospace(12.0),
                MARK,
            );
        }
    }
    let needle = sweep(gauges.airspeed_kt, 200.0);
    painter.line_segment(
        [center, from_up(center, needle, radius * 0.72)],
        pen(2.6, AMBER),
    );
    painter.circle_filled(center, 4.0, AMBER);
}

fn draw_attitude(painter: &Painter, center: Pos2, radius: f32, pitch_deg: f64, bank_deg: f64) {
    let pitch_px = pitch_deg as f32 * (radius / 30.0);
    let bank = (bank_deg as f32).to_radians();
    let sin_b = bank.sin();
    let cos_b = bank.cos();
    painter.circle_filled(center, radius, SKY);
    let rows = radius.floor() as i32;
    for y in -rows..=rows {
        let dy = y as f32;
        let half_sq = radius * radius - dy * dy;
        if half_sq <= 0.0 {
            continue;
        }
        let half = half_sq.sqrt();
        if sin_b.abs() < 0.02 {
            let above = -dy * cos_b + pitch_px;
            if above < 0.0 {
                paint_span(painter, center, dy, -half, half, GROUND);
            }
        } else {
            let dx_hit = (pitch_px - dy * cos_b) / sin_b;
            let (ground_from, ground_to) = if sin_b > 0.0 {
                (dx_hit.max(-half), half)
            } else {
                (-half, dx_hit.min(half))
            };
            paint_span(painter, center, dy, ground_from, ground_to, GROUND);
        }
    }
    if let Some((start, end)) = horizon_segment(center, radius - 2.0, pitch_px, bank_deg as f32) {
        painter.line_segment([start, end], pen(2.0, Color32::WHITE));
    }
    let pixels_per_degree = radius / 30.0;
    for degrees in [-20.0_f32, -10.0, 10.0, 20.0] {
        let shifted = pitch_px - degrees * pixels_per_degree;
        if let Some((start, end)) = horizon_segment(center, radius - 2.0, shifted, bank_deg as f32)
        {
            let mid = start + (end - start) * 0.5;
            let left = mid + (start - mid) * 0.28;
            let right = mid + (end - mid) * 0.28;
            painter.line_segment([left, right], pen(1.5, Color32::WHITE));
        }
    }
    for degrees in [-30, -20, -10, 0, 10, 20, 30] {
        let angle = (degrees as f32).to_radians();
        let outer = radius - 8.0;
        let inner = if degrees == 0 {
            radius - 22.0
        } else {
            radius - 16.0
        };
        painter.line_segment(
            [
                center + vec2(angle.sin() * inner, -angle.cos() * inner),
                center + vec2(angle.sin() * outer, -angle.cos() * outer),
            ],
            pen(if degrees == 0 { 2.0 } else { 1.2 }, Color32::WHITE),
        );
    }
    let pointer = (bank_deg as f32).to_radians();
    painter.line_segment(
        [
            center
                + vec2(
                    pointer.sin() * (radius - 28.0),
                    -pointer.cos() * (radius - 28.0),
                ),
            center
                + vec2(
                    pointer.sin() * (radius - 10.0),
                    -pointer.cos() * (radius - 10.0),
                ),
        ],
        pen(3.0, AMBER),
    );
    let span = radius * 0.46;
    painter.line_segment(
        [
            center + vec2(-span, 0.0),
            center + vec2(-radius * 0.12, 0.0),
        ],
        pen(3.0, AMBER),
    );
    painter.line_segment(
        [center + vec2(radius * 0.12, 0.0), center + vec2(span, 0.0)],
        pen(3.0, AMBER),
    );
    painter.line_segment(
        [center, center + vec2(0.0, -radius * 0.18)],
        pen(3.0, AMBER),
    );
    painter.circle_filled(center, 3.0, AMBER);
}

fn draw_altimeter(painter: &Painter, center: Pos2, radius: f32, altitude_ft: f64) {
    painter.circle_filled(center, radius, FACE);
    for number in 0..10 {
        let angle = number as f32 * 36.0;
        painter.line_segment(
            [
                from_up(center, angle, radius * 0.84),
                from_up(center, angle, radius * 0.93),
            ],
            pen(1.5, MARK),
        );
        painter.text(
            from_up(center, angle, radius * 0.68),
            Align2::CENTER_CENTER,
            format!("{number}"),
            FontId::monospace(14.0),
            MARK,
        );
    }
    let altitude = altitude_ft.max(0.0);
    let hundreds = (altitude / 1000.0).rem_euclid(1.0) as f32 * 360.0;
    let thousands = (altitude / 10000.0).rem_euclid(1.0) as f32 * 360.0;
    painter.line_segment(
        [center, from_up(center, thousands, radius * 0.42)],
        pen(3.4, MARK),
    );
    painter.line_segment(
        [center, from_up(center, hundreds, radius * 0.70)],
        pen(2.2, AMBER),
    );
    painter.circle_filled(center, 4.0, AMBER);
}

fn draw_heading(
    painter: &Painter,
    center: Pos2,
    radius: f32,
    heading_deg: f64,
    runway_heading_deg: f64,
) {
    painter.circle_filled(center, radius, FACE);
    for degrees in (0..360).step_by(5) {
        let relative = (degrees as f64 - heading_deg).rem_euclid(360.0) as f32;
        let inner = if degrees % 30 == 0 {
            radius * 0.74
        } else if degrees % 10 == 0 {
            radius * 0.82
        } else {
            radius * 0.88
        };
        painter.line_segment(
            [
                from_up(center, relative, inner),
                from_up(center, relative, radius * 0.93),
            ],
            pen(if degrees % 30 == 0 { 1.8 } else { 1.1 }, MARK),
        );
        if degrees % 30 == 0 {
            let label = match degrees {
                0 => "N".to_string(),
                90 => "E".to_string(),
                180 => "S".to_string(),
                270 => "W".to_string(),
                _ => format!("{}", degrees / 10),
            };
            let color = if matches!(degrees, 0 | 90 | 180 | 270) {
                Color32::WHITE
            } else {
                MARK
            };
            painter.text(
                from_up(center, relative, radius * 0.58),
                Align2::CENTER_CENTER,
                label,
                FontId::monospace(13.0),
                color,
            );
        }
    }
    let bug = (runway_heading_deg - heading_deg).rem_euclid(360.0) as f32;
    painter.circle_filled(from_up(center, bug, radius * 0.78), 4.5, BUG);
    painter.line_segment(
        [
            center + vec2(0.0, -radius + 6.0),
            center + vec2(0.0, -radius + 20.0),
        ],
        pen(3.0, AMBER),
    );
}

fn draw_vertical_speed(
    painter: &Painter,
    center: Pos2,
    radius: f32,
    vertical_fpm: f64,
    limit_fpm: f64,
) {
    painter.circle_filled(center, radius, FACE);
    let limit = limit_fpm.max(500.0);
    for mark in [-1.0, -0.5, 0.0, 0.5, 1.0] {
        let angle = vsi_angle(mark, 1.0);
        let inner = if mark == 0.0 {
            radius * 0.62
        } else {
            radius * 0.74
        };
        painter.line_segment(
            [
                from_up(center, angle, inner),
                from_up(center, angle, radius * 0.9),
            ],
            pen(1.6, MARK),
        );
        let label = if mark == 0.0 {
            "0".to_string()
        } else {
            format!("{:.0}", mark * limit / 1000.0)
        };
        painter.text(
            from_up(center, angle, radius * 0.48),
            Align2::CENTER_CENTER,
            label,
            FontId::monospace(12.0),
            DIM,
        );
    }
    let needle = vsi_angle((vertical_fpm / limit).clamp(-1.0, 1.0), 1.0);
    painter.line_segment(
        [center, from_up(center, needle, radius * 0.7)],
        pen(2.6, AMBER),
    );
    painter.circle_filled(center, 4.0, AMBER);
}

fn draw_turn(painter: &Painter, center: Pos2, radius: f32, turn_rate_deg_s: f64) {
    painter.circle_filled(center, radius, FACE);
    let bank = ((turn_rate_deg_s / 3.0) * 20.0).clamp(-45.0, 45.0) as f32;
    let radians = bank.to_radians();
    let span = radius * 0.42;
    let (sin_b, cos_b) = radians.sin_cos();
    let left = center + vec2(-span * cos_b, -span * sin_b);
    let right = center + vec2(span * cos_b, span * sin_b);
    let nose = center + vec2(18.0 * sin_b, -18.0 * cos_b);
    painter.line_segment([left, right], pen(3.0, MARK));
    painter.line_segment([center, nose], pen(3.0, MARK));
    painter.circle_filled(center, 3.0, AMBER);
    for side in [-1.0_f32, 1.0] {
        let x = side * span;
        painter.line_segment(
            [center + vec2(x, 6.0), center + vec2(x, 18.0)],
            pen(2.0, MARK),
        );
    }
    let track =
        Rect::from_center_size(center + vec2(0.0, radius * 0.48), vec2(radius * 0.72, 16.0));
    painter.rect_filled(track, 8.0, Color32::from_rgb(20, 24, 28));
    painter.rect_stroke(track, 8.0, pen(1.0, DIM), egui::StrokeKind::Inside);
    painter.circle_filled(track.center(), 6.0, Color32::from_rgb(230, 230, 230));
}

fn paint_span(painter: &Painter, center: Pos2, dy: f32, from: f32, to: f32, color: Color32) {
    if to - from < 0.4 {
        return;
    }
    painter.rect_filled(
        Rect::from_min_max(
            pos2(center.x + from, center.y + dy),
            pos2(center.x + to, center.y + dy + 1.0),
        ),
        0.0,
        color,
    );
}

fn horizon_segment(
    center: Pos2,
    radius: f32,
    pitch_px: f32,
    bank_deg: f32,
) -> Option<(Pos2, Pos2)> {
    let bank = bank_deg.to_radians();
    let a = -bank.sin();
    let b = -bank.cos();
    let norm = (a * a + b * b).sqrt();
    if norm < 1.0e-4 {
        return None;
    }
    let distance = pitch_px / norm;
    if distance.abs() >= radius {
        return None;
    }
    let an = a / norm;
    let bn = b / norm;
    let half = (radius * radius - distance * distance).sqrt();
    let origin_x = -an * distance;
    let origin_y = -bn * distance;
    let start = pos2(
        center.x + origin_x - bn * half,
        center.y + origin_y + an * half,
    );
    let end = pos2(
        center.x + origin_x + bn * half,
        center.y + origin_y - an * half,
    );
    Some((start, end))
}

fn draw_arc(
    painter: &Painter,
    center: Pos2,
    radius: f32,
    start_deg: f32,
    end_deg: f32,
    stroke: Stroke,
) {
    let steps = ((end_deg - start_deg).abs() / 4.0).ceil().max(1.0) as i32;
    let mut previous = from_up(center, start_deg, radius);
    for step in 1..=steps {
        let angle = start_deg + (end_deg - start_deg) * (step as f32 / steps as f32);
        let next = from_up(center, angle, radius);
        painter.line_segment([previous, next], stroke);
        previous = next;
    }
}

fn from_up(center: Pos2, clockwise_deg: f32, radius: f32) -> Pos2 {
    let radians = clockwise_deg.to_radians();
    center + vec2(radians.sin() * radius, -radians.cos() * radius)
}

fn sweep(value: f64, full_scale: f64) -> f32 {
    let fraction = (value / full_scale).clamp(0.0, 1.0) as f32;
    200.0 + 240.0 * fraction
}

fn vsi_angle(fraction: f64, _full: f64) -> f32 {
    270.0 + (fraction.clamp(-1.0, 1.0) as f32) * 90.0
}
