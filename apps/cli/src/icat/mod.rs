//! Kitty-compatible image cat. This is a client of the public graphics protocol;
//! it writes to stdout and needs neither a workspace socket nor a running GUI.
mod decode;
mod protocol;
mod terminal;
#[cfg(test)]
mod tests;

use std::io::{self, IsTerminal, Read, Write};
use std::path::{Path, PathBuf};
use std::time::Duration;
use usage_rs::Args;

type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

/// Kitty accepts --flag and --flag=no. Keep this in the Usage specification so
/// parsing, help and shell completions all describe the same interface.
#[derive(Clone, Copy, Debug)]
pub struct Switch(bool);

impl std::str::FromStr for Switch {
    type Err = &'static str;
    fn from_str(value: &str) -> std::result::Result<Self, Self::Err> {
        match value {
            "yes" | "true" | "y" | "1" => Ok(Self(true)),
            "no" | "false" | "n" | "0" => Ok(Self(false)),
            _ => Err("expected yes or no"),
        }
    }
}

#[derive(Args)]
pub struct Options {
    /// Image files, URLs, or directories (scanned recursively). Use - for stdin.
    pub images: Vec<String>,
    /// Horizontal alignment within the screen or placement rectangle.
    #[usage(long, default = "center", choices("center", "left", "right"))]
    align: String,
    /// Fit into WIDTHxHEIGHT@LEFTxTOP, measured in terminal cells from (0,0).
    #[usage(long)]
    place: Option<String>,
    /// Enlarge smaller images to fill the available area.
    #[usage(
        long,
        default = "no",
        default_missing = "yes",
        value_optional,
        require_equals
    )]
    scale_up: Switch,
    /// Fit to the screen width, height, both, or neither (ignored with --place).
    #[usage(long, default = "width", choices("both", "height", "none", "width"))]
    fit: String,
    /// Composite transparent pixels onto this color, or none to retain alpha.
    #[usage(long, default = "none")]
    background: String,
    /// Mirror the image horizontally, vertically, or both.
    #[usage(
        long,
        default = "none",
        choices("both", "horizontal", "none", "vertical")
    )]
    mirror: String,
    /// Remove images currently visible on screen.
    #[usage(
        long,
        default = "no",
        default_missing = "yes",
        value_optional,
        require_equals
    )]
    clear: Switch,
    /// Remove all images, including scrollback.
    #[usage(
        long,
        default = "no",
        default_missing = "yes",
        value_optional,
        require_equals
    )]
    clear_all: Switch,
    /// Transfer using temporary files, shared memory, or escape-code streaming.
    #[usage(
        long,
        default = "detect",
        choices("detect", "file", "memory", "stream")
    )]
    transfer_mode: String,
    /// Probe graphics support; print the best transfer mode to stderr and exit.
    #[usage(
        long,
        default = "no",
        default_missing = "yes",
        value_optional,
        require_equals
    )]
    detect_support: Switch,
    /// Seconds to wait for terminal query responses.
    #[usage(long, default = "10")]
    detection_timeout: f64,
    /// Supply columns,rows,width_pixels,height_pixels without querying the TTY.
    #[usage(long)]
    use_window_size: Option<String>,
    /// Print WIDTHxHEIGHT in pixels and exit.
    #[usage(
        long,
        default = "no",
        default_missing = "yes",
        value_optional,
        require_equals
    )]
    print_window_size: Switch,
    /// Read stdin automatically when piped, always, or never.
    #[usage(long, default = "detect", choices("detect", "yes", "no"))]
    stdin: String,
    /// Accepted for compatibility; has no effect.
    #[usage(
        long,
        default = "no",
        default_missing = "yes",
        value_optional,
        require_equals
    )]
    silent: Switch,
    /// Decode with Rust's image library or ImageMagick; auto falls back to magick.
    #[usage(long, default = "auto", choices("auto", "builtin", "magick"))]
    engine: String,
    /// Stacking order. Negative draws below text; --1 means -1073741825.
    #[usage(short = 'z', long, default = "0", allow_hyphen_values)]
    z_index: String,
    /// Animation loops: negative loops forever, zero displays only the first frame.
    #[usage(short = 'l', long = "loop", default = "-1", allow_negative_numbers)]
    loops: i32,
    /// Wait for a key after displaying images.
    #[usage(
        long,
        default = "no",
        default_missing = "yes",
        value_optional,
        require_equals
    )]
    hold: Switch,
    /// Display with Unicode placeholders, for editors and multiplexers.
    #[usage(
        long,
        default = "no",
        default_missing = "yes",
        value_optional,
        require_equals
    )]
    unicode_placeholder: Switch,
    /// Wrap graphics in tmux passthrough escapes (also enables placeholders).
    #[usage(long, default = "detect", choices("detect", "none", "tmux"))]
    passthrough: String,
    /// Image ID; multiple inputs use consecutive IDs. Values wrap to 32 bits.
    #[usage(long, default = "0", allow_negative_numbers)]
    image_id: String,
    /// Leave the cursor after the image without appending a newline.
    #[usage(
        short = 'n',
        long,
        default = "no",
        default_missing = "yes",
        value_optional,
        require_equals
    )]
    no_trailing_newline: Switch,
}

#[derive(Clone, Copy, Debug)]
struct WindowSize {
    columns: u32,
    rows: u32,
    width: u32,
    height: u32,
}

impl WindowSize {
    fn parse(value: &str) -> Result<Self> {
        let values: Vec<u16> = value
            .split(',')
            .map(str::parse)
            .collect::<std::result::Result<_, _>>()?;
        let [columns, rows, width, height] = values.as_slice() else {
            return Err(
                "--use-window-size requires columns,rows,width_pixels,height_pixels".into(),
            );
        };
        Self {
            columns: u32::from(*columns),
            rows: u32::from(*rows),
            width: u32::from(*width),
            height: u32::from(*height),
        }
        .validate()
    }

    fn validate(self) -> Result<Self> {
        if self.columns == 0
            || self.rows == 0
            || self.width < self.columns
            || self.height < self.rows
        {
            return Err("Terminal dimensions must be nonzero and pixel dimensions at least the cell dimensions; use --use-window-size to supply them".into());
        }
        Ok(self)
    }

    fn cell(self) -> (u32, u32) {
        (self.width / self.columns, self.height / self.rows)
    }
}

#[derive(Clone, Copy, Debug)]
struct Place {
    width: u32,
    height: u32,
    left: u32,
    top: u32,
}

impl Place {
    fn parse(value: &str) -> Result<Self> {
        let invalid = "--place requires WIDTHxHEIGHT@LEFTxTOP with positive dimensions and nonnegative coordinates";
        let (area, position) = value.split_once('@').ok_or(invalid)?;
        let (width, height) = area.split_once('x').ok_or(invalid)?;
        let (left, top) = position.split_once('x').ok_or(invalid)?;
        let p = Self {
            width: width.parse()?,
            height: height.parse()?,
            left: left.parse()?,
            top: top.parse()?,
        };
        if p.width == 0
            || p.height == 0
            || [p.width, p.height, p.left, p.top]
                .iter()
                .any(|&n| n > u16::MAX as u32)
        {
            return Err(invalid.into());
        }
        Ok(p)
    }
}

fn z_index(value: &str) -> Result<i32> {
    if let Some(negative) = value.strip_prefix('-').filter(|s| s.starts_with('-')) {
        return negative
            .parse::<i32>()?
            .checked_sub(1 << 30)
            .ok_or_else(|| "--z-index is outside the signed 32-bit range".into());
    }
    Ok(value.parse()?)
}

fn image_id(value: &str) -> Result<u32> {
    // Decimal accumulation permits arbitrary-sized IDs without overflowing.
    let digits = value.strip_prefix(['-', '+']).unwrap_or(value);
    if digits.is_empty() || !digits.bytes().all(|c| c.is_ascii_digit()) {
        return Err("--image-id requires an integer".into());
    }
    let id = digits.bytes().fold(0u32, |id, c| {
        id.wrapping_mul(10).wrapping_add(u32::from(c - b'0'))
    });
    Ok(if value.starts_with('-') {
        id.wrapping_neg()
    } else {
        id
    })
}

#[derive(Debug)]
enum Source {
    File(PathBuf),
    Url(String),
    Stdin,
}

fn directory_images(path: &Path, sources: &mut Vec<Source>) -> Result<()> {
    let mut entries = std::fs::read_dir(path)?.collect::<std::io::Result<Vec<_>>>()?;
    entries.sort_by_key(|entry| entry.file_name());
    for entry in entries {
        let path = entry.path();
        if entry.file_type()?.is_dir() {
            directory_images(&path, sources)?;
        } else if path.is_file()
            && (image::ImageFormat::from_path(&path).is_ok()
                || path.extension().is_some_and(|ext| {
                    matches!(
                        ext.to_string_lossy().to_ascii_lowercase().as_str(),
                        "svg" | "svgz" | "heic" | "heif" | "jxl" | "psd" | "eps" | "miff" | "xcf"
                    )
                }))
        {
            sources.push(Source::File(path));
        }
    }
    Ok(())
}

fn sources(opts: &Options) -> Result<Vec<Source>> {
    let explicit_stdin = opts
        .images
        .iter()
        .any(|arg| arg == "-" || arg == "/dev/stdin");
    if explicit_stdin && opts.stdin == "no" {
        return Err("stdin input conflicts with --stdin=no".into());
    }
    let mut result = Vec::new();
    if !explicit_stdin
        && (opts.stdin == "yes" || (opts.stdin == "detect" && !io::stdin().is_terminal()))
    {
        result.push(Source::Stdin);
    }
    let mut stdin_seen = false;
    for arg in &opts.images {
        if arg == "-" || arg == "/dev/stdin" {
            if stdin_seen {
                return Err("stdin can only be read once".into());
            }
            stdin_seen = true;
            result.push(Source::Stdin);
        } else if arg.starts_with("https://")
            || arg.starts_with("http://")
            || arg.starts_with("ftp://")
        {
            result.push(Source::Url(arg.clone()));
        } else {
            let path = if arg.starts_with("file://") {
                reqwest::Url::parse(arg)?
                    .to_file_path()
                    .map_err(|_| "Invalid file URL")?
            } else {
                PathBuf::from(arg)
            };
            if path.is_dir() {
                directory_images(&path, &mut result)?;
            } else {
                result.push(Source::File(path));
            }
        }
    }
    Ok(result)
}

const MAX_INPUT: u64 = 256 * 1024 * 1024;

fn read_input(reader: impl Read) -> Result<Vec<u8>> {
    let mut bytes = Vec::new();
    reader.take(MAX_INPUT + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > MAX_INPUT {
        return Err("Image input exceeds 256 MiB".into());
    }
    Ok(bytes)
}

impl Source {
    fn read(&self) -> Result<Vec<u8>> {
        match self {
            Self::File(path) => read_input(std::fs::File::open(path)?),
            Self::Stdin => read_input(io::stdin().lock()),
            Self::Url(url) if url.starts_with("ftp://") => {
                let file = tempfile::NamedTempFile::new()?;
                let output = std::process::Command::new("curl")
                    .args([
                        "--fail",
                        "--silent",
                        "--show-error",
                        "--location",
                        "--max-time",
                        "60",
                        "--max-filesize",
                        &MAX_INPUT.to_string(),
                        "--output",
                    ])
                    .arg(file.path())
                    .arg("--")
                    .arg(url)
                    .output()?;
                if !output.status.success() {
                    return Err(format!(
                        "FTP download: {}",
                        String::from_utf8_lossy(&output.stderr)
                    )
                    .into());
                }
                read_input(std::fs::File::open(file.path())?)
            }
            Self::Url(url) => read_input(
                reqwest::blocking::Client::builder()
                    .timeout(Duration::from_secs(60))
                    .build()?
                    .get(url)
                    .send()?
                    .error_for_status()?,
            ),
        }
    }
}

pub fn run(opts: Options) -> Result<()> {
    let timeout = Duration::try_from_secs_f64(opts.detection_timeout)
        .map_err(|_| "--detection-timeout must be a finite nonnegative number")?;
    let place = opts.place.as_deref().map(Place::parse).transpose()?;
    let z = z_index(&opts.z_index)?;
    let background = if opts.background == "none" {
        None
    } else {
        Some(decode::background(&opts.background)?)
    };
    let mut id = image_id(&opts.image_id)?;
    let tmux = opts.passthrough == "tmux"
        || (opts.passthrough == "detect"
            && std::env::var_os("TMUX").is_some_and(|s| !s.is_empty()));
    let placeholders = opts.unicode_placeholder.0 || tmux;
    let _ = opts.silent;
    let mut output = io::BufWriter::new(io::stdout().lock());

    if opts.clear_all.0 {
        protocol::command(&mut output, "a=d,d=R,x=0,y=4294967295,q=2", &[], tmux)?;
    } else if opts.clear.0 {
        protocol::command(&mut output, "a=d,d=A,q=2", &[], tmux)?;
    }
    output.flush()?;
    let mut inputs = if opts.print_window_size.0 || opts.detect_support.0 {
        Vec::new()
    } else {
        sources(&opts)?
    };
    let mut stdin_bytes = None;
    if inputs.iter().any(|source| matches!(source, Source::Stdin)) {
        let bytes = read_input(io::stdin().lock())?;
        if bytes.is_empty() && opts.stdin == "detect" {
            inputs.retain(|source| !matches!(source, Source::Stdin));
        } else {
            stdin_bytes = Some(bytes);
        }
    }
    if place.is_some() && inputs.len() > 1 {
        return Err("--place can only be used with a single image".into());
    }
    // Clearing alone must also work when there is no controlling terminal.
    if (opts.clear.0 || opts.clear_all.0)
        && inputs.is_empty()
        && !opts.print_window_size.0
        && !opts.detect_support.0
    {
        return Ok(());
    }
    let size = if let Some(size) = opts.use_window_size.as_deref() {
        WindowSize::parse(size)?
    } else {
        terminal::window_size(timeout)?
    };
    if opts.print_window_size.0 {
        write!(output, "{}x{}", size.width, size.height)?;
        return Ok(output.flush()?);
    }
    let mode = if opts.detect_support.0 || opts.transfer_mode == "detect" {
        if tmux {
            "stream"
        } else {
            terminal::detect(timeout)?
        }
    } else {
        &opts.transfer_mode
    };
    if opts.detect_support.0 {
        eprintln!("{mode}");
        return Ok(());
    }
    let mut failures = Vec::new();
    for source in inputs {
        let mut process = || -> Result<decode::Decoded> {
            let bytes = if matches!(source, Source::Stdin) {
                stdin_bytes.take().unwrap_or_default()
            } else {
                source.read()?
            };
            decode::decode(&bytes, &opts)
        };
        match process() {
            Ok(mut image) => {
                let result = image
                    .transform(&opts, size, place, background)
                    .and_then(|()| {
                        protocol::display(
                            &mut output,
                            &image,
                            &opts,
                            size,
                            place,
                            z,
                            id,
                            mode,
                            placeholders,
                            tmux,
                        )
                    });
                if let Err(error) = result {
                    failures.push(format!("{source:?}: {error}"));
                }
                if id != 0 {
                    id = id.wrapping_add(1).max(1);
                }
            }
            Err(error) => failures.push(format!("{source:?}: {error}")),
        }
    }
    output.flush()?;
    if !failures.is_empty() {
        return Err(failures.join("\n").into());
    }
    if opts.hold.0 {
        terminal::hold()?;
    }
    Ok(())
}
