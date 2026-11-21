#!/bin/sh
# Graffitty installer, served at https://graffitty.com/install.sh
#
#   curl -fsSL https://graffitty.com/install.sh | sh
#
# What it does:
#   - Installs the prebuilt release for the current user. No root, no compiling.
#   - Reads what to install from https://graffitty.com/releases: the latest
#     version, and each archive's checksum and exact address.
#   - Checks the download against that checksum before installing.
#   - Is always the current installer, also when an older Graffitty runs it
#     (gft self update), so it must upgrade from every earlier version.
#   - Run it again to reinstall the published archive, even for the same tag.
#     The new session server takes over running terminals and reopens windows
#     (gft internal update finish).
#
# Linux (x86_64, arm64; glibc 2.35 or later). One directory per version, like mise.
# Replacing an existing tree uses mv --exchange or Perl on older distributions.
# User data such as worlds/ is next to installs/, never inside it:
#   ~/.local/share/graffitty/installs/<version>/     unpacked bundle
#   ~/.local/share/graffitty/installs/current -> <version>
#   ~/.local/bin/{gft,gft-gui}                -> installs/current/...
#   ~/.local/share/applications/Graffitty.desktop   application-menu entry
#   ~/.local/share/icons/hicolor/<size>/apps/graffitty.png   application icons
#
# macOS (Apple Silicon). One copy, replaced in place:
#   /Applications/Graffitty.app
#   ~/.local/bin/{gft,gft-gui}                -> Graffitty.app/.../tools/
#
# Environment:
#   GRAFFITTY_VERSION     release tag, e.g. v0.1.0 (default: latest)
#   GRAFFITTY_RELEASES    where releases are listed: an https URL or a local
#                         directory (default: https://graffitty.com/releases)
#   GRAFFITTY_BIN_DIR     launcher links (default: ~/.local/bin)
#   GRAFFITTY_INSTALL_DIR Linux versions root (default: $XDG_DATA_HOME/graffitty/installs)
#   GRAFFITTY_APP_DIR     macOS folder holding Graffitty.app (default: /Applications)
#   GRAFFITTY_INSTALL_SKIP_IF_EXISTS  1 skips a matching installed archive SHA-256
#   GRAFFITTY_NO_DESKTOP  1 skips the Linux application-menu entry and folder actions
set -eu

# Layout under $RELEASES, the same for a URL and a local directory:
#   latest.txt     the latest release tag
#   <tag>.txt      one line per archive of that release:
#                    <sha256>  <name>  <address>
#                  <name> is what this script asks for, such as
#                  graffitty-macos-arm64.tar.gz. <address> is where that file
#                  is: an https URL, or a path relative to $RELEASES.
RELEASES="${GRAFFITTY_RELEASES:-https://graffitty.com/releases}"
RELEASES="${RELEASES%/}"

info() { printf 'graffitty: %s\n' "$*" >&2; }
warn() { printf 'graffitty: warning: %s\n' "$*" >&2; }
error() { printf 'graffitty: error: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || error "'$1' is required but was not found"; }

# All work happens in main, called on the last line. If `curl | sh` receives
# only part of the script, nothing runs.
main() {
  [ "$#" -eq 0 ] || error "this installer takes no arguments; see the GRAFFITTY_* variables in the script header"
  [ -n "${HOME:-}" ] || error "HOME is not set"
  need uname
  os="$(uname -s)"
  case "$os" in
  Darwin) install_macos ;;
  Linux) linux_arch && install_linux ;;
  *) error "unsupported OS: $os (Graffitty installs on Linux and macOS)" ;;
  esac
}

install_macos() {
  # Under Rosetta, uname reports x86_64 on Apple Silicon. Ask the hardware too.
  if [ "$(uname -m)" != arm64 ] && [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" != 1 ]; then
    error "Graffitty for macOS requires Apple Silicon"
  fi
  asset="graffitty-macos-arm64.tar.gz"
  bin_dir="${GRAFFITTY_BIN_DIR:-$HOME/.local/bin}"
  apps="${GRAFFITTY_APP_DIR:-/Applications}"
  app="$apps/Graffitty.app"
  gft="$app/Contents/Resources/graffitty/tools/gft"

  # Check everything that could fail first. Nothing on disk changes before that.
  for tool in tar gzip codesign xattr awk cut grep mktemp ln mv rm; do need "$tool"; done
  sha_tool
  if [ ! -d "$apps" ] || [ ! -w "$apps" ]; then
    error "cannot write to $apps; set GRAFFITTY_APP_DIR to a folder you own (for example \$HOME/Applications) and rerun"
  fi
  free_links
  resolve_version

  with_install_lock "$apps" replace_macos
}

replace_macos() {
  prepare_download
  lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  receipt=com.graffitty.archive-sha256
  if [ "${GRAFFITTY_INSTALL_SKIP_IF_EXISTS:-0}" = 1 ] && [ -x "$gft" ] &&
     [ "$(xattr -p "$receipt" "$app" 2>/dev/null)" = "$expected" ] &&
     codesign --verify --deep --strict "$app" 2>/dev/null; then
    info "Graffitty $version is already installed (archive SHA-256 matches)"
    return
  fi
  info "downloading Graffitty $version for macOS"
  fetch_archive
  staging="$(mktemp -d "$apps/.graffitty-install.XXXXXX")" || error "could not create a directory in $apps"
  staged="$staging/Graffitty.app"
  tar -xzf "$tmp/$asset" -C "$staging" 2>/dev/null || error "could not unpack $asset"
  if [ ! -x "$staged/Contents/MacOS/Graffitty" ] || [ ! -x "$staged/Contents/Resources/graffitty/tools/gft" ]; then
    error "$asset holds no complete Graffitty.app"
  fi
  xattr -dr com.apple.quarantine "$staged" 2>/dev/null || true
  codesign --verify --deep --strict "$staged" 2>/dev/null ||
    error "$asset is damaged: its code signature does not verify"
  # Keep the receipt on the directory inode, outside the sealed contents.
  xattr -w "$receipt" "$expected" "$staged"
  "$lsregister" -u "$staged" >/dev/null 2>&1 || true
  replace_tree "$staged" "$app"
  mkdir -p "$bin_dir" || error "could not create $bin_dir"
  ln -sf "$gft" "$bin_dir/gft"
  ln -sf "$app/Contents/Resources/graffitty/tools/gft-gui" "$bin_dir/gft-gui"
  "$lsregister" -f "$app" >/dev/null 2>&1 || true
  info "Graffitty $version is installed at $app"
  finish_update "$gft"
  path_hint
}

# Stops if gft or gft-gui in $bin_dir is a real file, not a link.
# A real file there is usually a development build.
free_links() {
  for name in gft gft-gui; do
    if [ -e "$bin_dir/$name" ] && [ ! -L "$bin_dir/$name" ]; then
      error "$bin_dir/$name already exists and is not a link (perhaps a development build);
  remove it, or set GRAFFITTY_BIN_DIR to another directory, then rerun"
    fi
  done
}

linux_arch() {
  # Sets $arch. Call it directly, not through $(...): `error` must exit the
  # installer itself.
  # Linux builds need glibc. Detect it for real; never assume it.
  if command -v getconf >/dev/null 2>&1 && getconf GNU_LIBC_VERSION >/dev/null 2>&1; then
    glibc_version="$(getconf GNU_LIBC_VERSION | awk '{print $2}')"
    if ! awk -v v="$glibc_version" 'BEGIN {split(v,a,"."); exit !(a[1]>2 || (a[1]==2 && a[2]>=35))}'; then
      error "Graffitty needs glibc 2.35 or newer (found $glibc_version)"
    fi
  elif command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | grep -qi musl; then
    error "Graffitty needs glibc 2.35 or newer; this system uses musl (such as Alpine Linux), which Graffitty does not support"
  else
    error "Graffitty needs glibc 2.35 or newer, and could not find glibc on this system"
  fi
  machine="$(uname -m)"
  case "$machine" in
  x86_64 | amd64) arch=x86_64 ;;
  aarch64 | arm64) arch=arm64 ;;
  *) error "no Linux build for $machine (available: x86_64, arm64)" ;;
  esac
}

install_linux() {
  asset="graffitty-linux-$arch.tar.gz"
  bin_dir="${GRAFFITTY_BIN_DIR:-$HOME/.local/bin}"
  data_dir="${XDG_DATA_HOME:-$HOME/.local/share}"
  installs="${GRAFFITTY_INSTALL_DIR:-$data_dir/graffitty/installs}"
  current="$installs/current"

  # Check everything that could fail first. Nothing on disk changes before that.
  for tool in tar gzip awk cut grep mktemp ln mv rm readlink; do need "$tool"; done
  sha_tool
  if [ -e "$current" ] && [ ! -L "$current" ]; then
    error "$current exists and is not managed by this installer; move it away first"
  fi
  free_links
  resolve_version
  target="$installs/${version#v}"

  mkdir -p "$installs" || error "could not create $installs"
  with_install_lock "$installs" replace_linux
}

replace_linux() {
  prepare_download
  previous=""
  [ ! -L "$current" ] || previous="$(readlink "$current")"
  if [ "${GRAFFITTY_INSTALL_SKIP_IF_EXISTS:-0}" = 1 ] && [ "$previous" = "${version#v}" ] &&
     [ "$(cat "$target/.archive-sha256" 2>/dev/null)" = "$expected" ] && bundle_ok "$target"; then
    info "Graffitty $version is already installed (archive SHA-256 matches)"
    return
  fi
  info "downloading Graffitty $version for linux-$arch"
  fetch_archive
  staging="$(mktemp -d "$installs/.staging.XXXXXX")" || error "could not create a directory in $installs"
  tar -xzf "$tmp/$asset" -C "$staging" 2>/dev/null || error "could not unpack $asset"
  bundle_ok "$staging/graffitty" || error "$asset is incomplete or failed its SHA256SUMS check"
  printf '%s\n' "$expected" > "$staging/graffitty/.archive-sha256"
  replace_tree "$staging/graffitty" "$target"

  if [ "$previous" != "${version#v}" ]; then
    ln -s "${version#v}" "$staging/current"
    # GNU mv -T and BSD mv -h both replace the link itself.
    mv -Tf "$staging/current" "$current" 2>/dev/null || mv -fh "$staging/current" "$current"
    for old in "$installs"/[0-9]*; do
      [ -d "$old" ] || continue
      case "${old##*/}" in "${version#v}" | "$previous") ;; *) rm -rf "$old" ;; esac
    done
  fi
  mkdir -p "$bin_dir" || error "could not create $bin_dir"
  ln -sf "$current/tools/gft" "$bin_dir/gft"
  ln -sf "$current/gft-gui" "$bin_dir/gft-gui"
  info "Graffitty $version is installed at $target"
  finish_update "$current/tools/gft"
  browser_libraries

  if [ "${GRAFFITTY_NO_DESKTOP:-0}" != 1 ]; then
    desktop_entry
    if command -v python3 >/dev/null 2>&1; then
      # Register the `current` path. Otherwise install.py resolves the link to this
      # version's directory, and a later upgrade deletes that directory.
      python3 "$current/install.py" --launcher "$current/gft-gui" --exported >/dev/null 2>&1 \
        || warn "file-manager folder actions were not registered; run: python3 $current/install.py --launcher $current/gft-gui --exported"
    else
      warn "python3 not found; skipped file-manager folder actions"
    fi
  fi
  path_hint
}

# Sets $version to a release tag such as v0.1.0.
# Without GRAFFITTY_VERSION it reads the latest tag once. Every download then
# uses that tag, even if a newer release appears meanwhile.
resolve_version() {
  case "$RELEASES" in
  https://* | /*) ;;
  *) error "GRAFFITTY_RELEASES must be an https URL or an absolute directory, not '$RELEASES'" ;;
  esac
  if [ -n "${GRAFFITTY_VERSION:-}" ] && [ "$GRAFFITTY_VERSION" != latest ]; then
    version="$GRAFFITTY_VERSION"
    case "$version" in v*) ;; *) version="v$version" ;; esac
  else
    need mktemp
    latest="$(mktemp)" || error "could not create a temporary file"
    if ! fetch "$RELEASES/latest.txt" "$latest"; then
      rm -f "$latest"
      error "could not read the latest Graffitty version from $RELEASES/latest.txt"
    fi
    IFS= read -r version < "$latest" || true
    rm -f "$latest"
    version="$(printf '%s' "$version" | tr -d '\r')"
  fi
  if ! printf '%s\n' "$version" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+([.+-][0-9A-Za-z.+-]+)?$'; then
    if [ -n "${GRAFFITTY_VERSION:-}" ] && [ "$GRAFFITTY_VERSION" != latest ]; then
      error "invalid GRAFFITTY_VERSION '$GRAFFITTY_VERSION' (expected e.g. v0.1.0)"
    fi
    error "no published Graffitty release found at $RELEASES"
  fi
}

# Serialize installs in the same destination. Close the lock descriptor for
# children so a reopened window or server cannot keep it after the install.
with_install_lock() (
  if command -v flock >/dev/null 2>&1; then
    flock -x 9
  else
    perl -e 'flock(STDIN, 2) or die "lock installation: $!\n"' <&9
  fi
  # A temporary redirection on a function can duplicate fd 9 onto another
  # inherited descriptor (macOS sh). Close it permanently in the child.
  (exec 9<&-; "$2")
  exec 9<&-
) 9<"$1"

# Both paths are on the same filesystem. Exchange nonempty directories in
# one rename so launchers always see a complete tree. Open files and mapped
# executables stay usable even after cleanup unlinks the displaced tree.
replace_tree() {
  if [ ! -e "$2" ] && [ ! -L "$2" ]; then
    mv "$1" "$2"
  elif mv --exchange --no-copy -T "$1" "$2" 2>/dev/null; then
    return 0
  else
    # Older coreutils and BSD mv do not expose the exchange flag. The two
    # supported Linux ABIs provide renameat2, and macOS provides renameatx_np.
    need perl
    perl -MConfig -e '
      my ($call, $cwd);
      if ($^O eq "darwin") { ($call, $cwd) = (488, -2) }
      elsif ($Config{archname} =~ /^x86_64/) { ($call, $cwd) = (316, -100) }
      elsif ($Config{archname} =~ /^(aarch64|arm64)/) { ($call, $cwd) = (276, -100) }
      else { die "unsupported rename ABI: $Config{archname}\n" }
      syscall($call, $cwd, $ARGV[0], $cwd, $ARGV[1], 2) == 0 or die "exchange directories: $!\n";
    ' "$1" "$2" || error "could not exchange $1 and $2"
  fi
}

# Resolve one verified archive identity before deciding whether to download it.
prepare_download() {
  tmp="$(mktemp -d)" || error "could not create a temporary directory"
  staging=""
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  fetch "$RELEASES/$version.txt" "$tmp/release.txt" \
    || error "Graffitty $version is not listed at $RELEASES"
  entry="$(awk -v f="$asset" '
    { sub(/\r$/, "") }
    NF == 3 && length($1) == 64 && $1 ~ /^[0-9a-f]+$/ && $2 == f { print $1 " " $3 }' "$tmp/release.txt")"
  [ -n "$entry" ] || error "Graffitty $version has no $asset; refusing to install it unverified"
  [ "$(printf '%s\n' "$entry" | grep -c .)" = 1 ] || error "Graffitty $version lists $asset more than once"
  expected="${entry%% *}"
  address="${entry#* }"
  case "$address" in
  https://* | /*) ;;
  *://*) error "Graffitty $version lists $asset at $address, which is not an https address" ;;
  *) address="$RELEASES/$address" ;;
  esac
}

fetch_archive() {
  fetch "$address" "$tmp/$asset" progress || error "could not download $asset for release $version from $address"
  actual="$($sha "$tmp/$asset" | cut -d' ' -f1)"
  [ "$actual" = "$expected" ] || error "checksum mismatch for $asset (expected $expected, got $actual)"
}

# True when $1 is a complete bundle and every file matches its SHA256SUMS.
bundle_ok() {
  for file in gft-gui tools/gft; do [ -x "$1/$file" ] || return 1; done
  for file in install.py SHA256SUMS PLATFORM; do [ -f "$1/$file" ] || return 1; done
  for size in 16 22 24 32 48 64 96 128 256 512; do
    [ -f "$1/icons/hicolor/${size}x${size}/apps/graffitty.png" ] || return 1
  done
  IFS= read -r installed_platform < "$1/PLATFORM" || return 1
  [ "$installed_platform" = "linux-$arch" ] || return 1
  (cd "$1" && sha_check SHA256SUMS)
}

# Adds Graffitty to the desktop's application menu. The file name must match
# the window class and Wayland app ID, which Godot derives from config/name.
desktop_entry() {
  apps="$data_dir/applications"
  case "$current" in
  *[\"\`\$\\%]* | *"
"*)
    warn "skipped the application-menu entry: $current contains characters a .desktop file cannot hold"
    return 0
    ;;
  esac
  mkdir -p "$apps" || { warn "could not create $apps; skipped the application-menu entry"; return 0; }
  theme="$data_dir/icons/hicolor"
  for icon in "$current"/icons/hicolor/*/apps/graffitty.png; do
    target_icon="$theme/${icon#"$current/icons/hicolor/"}"
    mkdir -p "${target_icon%/*}" && ln -sf "$icon" "$target_icon" \
      || { warn "could not install $target_icon; skipped the application-menu entry"; return 0; }
  done
  touch "$theme" || warn "could not update the timestamp on $theme"
  for cache_tool in gtk-update-icon-cache gtk4-update-icon-cache; do
    if command -v "$cache_tool" >/dev/null 2>&1; then
      # A per-user hicolor tree inherits the system's index.theme.
      "$cache_tool" --force --ignore-theme-index "$theme" >/dev/null 2>&1 || warn "could not refresh $theme"
      break
    fi
  done
  cat >"$apps/.Graffitty.desktop.new" <<EOF || { warn "could not write the application-menu entry"; return 0; }
[Desktop Entry]
Type=Application
Name=Graffitty
GenericName=Terminal
Comment=Terminals and Chromium in one connected workspace
Comment[fr]=Terminaux et Chromium dans un même espace de travail connecté
Comment[pt_BR]=Terminais e Chromium em um só espaço de trabalho conectado
Comment[es]=Terminales y Chromium en un mismo espacio de trabajo conectado
Comment[it]=Terminali e Chromium in un unico spazio di lavoro collegato
Comment[ko]=터미널과 Chromium을 하나로 연결하는 작업 공간
Comment[ja]=ターミナルと Chromium をつなぐひとつのワークスペース
Comment[de]=Terminals und Chromium in einem verbundenen Arbeitsbereich
Comment[nb]=Terminaler og Chromium i ett sammenkoblet arbeidsområde
Comment[sv]=Terminaler och Chromium i en sammankopplad arbetsyta
Comment[da]=Terminaler og Chromium i ét forbundet arbejdsområde
Exec="$current/gft-gui"
TryExec=$current/gft-gui
Icon=graffitty
Terminal=false
Categories=System;TerminalEmulator;
StartupWMClass=Graffitty
EOF
  mv "$apps/.Graffitty.desktop.new" "$apps/Graffitty.desktop" \
    || { warn "could not write the application-menu entry"; return 0; }
  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$apps" >/dev/null 2>&1 || true
  fi
}

# Browser panes use the system libraries every Chrome install needs. Name any
# that are missing; everything else in Graffitty works without them.
browser_libraries() {
  command -v ldd >/dev/null 2>&1 || return 0
  missing="$(ldd "$current/chromium-linux/libcef.so" 2>/dev/null \
    | sed -n 's/^[[:space:]]*\([^[:space:]]*\) => not found.*/\1/p' | sort -u | tr '\n' ' ')"
  [ -n "$missing" ] || return 0
  warn "browser panes need system libraries that are missing: $missing
  Install them as described in https://docs.graffitty.com/start-here/install/"
}

# If Graffitty was running, it still runs the old version. This restarts its
# session server as the new version and reopens the open windows.
# Terminals and their programs keep running the whole time.
finish_update() {
  [ -x "$1" ] || return 0
  if ! result="$("$1" --version 2>&1)"; then
    warn "Graffitty is installed, but gft cannot start: $result"
    return 0
  fi
  if result="$("$1" internal update finish 2>&1)"; then
    [ -z "$result" ] || info "$result"
  else
    warn "the running Graffitty was not restarted: $result
  Its terminals keep running on the previous version. To move them to this one:
    gft checkpoint save && gft server restart"
  fi
}

# Removes the download directory, and the unpacked bundle if it was not installed.
cleanup() {
  [ -z "${tmp:-}" ] || rm -rf "$tmp"
  [ -z "${staging:-}" ] || rm -rf "$staging"
}

# Copies $1, an https URL or an absolute path, to $2.
fetch() {
  case "$1" in
  https://*) download "$@" ;;
  /*) cp "$1" "$2" 2>/dev/null ;;
  *) error "cannot fetch '$1': not an https URL or an absolute path" ;;
  esac
}

download() {
  if command -v curl >/dev/null 2>&1; then
    if [ "${3:-}" = progress ] && [ -t 2 ]; then
      curl --proto '=https' --tlsv1.2 -fL --retry 3 -# -o "$2" "$1"
    else
      curl --proto '=https' --tlsv1.2 -fsSL --retry 3 -o "$2" "$1"
    fi
  elif command -v wget >/dev/null 2>&1; then
    # Basic flags only: busybox wget does not have --https-only and similar.
    wget -q -O "$2" "$1"
  else
    error "curl or wget is required"
  fi
}

sha_tool() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha="sha256sum"
  elif command -v shasum >/dev/null 2>&1; then
    sha="shasum -a 256"
  else
    error "sha256sum or shasum is required"
  fi
}

sha_check() { $sha -c "$1" >/dev/null 2>&1; }

path_hint() {
  case ":${PATH:-}:" in
  *":$bin_dir:"*) info "run gft-gui to start Graffitty, or open it from your applications" ;;
  *)
    info "$bin_dir is not on PATH. Add this to your shell profile, then run gft-gui:"
    info "  export PATH=\"$bin_dir:\$PATH\""
    ;;
  esac
}

main "$@"
