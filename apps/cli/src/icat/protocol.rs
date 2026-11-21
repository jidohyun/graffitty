//! Wire encoding follows https://sw.kovidgoyal.net/kitty/graphics-protocol/.
use super::{Options, Place, Result, WindowSize, decode::Decoded};
use base64::{Engine as _, engine::general_purpose::STANDARD as B64};
use std::io::{Cursor, Write};

include!("diacritics.rs");

pub(super) fn command(output: &mut impl Write, keys: &str, bytes: &[u8], tmux: bool) -> Result<()> {
    // 3072 raw bytes become 4096 base64 bytes: the protocol's chunk limit.
    let mut chunks = bytes.chunks(3072).peekable();
    let mut first = true;
    loop {
        let chunk = chunks.next().unwrap_or_default();
        let more = u8::from(chunks.peek().is_some());
        let keys = if first {
            format!("{keys},m={more}")
        } else {
            format!("m={more}")
        };
        let packet = format!("\x1b_G{keys};{}\x1b\\", B64.encode(chunk));
        if tmux {
            write!(
                output,
                "\x1bPtmux;{}\x1b\\",
                packet.replace('\x1b', "\x1b\x1b")
            )?;
        } else {
            output.write_all(packet.as_bytes())?;
        }
        first = false;
        if more == 0 {
            break;
        }
    }
    Ok(())
}

/// Keep ownership until a query completes or a transmission is flushed. Only
/// successful transmissions hand file/SHM cleanup to the terminal (t=t / t=s).
pub(super) enum Payload {
    Stream(Vec<u8>),
    File(tempfile::NamedTempFile, Vec<u8>),
    #[cfg(unix)]
    Memory(SharedMemory, usize),
}

impl Payload {
    pub fn new(mode: &str, bytes: &[u8]) -> Result<Self> {
        match mode {
            "stream" => Ok(Self::Stream(bytes.to_vec())),
            "file" => {
                let mut file = tempfile::Builder::new().prefix("tty-graphics-protocol-graffitty-").tempfile()?;
                file.write_all(bytes)?;
                file.flush()?;
                // A plain C:\ path, not std's \\?\ form, so the terminal can match it to its temp directory.
                let path = dunce::canonicalize(file.path())?;
                #[cfg(unix)]
                let path = { use std::os::unix::ffi::OsStrExt; path.as_os_str().as_bytes().to_vec() };
                #[cfg(not(unix))]
                let path = path.to_string_lossy().as_bytes().to_vec();
                Ok(Self::File(file, path))
            }
            #[cfg(unix)]
            "memory" => Ok(Self::Memory(SharedMemory::new(bytes)?, bytes.len())),
            _ => Err(format!("Transfer mode {mode} is unavailable on this platform; use --transfer-mode=stream or file").into()),
        }
    }

    pub fn data(&self) -> &[u8] {
        match self {
            Self::Stream(data) | Self::File(_, data) => data,
            #[cfg(unix)]
            Self::Memory(shm, _) => shm.name.as_bytes(),
        }
    }

    pub fn keys(&self) -> String {
        match self {
            Self::Stream(_) => "t=d".into(),
            // Whole files need no size field. Omitting S also avoids older
            // Ghostty versions treating an exact-size read as a limit error.
            Self::File(_, _) => "t=t".into(),
            #[cfg(unix)]
            Self::Memory(_, size) => format!("t=s,S={size}"),
        }
    }

    fn handoff(self) -> Result<()> {
        match self {
            Self::File(file, _) => {
                file.keep()?;
            }
            #[cfg(unix)]
            Self::Memory(mut shm, _) => {
                shm.unlink = false;
            }
            Self::Stream(_) => (),
        }
        Ok(())
    }
}

#[cfg(unix)]
pub(super) struct SharedMemory {
    name: std::ffi::CString,
    unlink: bool,
}

#[cfg(unix)]
impl SharedMemory {
    fn new(bytes: &[u8]) -> Result<Self> {
        use std::os::fd::FromRawFd;
        let name = std::ffi::CString::new(format!(
            "/gicat-{}",
            &uuid::Uuid::new_v4().simple().to_string()[..20]
        ))?;
        // SAFETY: the name is NUL terminated; successful creation returns an
        // owned descriptor, transferred to File exactly once.
        let fd = unsafe {
            libc::shm_open(
                name.as_ptr(),
                libc::O_CREAT | libc::O_EXCL | libc::O_RDWR,
                0o600,
            )
        };
        if fd < 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        let shm = Self { name, unlink: true };
        let file = unsafe { std::fs::File::from_raw_fd(fd) };
        file.set_len(bytes.len() as u64)?;
        // POSIX SHM descriptors are not writable with write(2) on macOS.
        // SAFETY: the object is sized above, mmap grants a writable range of
        // exactly bytes.len(), and the source slice cannot overlap that range.
        let mapping = unsafe {
            libc::mmap(
                std::ptr::null_mut(),
                bytes.len(),
                libc::PROT_READ | libc::PROT_WRITE,
                libc::MAP_SHARED,
                fd,
                0,
            )
        };
        if mapping == libc::MAP_FAILED {
            return Err(std::io::Error::last_os_error().into());
        }
        unsafe {
            std::ptr::copy_nonoverlapping(bytes.as_ptr(), mapping.cast::<u8>(), bytes.len());
            libc::munmap(mapping, bytes.len());
        }
        Ok(shm)
    }
}

#[cfg(unix)]
impl Drop for SharedMemory {
    fn drop(&mut self) {
        if self.unlink {
            // SAFETY: the name remains valid and unlink does not use the FD.
            unsafe {
                libc::shm_unlink(self.name.as_ptr());
            }
        }
    }
}

fn transmit(
    output: &mut impl Write,
    keys: &str,
    bytes: &[u8],
    mode: &str,
    tmux: bool,
) -> Result<()> {
    if mode == "stream" {
        return command(output, &format!("{keys},t=d"), bytes, tmux);
    }
    let payload = Payload::new(mode, bytes)?;
    command(
        output,
        &format!("{keys},{}", payload.keys()),
        payload.data(),
        tmux,
    )?;
    output.flush()?;
    payload.handoff()
}

#[allow(clippy::too_many_arguments)]
pub(super) fn display(
    output: &mut impl Write,
    image: &Decoded,
    opts: &Options,
    size: WindowSize,
    place: Option<Place>,
    z: i32,
    id: u32,
    mode: &str,
    placeholders: bool,
    tmux: bool,
) -> Result<()> {
    let (width, height) = image.frames[0].pixels.dimensions();
    let (cell_width, cell_height) = size.cell();
    let columns = width.div_ceil(cell_width);
    let rows = height.div_ceil(cell_height);
    if placeholders && (columns as usize > DIACRITICS.len() || rows as usize > DIACRITICS.len()) {
        return Err(format!(
            "Unicode placeholders support images up to {}x{} cells",
            DIACRITICS.len(),
            DIACRITICS.len()
        )
        .into());
    }
    let area_width = place.map_or(size.columns, |p| p.width);
    let spare_columns = area_width.saturating_sub(columns);
    let spare_pixels = (cell_width - width % cell_width) % cell_width;
    let (offset, x_offset) = match opts.align.as_str() {
        "right" => (spare_columns, spare_pixels),
        "left" => (0, 0),
        _ => (spare_columns / 2, spare_pixels / 2),
    };
    let id = if id == 0 {
        u32::from_le_bytes(uuid::Uuid::new_v4().as_bytes()[..4].try_into().unwrap()).max(1)
    } else {
        id
    };
    output.write_all(b"\r")?;
    if let Some(p) = place {
        write!(output, "\x1b[{};{}H", p.top + 1, p.left + offset + 1)?;
    } else if !placeholders && offset > 0 {
        write!(output, "\x1b[{offset}C")?;
    }
    for (index, frame) in image.frames.iter().enumerate() {
        let mut bytes = Cursor::new(Vec::new());
        frame.pixels.write_to(&mut bytes, image::ImageFormat::Png)?;
        let mut keys = if index == 0 {
            format!("a=T,f=100,q=2,i={id},s={width},v={height},z={z},X={x_offset}")
        } else {
            format!(
                "a=f,f=100,q=2,i={id},s={width},v={height},z={},X=1",
                frame.delay
            )
        };
        if index == 0 {
            if place.is_some() {
                keys.push_str(",C=1");
            }
            if placeholders {
                keys.push_str(&format!(",U=1,c={columns},r={rows}"));
            }
        }
        transmit(output, &keys, bytes.get_ref(), mode, tmux)?;
        if index == 0 && image.frames.len() > 1 {
            let loops = if opts.loops < 0 {
                1
            } else {
                opts.loops as u32 + 1
            };
            command(
                output,
                &format!("a=a,q=2,i={id},r=1,z={},v={loops},s=2", frame.delay),
                &[],
                tmux,
            )?;
        }
    }
    if placeholders {
        write!(
            output,
            "\x1b[38;2;{};{};{}m",
            (id >> 16) & 255,
            (id >> 8) & 255,
            id & 255
        )?;
        if place.is_some() {
            output.write_all(b"\x1b7")?;
        }
        for row in 0..rows {
            if let Some(p) = place {
                write!(output, "\x1b[{};{}H", p.top + row + 1, p.left + offset + 1)?;
            } else {
                write!(output, "{}", " ".repeat(offset as usize))?;
            }
            for column in 0..columns {
                write!(
                    output,
                    "\u{10eeee}{}{}{}",
                    DIACRITICS[row as usize],
                    DIACRITICS[column as usize],
                    DIACRITICS[(id >> 24) as usize]
                )?;
            }
            // Preview hosts such as fzf consume lines and discard cursor
            // addressing. Keep explicit row separators even with --place.
            if row + 1 < rows {
                output.write_all(b"\r\n")?;
            }
        }
        output.write_all(b"\x1b[39m")?;
        if place.is_some() {
            output.write_all(b"\x1b8")?;
        }
    }
    if image.frames.len() > 1 {
        command(output, &format!("a=a,q=2,i={id},s=3"), &[], tmux)?;
    }
    if place.is_none() && !opts.no_trailing_newline.0 {
        output.write_all(b"\n")?;
    }
    Ok(())
}
