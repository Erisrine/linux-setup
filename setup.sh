#!/usr/bin/env bash
# =============================================================================
#  setup.sh: workstation setup for Linux Mint 22.x (Cinnamon) / Ubuntu 24.04
#
#  Installs and configures:
#    - Mullvad VPN              (official apt repo, daemon left stopped)
#    - Vivaldi                  (official .deb + repo, set as default browser)
#    - Unity Hub                (official apt repo)
#    - .NET 9 SDK               (Ubuntu dotnet/backports PPA, falls back to dotnet-install.sh)
#    - VS Code                  (official Microsoft repo + Unity extension)
#    - Alacritty                (set as default terminal)
#    - Lotion                   (unofficial Notion desktop app, latest GitHub .deb)
#    - Aseprite                 (built from source with prebuilt Skia, /opt/aseprite)
#    - Claude Code              (native installer, ~/.local/bin added to PATH)
#    - Hotkeys                  Super+T -> Alacritty, Super+B -> Vivaldi
#
#  Usage (run as your normal user, NOT with sudo; it asks for sudo itself):
#    bash setup.sh                       # run everything
#    bash setup.sh --only vscode,dotnet  # run just these steps
#    bash setup.sh --skip aseprite       # run everything except these
#    bash setup.sh --list                # show step names
#
#  From GitHub:
#    bash <(curl -fsSL https://raw.githubusercontent.com/<you>/<repo>/main/setup.sh)
#
#  Safe to re-run: every step checks what is already there.
# =============================================================================
set -Eeuo pipefail

ALL_STEPS=(base mullvad vivaldi unityhub dotnet vscode alacritty lotion aseprite claude hotkeys)

# ----------------------------------------------------------------------------- helpers
log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

apt_update()  { sudo DEBIAN_FRONTEND=noninteractive apt-get update -q; }
apt_install() { sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$@"; }
pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep 'install ok installed' >/dev/null; }

# Download an ASCII-armored key and store it dearmored at $2.
install_key() {
  local url=$1 dest=$2 tmp
  tmp=$(mktemp)
  curl -fsSL "$url" | gpg --batch --yes --dearmor -o "$tmp"
  sudo install -D -o root -g root -m 644 "$tmp" "$dest"
  rm -f "$tmp"
}

# Write a file as root only if its content differs.
write_root_file() {
  local dest=$1 content=$2
  if [[ ! -f $dest ]] || [[ "$(cat "$dest")" != "$content" ]]; then
    printf '%s\n' "$content" | sudo tee "$dest" >/dev/null
  fi
}

# Latest release asset URL from GitHub matching a regex.
gh_latest_asset() {
  local repo=$1 pattern=$2
  curl -fsSL "https://api.github.com/repos/$repo/releases/latest" \
    | grep -oE '"browser_download_url": *"[^"]+"' | cut -d'"' -f4 \
    | grep -E "$pattern" | head -n1 || true
}

# Add a PATH-style snippet to a shell rc file once (marked block).
ensure_rc_block() {
  local file=$1 marker=$2 body=$3
  [[ -f $file ]] || touch "$file"
  if ! grep -qF "# >>> $marker >>>" "$file"; then
    printf '\n# >>> %s >>>\n%s\n# <<< %s <<<\n' "$marker" "$body" "$marker" >>"$file"
    info "Updated $file"
  fi
}

shell_rc_files() {
  local f
  for f in "$HOME/.bashrc" "$HOME/.profile" "$HOME/.zshrc"; do
    # .zshrc only if zsh is actually in use
    [[ $f == *zshrc && ! -f $f ]] && continue
    echo "$f"
  done
}

# ----------------------------------------------------------------------------- steps

step_base() {
  log "Base packages"
  apt_update
  apt_install curl wget gpg ca-certificates git unzip python3 apt-transport-https
}

step_mullvad() {
  log "Mullvad VPN"
  sudo curl -fsSLo /usr/share/keyrings/mullvad-keyring.asc \
    https://repository.mullvad.net/deb/mullvad-keyring.asc
  write_root_file /etc/apt/sources.list.d/mullvad.list \
    "deb [signed-by=/usr/share/keyrings/mullvad-keyring.asc arch=$ARCH] https://repository.mullvad.net/deb/stable stable main"
  apt_update
  apt_install mullvad-vpn
  # The package's postinst starts the daemon on its own. A freshly started daemon
  # with no account can go into its "blocked" state and cut all traffic, which
  # breaks every later step that downloads something. Stop it and keep it off
  # until you're ready to log in.
  sudo systemctl disable --now mullvad-daemon.service mullvad-early-boot-blocking.service 2>/dev/null || true
  info "Mullvad installed but NOT running. When ready:"
  info "  sudo systemctl enable --now mullvad-daemon"
  info "  mullvad account login <ACCOUNT_NUMBER>   (or use the GUI)"
}

step_vivaldi() {
  log "Vivaldi"
  if ! pkg_installed vivaldi-stable; then
    # Install the official .deb; its postinst configures Vivaldi's own apt repo
    # and key, which avoids duplicate/conflicting repo definitions.
    local repo=https://repo.vivaldi.com/archive/deb file
    file=$(curl -fsSL "$repo/dists/stable/main/binary-$ARCH/Packages" | awk '
      /^Package: /  { pkg = $2 }
      /^Version: /  { ver = $2 }
      /^Filename: / { if (pkg == "vivaldi-stable") print ver, $2 }' \
      | sort -V | tail -n1 | cut -d' ' -f2)
    [[ -n $file ]] || die "Could not find vivaldi-stable in the Vivaldi repo"
    curl -fsSLo "$WORK/vivaldi.deb" "$repo/$file"
    apt_install "$WORK/vivaldi.deb"
  else
    info "Already installed"
  fi

  xdg-settings set default-web-browser vivaldi-stable.desktop \
    || warn "xdg-settings failed; set Vivaldi as default in System Settings > Preferred Applications"
  if update-alternatives --list x-www-browser 2>/dev/null | grep -x /usr/bin/vivaldi-stable >/dev/null; then
    sudo update-alternatives --set x-www-browser /usr/bin/vivaldi-stable
  fi
  if have gsettings && gsettings list-schemas | grep -x org.cinnamon.desktop.default-applications.browser 2>/dev/null >/dev/null; then
    gsettings set org.cinnamon.desktop.default-applications.browser exec 'vivaldi-stable' || true
  fi
}

step_unityhub() {
  log "Unity Hub"
  install_key https://hub.unity3d.com/linux/keys/public /usr/share/keyrings/Unity_Technologies_ApS.gpg
  write_root_file /etc/apt/sources.list.d/unityhub.list \
    "deb [signed-by=/usr/share/keyrings/Unity_Technologies_ApS.gpg] https://hub.unity3d.com/linux/repos/deb stable main"
  apt_update
  apt_install unityhub
}

step_dotnet() {
  log ".NET 9 SDK"
  if have dotnet && dotnet --list-sdks 2>/dev/null | grep '^9\.' >/dev/null; then
    info "Already installed: $(dotnet --list-sdks | grep '^9\.' | tail -n1)"
    return 0
  fi

  # Ubuntu's official .NET backports PPA (Ubuntu 24.04 base has only .NET 8).
  local codename fp
  codename=$(. /etc/os-release; echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
  fp=$(curl -fsSL https://api.launchpad.net/1.0/~dotnet/+archive/ubuntu/backports \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["signing_key_fingerprint"])' 2>/dev/null) \
     || fp=45A3F127159BE9E5017811C62125B164E8E5D3FA

  if install_key "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x$fp" /usr/share/keyrings/dotnet-backports.gpg \
     && write_root_file /etc/apt/sources.list.d/dotnet-backports.list \
          "deb [signed-by=/usr/share/keyrings/dotnet-backports.gpg] https://ppa.launchpadcontent.net/dotnet/backports/ubuntu $codename main" \
     && apt_update && apt_install dotnet-sdk-9.0; then
    info "Installed from dotnet/backports PPA: $(dotnet --version)"
  else
    warn "PPA install failed; falling back to Microsoft's dotnet-install.sh (~/.dotnet)"
    sudo rm -f /etc/apt/sources.list.d/dotnet-backports.list
    curl -fsSLo "$WORK/dotnet-install.sh" https://dot.net/v1/dotnet-install.sh
    bash "$WORK/dotnet-install.sh" --channel 9.0 --install-dir "$HOME/.dotnet"
    local f
    while read -r f; do
      ensure_rc_block "$f" "dotnet" 'export DOTNET_ROOT="$HOME/.dotnet"
case ":$PATH:" in *":$HOME/.dotnet:"*) ;; *) export PATH="$HOME/.dotnet:$HOME/.dotnet/tools:$PATH" ;; esac'
    done < <(shell_rc_files)
    "$HOME/.dotnet/dotnet" --version
  fi
}

step_vscode() {
  log "Visual Studio Code"
  install_key https://packages.microsoft.com/keys/microsoft.asc /usr/share/keyrings/microsoft.gpg
  # Same deb822 file the 'code' package manages itself, so no duplicate repo.
  write_root_file /etc/apt/sources.list.d/vscode.sources "Types: deb
URIs: https://packages.microsoft.com/repos/code
Suites: stable
Components: main
Architectures: amd64,arm64,armhf
Signed-By: /usr/share/keyrings/microsoft.gpg"
  sudo rm -f /etc/apt/sources.list.d/vscode.list  # old-style duplicate, if any
  echo "code code/add-microsoft-repo boolean true" | sudo debconf-set-selections
  apt_update
  apt_install code

  # Unity extension (pulls in C# Dev Kit + C# automatically).
  if code --list-extensions 2>/dev/null | grep -i '^visualstudiotoolsforunity.vstuc$' >/dev/null; then
    info "Unity extension already installed"
  else
    code --install-extension visualstudiotoolsforunity.vstuc --force \
      || warn "Could not install the Unity VS Code extension; install 'Unity' from the Extensions panel"
  fi
}

step_alacritty() {
  log "Alacritty (default terminal)"
  apt_install alacritty

  local bin
  bin=$(command -v alacritty)
  if ! update-alternatives --list x-terminal-emulator 2>/dev/null | grep -x "$bin" >/dev/null; then
    sudo update-alternatives --install /usr/bin/x-terminal-emulator x-terminal-emulator "$bin" 50
  fi
  sudo update-alternatives --set x-terminal-emulator "$bin"

  # Cinnamon (also used by Nemo's "Open in Terminal" and Ctrl+Alt+T)
  if gsettings list-schemas 2>/dev/null | grep -x org.cinnamon.desktop.default-applications.terminal >/dev/null; then
    gsettings set org.cinnamon.desktop.default-applications.terminal exec 'alacritty'
    gsettings set org.cinnamon.desktop.default-applications.terminal exec-arg '-e'
  fi
  # GNOME / GTK apps
  if gsettings list-schemas 2>/dev/null | grep -x org.gnome.desktop.default-applications.terminal >/dev/null; then
    gsettings set org.gnome.desktop.default-applications.terminal exec 'alacritty'
    gsettings set org.gnome.desktop.default-applications.terminal exec-arg '-e'
  fi
  # Xfce
  if have xfconf-query || [[ ${XDG_CURRENT_DESKTOP:-} == *XFCE* ]]; then
    mkdir -p "$HOME/.config/xfce4"
    local rc="$HOME/.config/xfce4/helpers.rc"
    touch "$rc"
    sed -i '/^TerminalEmulator=/d' "$rc"
    echo 'TerminalEmulator=alacritty' >>"$rc"
  fi
}

step_lotion() {
  log "Lotion (Notion desktop client)"
  local url ver
  url=$(gh_latest_asset puneetsl/lotion "_${ARCH}\.deb$")
  [[ -n $url ]] || die "No Lotion .deb found in the latest GitHub release"
  ver=$(basename "$url" | sed -E 's/^lotion_([^_]+)_.*/\1/')
  if pkg_installed lotion && [[ "$(dpkg-query -W -f='${Version}' lotion)" == "$ver"* ]]; then
    info "Lotion $ver already installed"
    return 0
  fi
  curl -fsSLo "$WORK/lotion.deb" "$url"
  apt_install "$WORK/lotion.deb"
  info "Installed Lotion $ver"
}

step_aseprite() {
  log "Aseprite (build from source)"
  local prefix=/opt/aseprite
  local src="$HOME/.cache/aseprite-build"
  local tag
  tag=$(curl -fsSL https://api.github.com/repos/aseprite/aseprite/releases/latest \
        | grep -oE '"tag_name": *"[^"]+"' | cut -d'"' -f4)
  [[ -n $tag ]] || die "Could not determine latest Aseprite release"

  if [[ -x $prefix/aseprite && "$(cat "$prefix/.version" 2>/dev/null)" == "$tag" ]]; then
    info "Aseprite $tag already built and installed"
    return 0
  fi
  info "Building Aseprite $tag (this takes a while)"

  apt_install g++ clang cmake ninja-build unzip libx11-dev libxcursor-dev libxi-dev \
              libxrandr-dev libgl1-mesa-dev libfontconfig1-dev
  # clang uses the newest GCC install it finds for libstdc++; make sure its
  # headers exist or compilation fails with "'cstdint' file not found" etc.
  local gccver
  gccver=$(ls /usr/lib/gcc/x86_64-linux-gnu/ 2>/dev/null | grep -E '^[0-9]+$' | sort -n | tail -n1 || true)
  if [[ -n $gccver ]]; then apt_install "libstdc++-${gccver}-dev"; fi

  # Source
  rm -rf "$src"
  git clone --recursive --depth 1 --branch "$tag" https://github.com/aseprite/aseprite.git "$src/aseprite" \
    || { rm -rf "$src/aseprite"; git clone --recursive --branch "$tag" https://github.com/aseprite/aseprite.git "$src/aseprite"; }

  # Prebuilt Skia matching the milestone this release documents (e.g. aseprite-m124)
  local milestone skia_tag skia_dir lib
  milestone=$(grep -oE 'aseprite-m[0-9]+' "$src/aseprite/INSTALL.md" 2>/dev/null | head -n1 | sed 's/aseprite-//' || true)
  milestone=${milestone:-m124}
  skia_tag=$(curl -fsSL "https://api.github.com/repos/aseprite/skia/releases?per_page=50" \
             | grep -oE '"tag_name": *"[^"]+"' | cut -d'"' -f4 | grep -E "^${milestone}-" | head -n1 || true)
  skia_tag=${skia_tag:-m124-08a5439a6b}
  info "Using Skia $skia_tag"
  skia_dir="$src/skia"
  mkdir -p "$skia_dir"
  curl -fsSLo "$src/skia.zip" "https://github.com/aseprite/skia/releases/download/$skia_tag/Skia-Linux-Release-x64.zip"
  unzip -q -o "$src/skia.zip" -d "$skia_dir"
  lib=$(find "$skia_dir" -name libskia.a -path '*Release-x64*' | head -n1 || true)
  [[ -n $lib ]] || die "libskia.a not found in Skia archive"
  local libdir; libdir=$(dirname "$lib")
  local skia_root; skia_root=$(dirname "$(dirname "$libdir")")   # .../out/Release-x64 -> root

  # Build (per INSTALL.md "Linux details": clang + libstdc++ with prebuilt Skia)
  mkdir -p "$src/aseprite/build"
  (
    cd "$src/aseprite/build"
    export CC=clang CXX=clang++
    cmake \
      -DCMAKE_BUILD_TYPE=RelWithDebInfo \
      -DCMAKE_CXX_FLAGS:STRING=-stdlib=libstdc++ \
      -DCMAKE_EXE_LINKER_FLAGS:STRING=-stdlib=libstdc++ \
      -DLAF_BACKEND=skia \
      -DSKIA_DIR="$skia_root" \
      -DSKIA_LIBRARY_DIR="$libdir" \
      -DSKIA_LIBRARY="$lib" \
      -DENABLE_TESTS=OFF \
      -G Ninja ..
    ninja aseprite
  )

  # Install to /opt/aseprite (binary needs its data/ folder next to it)
  sudo rm -rf "$prefix"
  sudo mkdir -p "$prefix"
  sudo cp -a "$src/aseprite/build/bin/." "$prefix/"
  echo "$tag" | sudo tee "$prefix/.version" >/dev/null
  sudo ln -sf "$prefix/aseprite" /usr/local/bin/aseprite

  local icon
  icon=$(find "$prefix/data/icons" -name 'ase256.png' 2>/dev/null | head -n1 || true)
  [[ -n $icon ]] || icon=$(ls -S "$prefix"/data/icons/ase*.png 2>/dev/null | head -n1 || true)
  sudo mkdir -p /usr/local/share/applications
  write_root_file /usr/local/share/applications/aseprite.desktop "[Desktop Entry]
Type=Application
Name=Aseprite
GenericName=Sprite Editor
Comment=Animated sprite editor & pixel art tool
Exec=$prefix/aseprite %F
Icon=${icon:-aseprite}
Terminal=false
Categories=Graphics;2DGraphics;RasterGraphics;
StartupWMClass=Aseprite"
  sudo update-desktop-database /usr/local/share/applications 2>/dev/null || true

  rm -rf "$src"  # free ~several GB of build files
  info "Aseprite $tag installed to $prefix"
}

step_claude() {
  log "Claude Code"
  if [[ -x $HOME/.local/bin/claude ]]; then
    info "Already installed; updating"
    "$HOME/.local/bin/claude" update || true
  else
    curl -fsSL https://claude.ai/install.sh | bash
  fi
  local f
  while read -r f; do
    ensure_rc_block "$f" "local-bin-path" 'case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac'
  done < <(shell_rc_files)
  "$HOME/.local/bin/claude" --version
}

# --- hotkeys -----------------------------------------------------------------

# cinnamon_bind <name> <command> <binding>, e.g. cinnamon_bind Terminal alacritty '<Super>t'
cinnamon_bind() {
  local name=$1 cmd=$2 binding=$3
  local schema=org.cinnamon.desktop.keybindings
  local base=/org/cinnamon/desktop/keybindings/custom-keybindings
  local ids id="" i n
  ids=$(gsettings get "$schema" custom-list | python3 -c '
import ast, sys
s = sys.stdin.read().strip()
if s.startswith("@as"): s = s[3:].strip()
print(" ".join(ast.literal_eval(s)))')

  # Reuse an entry with the same name (re-runs), else take the next free customN.
  for i in $ids; do
    n=$(gsettings get "$schema.custom-keybinding:$base/$i/" name 2>/dev/null || true)
    [[ $n == "'$name'" ]] && { id=$i; break; }
  done
  if [[ -z $id ]]; then
    n=0
    while [[ " $ids " == *" custom$n "* ]]; do n=$((n + 1)); done
    id="custom$n"
  fi

  local path="$schema.custom-keybinding:$base/$id/"
  gsettings set "$path" name "$name"
  gsettings set "$path" command "$cmd"
  gsettings set "$path" binding "['$binding']"

  # Re-set the list (without, then with, the id) so Cinnamon reloads it live.
  local others=() ; for i in $ids; do [[ $i != "$id" ]] && others+=("$i"); done
  to_gvariant() { python3 -c 'import sys; a = sys.argv[1:]; print(repr(a) if a else "@as []")' "$@"; }
  gsettings set "$schema" custom-list "$(to_gvariant "${others[@]}")"
  gsettings set "$schema" custom-list "$(to_gvariant "${others[@]}" "$id")"
  info "$binding -> $cmd  ($id)"
}

xfce_bind() {
  local cmd=$1 binding=$2
  xfconf-query -c xfce4-keyboard-shortcuts -p "/commands/custom/$binding" -s "$cmd" 2>/dev/null \
    || xfconf-query -c xfce4-keyboard-shortcuts -p "/commands/custom/$binding" -n -t string -s "$cmd"
  info "$binding -> $cmd"
}

step_hotkeys() {
  log "Hotkeys: Super+T terminal, Super+B browser"
  [[ -n ${DBUS_SESSION_BUS_ADDRESS:-} ]] || warn "No desktop session bus detected; run this step from inside your desktop session"
  if gsettings list-schemas 2>/dev/null | grep -x org.cinnamon.desktop.keybindings >/dev/null; then
    cinnamon_bind "Terminal (Alacritty)" "alacritty" "<Super>t"
    cinnamon_bind "Browser (Vivaldi)" "vivaldi-stable" "<Super>b"
  elif have xfconf-query; then
    xfce_bind alacritty "<Super>t"
    xfce_bind vivaldi-stable "<Super>b"
  else
    warn "Unsupported desktop (${XDG_CURRENT_DESKTOP:-unknown}); add Super+T / Super+B manually"
  fi
}

# ----------------------------------------------------------------------------- main

usage() { sed -n '3,/^# ====/p' "$0" | sed 's/^# \{0,1\}//' | head -n -1; }

main() {
  local only="" skip=""
  while [[ $# -gt 0 ]]; do
    case $1 in
      --only) only=$2; shift 2 ;;
      --skip) skip=$2; shift 2 ;;
      --list) printf '%s\n' "${ALL_STEPS[@]}"; exit 0 ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown option: $1 (see --help)" ;;
    esac
  done

  [[ $EUID -ne 0 ]] || die "Run as your normal user (not root/sudo). The script calls sudo when needed."
  have apt-get || die "This script targets Debian/Ubuntu/Mint (apt)."
  ARCH=$(dpkg --print-architecture)
  [[ $ARCH == amd64 ]] || die "Only amd64 is supported (Unity Hub and prebuilt Skia are x86_64-only)."

  local steps=() s
  for s in "${ALL_STEPS[@]}"; do
    [[ -n $only && ",$only," != *",$s,"* ]] && continue
    [[ -n $skip && ",$skip," == *",$s,"* ]] && continue
    steps+=("$s")
  done
  # Everything needs curl/gpg/git; always do base first unless explicitly skipped.
  if [[ -n $only && ",$only," != *",base,"* && ",$skip," != *",base,"* ]]; then
    steps=(base "${steps[@]}")
  fi
  [[ ${#steps[@]} -gt 0 ]] || die "No steps selected (see --list)"

  echo "Steps: ${steps[*]}"
  sudo -v || die "sudo is required"
  # Keep sudo alive for the long Aseprite build.
  ( while kill -0 "$$" 2>/dev/null; do sudo -n true; sleep 50; done ) 2>/dev/null &
  local keepalive=$!

  WORK=$(mktemp -d)
  chmod 755 "$WORK"  # lets apt's _apt user read local .debs
  trap 'kill '"$keepalive"' 2>/dev/null; rm -rf "$WORK"' EXIT

  local ok=() failed=() rc
  for s in "${steps[@]}"; do
    # Run each step in a subshell with errexit so one failure doesn't stop the rest.
    set +e
    ( set -e; "step_$s" )
    rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then ok+=("$s"); else failed+=("$s"); warn "Step '$s' failed (exit $rc)"; fi
  done

  log "Summary"
  [[ ${#ok[@]}     -gt 0 ]] && printf '  \033[1;32mOK\033[0m     %s\n' "${ok[@]}"
  [[ ${#failed[@]} -gt 0 ]] && printf '  \033[1;31mFAILED\033[0m %s\n' "${failed[@]}"
  cat <<'EOF'

Next steps:
  - Open a NEW terminal (or run: source ~/.bashrc) so PATH changes apply.
  - Mullvad:  sudo systemctl enable --now mullvad-daemon
              mullvad account login <number>  then  mullvad connect
  - Claude:   run `claude` and log in.
  - Unity:    open Unity Hub, sign in, install an Editor. In a project, set
              Edit > Preferences > External Tools > External Script Editor = Visual Studio Code
              (the "Visual Studio Editor" package must be installed in the project; it is by default).
EOF
  [[ ${#failed[@]} -eq 0 ]]
}

main "$@"
