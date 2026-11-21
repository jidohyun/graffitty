//! Source-matched syntax themes, activity previews, and deterministic animation.
use super::{
    Entry, Provider, Scenario,
    palette::{Palette, faint},
};
use ratatui::{
    style::{Color, Modifier, Style},
    text::{Line, Span},
};
use similar::{ChangeTag, TextDiff};
use std::{cell::RefCell, collections::HashMap, path::Path, sync::OnceLock};
use syntect::{
    easy::HighlightLines,
    highlighting::{FontStyle, Highlighter, Theme},
    parsing::{Scope, SyntaxSet},
    util::LinesWithEndings,
};
use two_face::theme::EmbeddedThemeName;
use unicode_segmentation::UnicodeSegmentation;
use unicode_width::UnicodeWidthStr;

fn theme(provider: Provider, palette: Palette) -> &'static Theme {
    static THEMES: OnceLock<[Theme; 3]> = OnceLock::new();
    let themes = THEMES.get_or_init(|| {
        let themes = two_face::theme::extra();
        [
            EmbeddedThemeName::CatppuccinMocha,
            EmbeddedThemeName::CatppuccinLatte,
            EmbeddedThemeName::MonokaiExtended,
        ]
        .map(|t| themes.get(t).clone())
    });
    &themes[if provider == Provider::Claude {
        2
    } else {
        usize::from(palette.light())
    }]
}

type HighlightCache = HashMap<(bool, bool, String, String), Vec<Line<'static>>>;
thread_local! { static HIGHLIGHTS: RefCell<HighlightCache> = RefCell::new(HashMap::new()); }

pub(super) fn code(
    text: &str,
    language: &str,
    provider: Provider,
    palette: Palette,
) -> Vec<Line<'static>> {
    let plain = || text.lines().map(|s| Line::from(s.to_owned())).collect();
    if text.len() > 64 * 1024 || text.lines().any(|l| l.len() > 4096) {
        return plain();
    }
    let key = (
        provider == Provider::Claude,
        palette.light(),
        language.to_owned(),
        text.to_owned(),
    );
    if let Some(hit) = HIGHLIGHTS.with(|c| c.borrow().get(&key).cloned()) {
        return hit;
    }
    static SYNTAX: OnceLock<SyntaxSet> = OnceLock::new();
    let syntax = SYNTAX.get_or_init(two_face::syntax::extra_newlines);
    let Some(grammar) = syntax
        .find_syntax_by_token(language)
        .or_else(|| syntax.find_syntax_by_extension(language))
    else {
        return plain();
    };
    let mut highlighter = HighlightLines::new(grammar, theme(provider, palette));
    let mut lines = Vec::new();
    for line in LinesWithEndings::from(text) {
        let Ok(tokens) = highlighter.highlight_line(line, syntax) else {
            return plain();
        };
        let spans = tokens
            .into_iter()
            .map(|(s, t)| {
                let mut style =
                    Style::default().fg(Color::Rgb(s.foreground.r, s.foreground.g, s.foreground.b));
                if s.font_style.contains(FontStyle::BOLD) {
                    style = style.add_modifier(Modifier::BOLD);
                }
                Span::styled(t.trim_end_matches(['\r', '\n']).to_owned(), style)
            })
            .collect::<Vec<_>>();
        lines.push(Line::from(spans));
    }
    HIGHLIGHTS.with(|c| {
        let mut cache = c.borrow_mut();
        if cache.len() >= 64 {
            cache.clear();
        }
        cache.insert(key, lines.clone());
    });
    lines
}

pub(super) fn scope_color(scope: &str, provider: Provider, palette: Palette) -> Color {
    let scope = Scope::new(scope).expect("static syntax scope");
    let c = Highlighter::new(theme(provider, palette))
        .style_for_stack(&[scope])
        .foreground;
    Color::Rgb(c.r, c.g, c.b)
}

pub(super) fn clip(mut line: Line<'static>, width: u16) -> Line<'static> {
    if line.width() <= usize::from(width) {
        return line;
    }
    let mut remaining = usize::from(width).saturating_sub(1);
    let mut spans = Vec::new();
    'outer: for span in line.spans {
        let mut content = String::new();
        for grapheme in span.content.graphemes(true) {
            let n = grapheme.width();
            if n > remaining {
                spans.push(Span::styled(content, span.style));
                break 'outer;
            }
            content.push_str(grapheme);
            remaining -= n;
        }
        spans.push(Span::styled(content, span.style));
    }
    if width > 0 {
        spans.push(Span::raw("…"));
    }
    line.spans = spans;
    line
}

fn claude_activity_glyph(elapsed: u64, term: &str) -> &'static str {
    // Claude Code 2.1.296: Vdn's terminal-specific glyphs and Xn's 2 s easing.
    let frames = if term == "xterm-ghostty" {
        ["·", "✢", "✳", "✶", "✻", "✻"]
    } else {
        ["·", "✢", "✳", "✶", "✻", "✽"]
    };
    let phase = (1.0 - (std::f64::consts::TAU * elapsed as f64 / 2000.0).cos()) / 2.0;
    frames[(phase * 5.0).round() as usize]
}

pub(super) fn activity_dot(provider: Provider, elapsed: u64, palette: Palette) -> Span<'static> {
    if provider == Provider::Claude {
        return Span::styled(
            claude_activity_glyph(elapsed, &std::env::var("TERM").unwrap_or_default()),
            Style::default().fg(Color::Rgb(215, 119, 87)),
        );
    }
    let (Some(fg), Some(bg)) = (palette.foreground, palette.background) else {
        return Span::styled(
            if (elapsed / 600) % 2 == 0 {
                "•"
            } else {
                "◦"
            },
            faint(),
        );
    };
    // Codex's one-character activity shimmer: 2 s sweep, ten columns of padding.
    let position = ((elapsed % 2000) as f32 / 2000.0 * 21.0) as usize;
    let distance = (10.0 - position as f32).abs();
    let intensity = if distance <= 5.0 {
        0.5 * (1.0 + (std::f32::consts::PI * distance / 5.0).cos())
    } else {
        0.0
    };
    Span::styled(
        "•",
        Style::default()
            .fg(super::palette::blend(bg, fg, intensity * 0.9))
            .add_modifier(Modifier::BOLD),
    )
}

pub(super) fn thinking(
    text: &str,
    provider: Provider,
    elapsed: u64,
    palette: Palette,
    tool_active: bool,
) -> Line<'static> {
    let mut spans = vec![activity_dot(provider, elapsed, palette), Span::raw(" ")];
    let width = text.width() as f64;
    let half_width = (width * 0.1).max(3.0);
    let sweep = ((elapsed.saturating_sub(600) as f64 / 1000.0) % 4.0).min(1.0);
    let position = sweep * (width + 2.0 * half_width) - half_width;
    let glimmer = width + 10.0 - ((elapsed / 200) as f64 % (width + 20.0));
    let mut column = 0.0;
    for glyph in text.graphemes(true) {
        let w = glyph.width() as f64;
        let style = if provider == Provider::Claude {
            Style::default().fg(if tool_active {
                // Native tool-use status pulses the entire word over two seconds.
                let flash = (((elapsed as f64 / 1000.0 * std::f64::consts::PI).sin() + 1.0) * 4.0)
                    .round()
                    / 8.0;
                super::palette::blend((235, 159, 127), (215, 119, 87), flash as f32)
            } else if (column - glimmer).abs() <= 1.0 {
                Color::Rgb(235, 159, 127)
            } else {
                Color::Rgb(215, 119, 87)
            })
        } else if let (Some(fg), Some(bg)) = (palette.foreground, palette.background) {
            let distance = ((column + w / 2.0 - position).abs() / half_width).min(1.0);
            let intensity = 0.5 * (1.0 + (std::f64::consts::PI * distance).cos());
            Style::default().fg(super::palette::blend(
                fg,
                bg,
                (0.5 + 0.5 * intensity) as f32,
            ))
        } else {
            faint()
        };
        spans.push(Span::styled(glyph.to_owned(), style));
        column += w;
    }
    if provider == Provider::Claude {
        spans.push(Span::styled(
            "…",
            Style::default().fg(Color::Rgb(215, 119, 87)),
        ));
    }
    let seconds = elapsed / 1000;
    let time = if seconds < 60 {
        format!("{seconds}s")
    } else {
        format!("{}m {}s", seconds / 60, seconds % 60)
    };
    if provider == Provider::Codex {
        spans.extend([
            Span::styled(format!(" ({time} • "), faint()),
            Span::styled("esc", Style::default().add_modifier(Modifier::BOLD)),
            Span::styled(" to interrupt)", faint()),
        ]);
    } else if elapsed > 16_000 {
        // 2.1.296's non-verbose spinner reveals its timer after 16 seconds when
        // there is no reasoning/token metadata. Interrupt belongs in the footer.
        spans.push(Span::styled(format!(" ({time})"), faint()));
    }
    Line::from(spans)
}

fn diff_background(added: bool, provider: Provider, palette: Palette) -> Color {
    if provider == Provider::Claude {
        return if added {
            Color::Rgb(2, 40, 0)
        } else {
            Color::Rgb(61, 1, 0)
        };
    }
    let highlighter = Highlighter::new(theme(provider, palette));
    for name in if added {
        ["markup.inserted", "diff.inserted"]
    } else {
        ["markup.deleted", "diff.deleted"]
    } {
        if let Some(bg) = highlighter
            .style_mod_for_stack(&[Scope::new(name).unwrap()])
            .background
        {
            return Color::Rgb(bg.r, bg.g, bg.b);
        }
    }
    match (palette.light(), added) {
        (false, true) => Color::Rgb(33, 58, 43),
        (false, false) => Color::Rgb(74, 34, 29),
        (true, true) => Color::Rgb(218, 251, 225),
        (true, false) => Color::Rgb(255, 235, 233),
    }
}

pub(super) fn edit(
    entry: &Entry,
    provider: Provider,
    palette: Palette,
    width: u16,
    expanded: bool,
) -> Vec<Line<'static>> {
    let Entry::Edit {
        path,
        before,
        after,
        line,
        preview_lines,
        complete,
    } = entry
    else {
        return Vec::new();
    };
    if !complete {
        return vec![Line::from(format!(
            "{} {}",
            if provider == Provider::Codex {
                "• Editing"
            } else {
                "● Update"
            },
            path
        ))];
    }
    let diff = TextDiff::from_lines(before, after);
    let (mut added, mut removed) = (0, 0);
    for change in diff.iter_all_changes() {
        match change.tag() {
            ChangeTag::Insert => added += 1,
            ChangeTag::Delete => removed += 1,
            _ => (),
        }
    }
    let green = if provider == Provider::Claude {
        Color::Rgb(78, 186, 101)
    } else {
        Color::Green
    };
    let red = if provider == Provider::Claude {
        Color::Rgb(255, 107, 128)
    } else {
        Color::Red
    };
    let mut lines = if provider == Provider::Codex {
        vec![Line::from(vec![
            Span::styled("• ", faint()),
            Span::styled("Edited", Style::default().add_modifier(Modifier::BOLD)),
            Span::raw(format!(" {path} (")),
            Span::styled(format!("+{added}"), Style::default().fg(green)),
            Span::raw(" "),
            Span::styled(format!("-{removed}"), Style::default().fg(red)),
            Span::raw(")"),
        ])]
    } else {
        vec![
            Line::from(vec![
                Span::styled("● ", Style::default().fg(green)),
                Span::styled("Update", Style::default().add_modifier(Modifier::BOLD)),
                Span::raw(format!("({path})")),
            ]),
            Line::from(format!(
                "  ⎿  Added {added} {}, removed {removed} {}",
                if added == 1 { "line" } else { "lines" },
                if removed == 1 { "line" } else { "lines" }
            )),
        ]
    };
    let language = Path::new(path)
        .extension()
        .and_then(|s| s.to_str())
        .unwrap_or("");
    let before_lines = code(before, language, provider, palette);
    let after_lines = code(after, language, provider, palette);
    let digits = (line.saturating_add(before.lines().count().max(after.lines().count())))
        .to_string()
        .len();
    let mut rows = Vec::new();
    for (i, group) in diff.grouped_ops(3).into_iter().enumerate() {
        if i > 0 {
            rows.push(Line::from("    ⋮"));
        }
        for op in group {
            for change in diff.iter_changes(&op) {
                let (index, source, sign, color, bg) = match change.tag() {
                    ChangeTag::Delete => (
                        change.old_index().unwrap(),
                        &before_lines,
                        "-",
                        red,
                        diff_background(false, provider, palette),
                    ),
                    ChangeTag::Insert => (
                        change.new_index().unwrap(),
                        &after_lines,
                        "+",
                        green,
                        diff_background(true, provider, palette),
                    ),
                    ChangeTag::Equal => (
                        change.new_index().unwrap(),
                        &after_lines,
                        " ",
                        Color::Reset,
                        Color::Reset,
                    ),
                };
                let mut spans = vec![
                    Span::styled(
                        format!("    {:>digits$} ", line.saturating_add(index)),
                        faint(),
                    ),
                    Span::styled(format!("{sign} "), Style::default().fg(color)),
                ];
                if let Some(content) = source.get(index) {
                    spans.extend(content.spans.clone());
                }
                rows.push(Line::from(spans).style(Style::default().bg(bg)));
            }
        }
    }
    let hidden = rows.len() > *preview_lines || rows.iter().any(|l| l.width() > usize::from(width));
    let limit = if expanded { rows.len() } else { *preview_lines };
    lines.extend(
        rows.into_iter()
            .take(limit)
            .map(|l| if expanded { l } else { clip(l, width) }),
    );
    if hidden {
        lines.push(Line::from(if expanded {
            "    − Show less"
        } else if provider == Provider::Claude {
            "    … (ctrl+t to expand)"
        } else {
            "    + Show details"
        }));
    }
    lines
}

pub(super) fn tool(
    entry: &Entry,
    provider: Provider,
    palette: Palette,
    width: u16,
    expanded: bool,
    elapsed: u64,
) -> Vec<Line<'static>> {
    let Entry::Tool {
        name,
        input,
        output,
        complete,
        exit_code,
        preview_lines,
    } = entry
    else {
        return Vec::new();
    };
    let shell = name.eq_ignore_ascii_case("bash")
        || name.eq_ignore_ascii_case("shell")
        || name.eq_ignore_ascii_case("exec_command");
    // Claude's tool rows use ko/Nf (a dim dot blinking every 600 ms),
    // not the changing star shown beside its working word.
    let marker = if !complete && provider == Provider::Claude {
        Span::styled(
            if (elapsed / 600) % 2 == 0 {
                if cfg!(target_os = "macos") { "⏺" } else { "●" }
            } else {
                " "
            },
            faint(),
        )
    } else if !complete {
        activity_dot(provider, elapsed, palette)
    } else {
        Span::styled(
            if provider == Provider::Codex {
                "•"
            } else {
                "●"
            },
            Style::default()
                .fg(match (provider, *exit_code == 0) {
                    (Provider::Codex, true) => Color::Green,
                    (Provider::Codex, false) => Color::Red,
                    (Provider::Claude, true) => Color::Rgb(78, 186, 101),
                    (Provider::Claude, false) => Color::Rgb(255, 107, 128),
                })
                .add_modifier(Modifier::BOLD),
        )
    };
    let verb = if provider == Provider::Claude {
        name.to_owned()
    } else if *complete && *exit_code != 0 {
        format!("Failed (exit {exit_code})")
    } else if shell {
        if *complete { "Ran" } else { "Running" }.into()
    } else {
        name.to_owned()
    };
    let mut header = vec![
        marker,
        Span::raw(" "),
        Span::styled(verb, Style::default().add_modifier(Modifier::BOLD)),
        Span::raw(if provider == Provider::Claude {
            "("
        } else {
            " "
        }),
    ];
    let commands = if shell {
        code(input, "bash", provider, palette)
    } else {
        input.lines().map(|l| Line::from(l.to_owned())).collect()
    };
    if let Some(first) = commands.first() {
        header.extend(first.spans.clone());
    }
    if commands.len() > 1 {
        header.push(Span::raw(" …"));
    }
    if provider == Provider::Claude {
        header.push(Span::raw(")"));
    }
    let header = Line::from(header);
    let clipped_header = header.width() > usize::from(width) || commands.len() > 1;
    let mut lines = vec![if expanded {
        header
    } else {
        clip(header, width)
    }];
    if !complete && output.is_empty() {
        return lines;
    }
    if expanded {
        for command in commands.iter().skip(1) {
            let mut line = command.clone();
            line.spans.insert(0, Span::raw("    "));
            lines.push(line);
        }
    }
    let output: Vec<_> = output.lines().collect();
    let start = if expanded {
        0
    } else {
        output.len().saturating_sub(*preview_lines)
    };
    let clipped_rows = output
        .iter()
        .skip(start)
        .filter(|l| l.width() + 4 > usize::from(width))
        .count();
    for (i, row) in output.iter().skip(start).enumerate() {
        let prefix = if i > 0 {
            "    "
        } else if provider == Provider::Claude {
            "  ⎿ "
        } else {
            "  └ "
        };
        let line = Line::from(format!("{prefix}{row}")).style(if provider == Provider::Codex {
            faint()
        } else {
            Style::default()
        });
        lines.push(if expanded { line } else { clip(line, width) });
    }
    if output.is_empty() {
        lines.push(Line::from("  └ (no output)").style(faint()));
    }
    let hidden = start + clipped_rows;
    if expanded {
        lines.push(Line::from("    − Show less"));
    } else if hidden > 0 {
        lines.push(clip(
            Line::from(format!(
                "    + {hidden} {} (^t to expand)",
                if hidden == 1 { "line" } else { "lines" }
            )),
            width,
        ));
    } else if clipped_header {
        lines.push(Line::from("    + Show details"));
    }
    lines
}

pub(super) fn status(settings: &Scenario, palette: Palette, width: u16) -> Line<'static> {
    let items = [
        (settings.model.clone(), "entity.name.type"),
        (settings.directory.clone(), "string"),
    ];
    let mut spans = vec![Span::raw("  ")];
    for (text, scope) in items.into_iter().filter(|(t, _)| !t.is_empty()) {
        if spans.len() > 1 {
            spans.push(Span::styled(" · ", palette.codex_secondary()));
        }
        let color = scope_color(scope, Provider::Codex, palette);
        let color = if let Color::Rgb(r, g, b) = color {
            let luma = (77 * u16::from(r) + 150 * u16::from(g) + 29 * u16::from(b)) / 256;
            let soften = |v| ((u16::from(v) * 85 + luma * 15 + 50) / 100) as u8;
            Color::Rgb(soften(r), soften(g), soften(b))
        } else {
            color
        };
        spans.push(Span::styled(
            super::scenario::clean(&text),
            Style::default().fg(color),
        ));
    }
    clip(Line::from(spans), width)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn palette() -> Palette {
        Palette {
            foreground: Some((248, 248, 242)),
            background: Some((40, 42, 54)),
        }
    }
    fn text(lines: &[Line<'_>]) -> String {
        lines
            .iter()
            .map(ToString::to_string)
            .collect::<Vec<_>>()
            .join("\n")
    }

    #[test]
    fn syntax_colored_edit_preview_retains_numbering_counts_and_expansion() {
        let entry = Entry::Edit { path: "tests/review.py".into(), before: "self.assertIn(\"Codex\", screen)\nself.assertIn(\"Claude\", screen)\n".into(),
            after: "wait(lambda: \"Codex\" in screen)\nwait(lambda: \"Claude\" in screen)\nassert done\n".into(), line: 105, preview_lines: 3, complete: true };
        for provider in [Provider::Codex, Provider::Claude] {
            let collapsed = edit(&entry, provider, palette(), 100, false);
            let expanded = edit(&entry, provider, palette(), 100, true);
            let rendered = text(&collapsed);
            assert!(rendered.contains("105 - self.assertIn"), "{rendered}");
            assert!(rendered.contains("105 + wait(lambda:"), "{rendered}");
            assert!(!rendered.contains("assert done"));
            assert!(text(&expanded).contains("107 + assert done"));
            assert!(text(&expanded).contains("Show less"));
            assert!(if provider == Provider::Codex {
                rendered.contains("Edited tests/review.py (+3 -2)")
                    && rendered.contains("+ Show details")
            } else {
                rendered.contains("Update(tests/review.py)")
                    && rendered.contains("Added 3 lines, removed 2 lines")
            });
            let changed = collapsed
                .iter()
                .find(|l| l.to_string().contains("105 +"))
                .unwrap();
            assert!(matches!(changed.style.bg, Some(Color::Rgb(..))));
            let colors: std::collections::HashSet<_> =
                changed.spans.iter().filter_map(|s| s.style.fg).collect();
            assert!(
                colors.len() >= 4,
                "syntax highlighting must survive the diff background"
            );
        }
    }

    #[test]
    fn shell_preview_colors_completion_and_retains_hidden_output() {
        let entry = Entry::Tool {
            name: "Bash".into(),
            input: "uv run --no-project tools/mise_tasks.py cli:build".into(),
            output: "first\nsecond\nthird\nfourth\nfifth".into(),
            exit_code: 0,
            preview_lines: 3,
            complete: true,
        };
        for provider in [Provider::Codex, Provider::Claude] {
            let collapsed = tool(&entry, provider, palette(), 100, false, 0);
            assert!(!text(&collapsed).contains("first"));
            assert!(text(&collapsed).contains("+ 2 lines (^t to expand)"));
            assert!(text(&tool(&entry, provider, palette(), 100, true, 0)).contains("first"));
            let colors: std::collections::HashSet<_> = collapsed[0]
                .spans
                .iter()
                .filter_map(|s| s.style.fg)
                .collect();
            assert!(
                colors.len() >= if provider == Provider::Codex { 4 } else { 3 },
                "shell arguments need separate syntax colors: {:?}",
                collapsed[0]
            );
        }
    }

    #[test]
    fn claude_tool_marker_blinks_without_copying_working_star() {
        let entry = Entry::Tool {
            name: "Bash".into(),
            input: "sleep 5".into(),
            output: String::new(),
            exit_code: 0,
            preview_lines: 3,
            complete: false,
        };
        let dot = if cfg!(target_os = "macos") { "⏺" } else { "●" };
        for (elapsed, expected) in [(0, dot), (599, dot), (600, " "), (1000, " "), (1200, dot)] {
            let lines = tool(&entry, Provider::Claude, palette(), 100, false, elapsed);
            assert_eq!(lines[0].spans[0].content, expected);
            assert_eq!(lines[0].spans[0].style, faint());
        }
        assert_eq!(claude_activity_glyph(1000, "xterm-ghostty"), "✻");
    }

    #[test]
    fn claude_native_spinner_cycle_and_tool_word_pulse() {
        for (time, glyph) in [(0, "·"), (500, "✳"), (1000, "✽"), (1500, "✶"), (2000, "·")] {
            assert_eq!(
                claude_activity_glyph(time, "xterm-256color"),
                glyph
            );
        }
        assert_eq!(claude_activity_glyph(1000, "xterm-ghostty"), "✻");
        for time in (0..4000).step_by(25) {
            assert_ne!(claude_activity_glyph(time, "xterm-ghostty"), "✽");
        }
        let bright = thinking("Working", Provider::Claude, 500, palette(), true);
        let dark = thinking("Working", Provider::Claude, 1500, palette(), true);
        assert_ne!(bright.spans[2].style, dark.spans[2].style);
        assert!(
            bright.spans[2..9]
                .windows(2)
                .all(|pair| pair[0].style == pair[1].style)
        );
    }

    #[test]
    fn animation_changes_styles_without_changing_text_or_timing() {
        for (provider, time) in [(Provider::Codex, 900), (Provider::Claude, 2600)] {
            let a = thinking("Working", provider, 0, palette(), false);
            let b = thinking("Working", provider, time, palette(), false);
            assert_ne!(a.spans[2..9], b.spans[2..9]);
            assert_eq!(b, thinking("Working", provider, time, palette(), false));
            assert_ne!(
                activity_dot(provider, 0, palette()),
                activity_dot(provider, time, palette())
            );
            assert_eq!(
                b.spans
                    .iter()
                    .any(|s| s.content == "esc" && s.style.add_modifier.contains(Modifier::BOLD)),
                provider == Provider::Codex
            );
        }
    }
}
