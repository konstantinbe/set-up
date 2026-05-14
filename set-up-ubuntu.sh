#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
  echo "This script needs bash 4 or newer."
  exit 1
fi

CURRENT_USER="${SUDO_USER:-${USER}}"
USER_HOME="$(getent passwd "$CURRENT_USER" | cut -d: -f6)"
SUDOERS_FILE="/etc/sudoers.d/90-${CURRENT_USER}-passwordless"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
info() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok() { printf '\033[1;32m✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m! %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31mError: %s\033[0m\n' "$*" >&2; exit 1; }

run_sudo() {
  # Preserve stdin for commands like `sudo tee` once sudo is already valid;
  # otherwise provide the password non-interactively.
  if sudo -n true 2>/dev/null; then
    sudo "$@"
  else
    printf '%s\n' "$LOGIN_PASSWORD" | sudo -S "$@"
  fi
}

require_ubuntu() {
  [[ -r /etc/os-release ]] || fail "Cannot find /etc/os-release. This script is intended for Ubuntu."
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || fail "This script is intended for Ubuntu; detected '${ID:-unknown}'."
}

confirm_plan() {
  cat <<EOF
$(bold "Fresh Ubuntu test-machine setup")

This script is idempotent: it is safe to run repeatedly. Existing packages,
keys, sudo rules, SSH settings, and git settings will be reused or updated
without creating duplicates.

This script will configure this machine for testing by doing the following:

  • Install packages:
      git, curl, OpenSSH server/client, Swift via swiftly, Avahi/mDNS tools,
      GNOME Remote Desktop support, and Neovim.

  • Configure:
      Neovim as the default CLI editor
      Passwordless sudo for user: ${CURRENT_USER}
      SSH login via openssh-server
      SSH key generation for ${CURRENT_USER}
      Passwordless SSH login keys for konstantinbe and ai
      Avahi/mDNS discovery and name resolution
      Remote Desktop sharing + control using the same username/password as ${CURRENT_USER}
      Global git user.name and user.email for ${CURRENT_USER}

You will be asked for your Ubuntu login password once. It is used to run sudo
commands and to set the GNOME Remote Desktop credentials to match your login.
EOF

  printf '\nContinue? [y/N] '
  read -r answer
  case "$answer" in
    y|Y|yes|YES) ;;
    *) echo "Aborted."; exit 0 ;;
  esac
}

ask_inputs() {
  printf '\nUbuntu login password for %s: ' "$CURRENT_USER"
  read -rs LOGIN_PASSWORD
  printf '\n'

  info "Checking sudo access"
  run_sudo -v || fail "sudo authentication failed."
  ok "sudo access confirmed"

  local existing_git_name existing_git_email
  existing_git_name="$(run_sudo -u "$CURRENT_USER" -H git config --global --get user.name 2>/dev/null || true)"
  existing_git_email="$(run_sudo -u "$CURRENT_USER" -H git config --global --get user.email 2>/dev/null || true)"

  if [[ -n "$existing_git_name" ]]; then
    printf '\nGit user.name [%s]: ' "$existing_git_name"
  else
    printf '\nGit user.name: '
  fi
  read -r GIT_NAME
  GIT_NAME="${GIT_NAME:-$existing_git_name}"
  [[ -n "$GIT_NAME" ]] || fail "git user.name cannot be empty."

  if [[ -n "$existing_git_email" ]]; then
    printf 'Git user.email [%s]: ' "$existing_git_email"
  else
    printf 'Git user.email: '
  fi
  read -r GIT_EMAIL
  GIT_EMAIL="${GIT_EMAIL:-$existing_git_email}"
  [[ -n "$GIT_EMAIL" ]] || fail "git user.email cannot be empty."
}

install_packages() {
  info "Updating apt package indexes"
  run_sudo apt-get update
  ok "apt package indexes updated"

  info "Enabling Ubuntu universe repository for optional Avahi tools"
  run_sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y software-properties-common ca-certificates curl
  run_sudo add-apt-repository -y universe || true
  run_sudo apt-get update
  ok "universe repository is available"

  info "Installing base tools, SSH, Avahi, GNOME Remote Desktop, and Neovim"
  run_sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates \
    curl \
    git \
    neovim \
    openssh-client \
    openssh-server \
    avahi-daemon \
    avahi-utils \
    avahi-discover \
    avahi-autoipd \
    libnss-mdns \
    mdns-scan \
    gnome-remote-desktop \
    dbus-x11
  ok "packages installed"
}

install_swiftly() {
  if command -v swiftly >/dev/null 2>&1 || [[ -x "$USER_HOME/.local/bin/swiftly" ]]; then
    ok "swiftly is already installed"
  else
    info "Installing swiftly for ${CURRENT_USER}"
    run_sudo -u "$CURRENT_USER" -H bash -lc 'curl -L https://swiftlang.github.io/swiftly/swiftly-install.sh | bash -s -- -y'
    ok "swiftly installed"
  fi

  info "Ensuring a Swift toolchain is installed via swiftly"
  run_sudo -u "$CURRENT_USER" -H bash -lc '
    set -e
    if [[ -f "$HOME/.local/share/swiftly/env.sh" ]]; then
      source "$HOME/.local/share/swiftly/env.sh"
    fi

    if ! command -v swiftly >/dev/null 2>&1; then
      echo "swiftly was installed, but is not on PATH yet. Open a new shell and run: swiftly install latest"
      exit 0
    fi

    if command -v swift >/dev/null 2>&1; then
      swift --version | head -n 1
      exit 0
    fi

    swiftly install latest
    swiftly use latest
  '
  ok "Swift toolchain is available"
}

configure_editor() {
  info "Setting Neovim as the default CLI editor"
  run_sudo update-alternatives --install /usr/bin/editor editor /usr/bin/nvim 100
  run_sudo update-alternatives --set editor /usr/bin/nvim

  # Append each export only if it is not already present.
  run_sudo -u "$CURRENT_USER" -H bash -lc '
    set -euo pipefail
    profile="$HOME/.profile"
    touch "$profile"
    grep -qxF "export EDITOR=nvim" "$profile" || printf "\nexport EDITOR=nvim\n" >> "$profile"
    grep -qxF "export VISUAL=nvim" "$profile" || printf "export VISUAL=nvim\n" >> "$profile"
  '
  ok "Neovim is the default editor"
}

configure_passwordless_sudo() {
  info "Enabling passwordless sudo for ${CURRENT_USER}"
  printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$CURRENT_USER" | run_sudo tee "$SUDOERS_FILE" >/dev/null
  run_sudo chmod 0440 "$SUDOERS_FILE"
  run_sudo visudo -cf "$SUDOERS_FILE" >/dev/null
  ok "passwordless sudo enabled"
}

configure_ssh() {
  info "Enabling SSH login"
  run_sudo systemctl enable --now ssh

  if command -v ufw >/dev/null 2>&1 && run_sudo ufw status | grep -q 'Status: active'; then
    run_sudo ufw allow OpenSSH
  fi

  local sshd_config="/etc/ssh/sshd_config.d/99-testing-login.conf"
  run_sudo tee "$sshd_config" >/dev/null <<'EOF'
PasswordAuthentication yes
KbdInteractiveAuthentication yes
PubkeyAuthentication yes
PermitRootLogin no
EOF
  run_sudo systemctl reload ssh || run_sudo systemctl restart ssh
  ok "SSH login enabled"
}

configure_ssh_keys() {
  info "Generating SSH keys and installing authorized login keys"

  run_sudo -u "$CURRENT_USER" -H bash -lc '
    set -euo pipefail
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"

    if [[ ! -f "$HOME/.ssh/id_ed25519" ]]; then
      ssh-keygen -t ed25519 -a 100 -N "" -C "${USER}@$(hostname)-$(date +%Y%m%d)" -f "$HOME/.ssh/id_ed25519"
    elif [[ ! -f "$HOME/.ssh/id_ed25519.pub" ]]; then
      ssh-keygen -y -f "$HOME/.ssh/id_ed25519" > "$HOME/.ssh/id_ed25519.pub"
    fi

    [[ ! -f "$HOME/.ssh/id_ed25519" ]] || chmod 600 "$HOME/.ssh/id_ed25519"
    [[ ! -f "$HOME/.ssh/id_ed25519.pub" ]] || chmod 644 "$HOME/.ssh/id_ed25519.pub"
    touch "$HOME/.ssh/authorized_keys"
    chmod 600 "$HOME/.ssh/authorized_keys"
  '

  local konstantinbe_key="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGYXUzgS66WuArPebeKxMU7NG7k1/9xnsG86B0+BjZqe me@konstantinbender.com"
  local ai_key="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM17W+YWrRkj1ME61zw+Mrorq1cchRgE1KGv0PR/X4JP me@konstantinbender.com"

  for key in "$konstantinbe_key" "$ai_key"; do
    local key_type key_body
    key_type="$(awk '{print $1}' <<<"$key")"
    key_body="$(awk '{print $2}' <<<"$key")"

    if ! run_sudo -u "$CURRENT_USER" -H awk -v type="$key_type" -v body="$key_body" \
      '$1 == type && $2 == body { found = 1 } END { exit !found }' "$USER_HOME/.ssh/authorized_keys"; then
      printf '%s\n' "$key" | run_sudo -u "$CURRENT_USER" -H tee -a "$USER_HOME/.ssh/authorized_keys" >/dev/null
    fi
  done

  run_sudo -u "$CURRENT_USER" -H chmod 700 "$USER_HOME/.ssh"
  run_sudo -u "$CURRENT_USER" -H chmod 600 "$USER_HOME/.ssh/authorized_keys"
  ok "SSH keys configured"
}

configure_avahi() {
  info "Enabling Avahi/mDNS services"
  run_sudo systemctl enable --now avahi-daemon

  if command -v ufw >/dev/null 2>&1 && run_sudo ufw status | grep -q 'Status: active'; then
    run_sudo ufw allow 5353/udp comment 'mDNS/Avahi'
  fi

  if [[ -f /etc/nsswitch.conf ]]; then
    # Ensure .local name resolution works. Ubuntu often does this automatically
    # when libnss-mdns is installed, but keep it explicit for fresh test boxes.
    if ! grep -Eq '^hosts:.*mdns4_minimal' /etc/nsswitch.conf; then
      run_sudo cp /etc/nsswitch.conf /etc/nsswitch.conf.bak-before-avahi
      run_sudo sed -i -E 's/^(hosts:[[:space:]]*files)([[:space:]]|$)/\1 mdns4_minimal [NOTFOUND=return] /' /etc/nsswitch.conf
    fi
  fi

  ok "Avahi/mDNS enabled"
}

configure_remote_desktop() {
  info "Configuring GNOME Remote Desktop sharing + control"

  if ! command -v grdctl >/dev/null 2>&1; then
    warn "grdctl was not found; gnome-remote-desktop may not support CLI setup on this Ubuntu release."
    return 0
  fi

  # Run in the user's graphical/session context when possible. This is how
  # GNOME stores Remote Desktop settings and credentials.
  local uid runtime_dir session_bus
  uid="$(id -u "$CURRENT_USER")"
  runtime_dir="/run/user/${uid}"
  session_bus="unix:path=${runtime_dir}/bus"

  if [[ ! -S "${runtime_dir}/bus" ]]; then
    warn "No active GNOME user session bus found. Log in graphically as ${CURRENT_USER}, then rerun this script to finish Remote Desktop setup."
    return 0
  fi

  run_sudo -u "$CURRENT_USER" \
    XDG_RUNTIME_DIR="$runtime_dir" \
    DBUS_SESSION_BUS_ADDRESS="$session_bus" \
    grdctl rdp set-credentials "$CURRENT_USER" "$LOGIN_PASSWORD" || warn "Could not set RDP credentials."

  run_sudo -u "$CURRENT_USER" \
    XDG_RUNTIME_DIR="$runtime_dir" \
    DBUS_SESSION_BUS_ADDRESS="$session_bus" \
    grdctl rdp enable || warn "Could not enable RDP."

  # If supported by this grdctl/GNOME version, allow control rather than view-only.
  run_sudo -u "$CURRENT_USER" \
    XDG_RUNTIME_DIR="$runtime_dir" \
    DBUS_SESSION_BUS_ADDRESS="$session_bus" \
    grdctl rdp disable-view-only >/dev/null 2>&1 || true

  run_sudo -u "$CURRENT_USER" \
    XDG_RUNTIME_DIR="$runtime_dir" \
    DBUS_SESSION_BUS_ADDRESS="$session_bus" \
    gsettings set org.gnome.desktop.remote-desktop.rdp enable true >/dev/null 2>&1 || true
  run_sudo -u "$CURRENT_USER" \
    XDG_RUNTIME_DIR="$runtime_dir" \
    DBUS_SESSION_BUS_ADDRESS="$session_bus" \
    gsettings set org.gnome.desktop.remote-desktop.rdp view-only false >/dev/null 2>&1 || true

  if command -v ufw >/dev/null 2>&1 && run_sudo ufw status | grep -q 'Status: active'; then
    run_sudo ufw allow 3389/tcp comment 'GNOME Remote Desktop RDP'
  fi

  run_sudo systemctl --global enable gnome-remote-desktop.service >/dev/null 2>&1 || true
  ok "GNOME Remote Desktop configured where supported"
}

configure_git() {
  info "Configuring git identity for ${CURRENT_USER}"
  run_sudo -u "$CURRENT_USER" -H git config --global user.name "$GIT_NAME"
  run_sudo -u "$CURRENT_USER" -H git config --global user.email "$GIT_EMAIL"
  ok "git identity configured"
}

summary() {
  local hostname_ip public_key
  hostname_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  public_key="$(run_sudo -u "$CURRENT_USER" -H bash -lc 'cat "$HOME/.ssh/id_ed25519.pub" 2>/dev/null || true')"
  cat <<EOF

$(bold "Setup complete")

Useful connection details:
  Username:        ${CURRENT_USER}
  Hostname:        $(hostname)
  mDNS name:       $(hostname).local
  Primary IP:      ${hostname_ip:-unknown}
  SSH:             ssh ${CURRENT_USER}@$(hostname).local
  Remote Desktop:  RDP to $(hostname).local using your ${CURRENT_USER} login

Generated SSH public key:
  ${public_key:-not available}

You may need to log out and back in for PATH/editor/session changes to appear.
EOF
}

main() {
  require_ubuntu
  confirm_plan
  ask_inputs
  configure_passwordless_sudo
  install_packages
  install_swiftly
  configure_editor
  configure_ssh
  configure_ssh_keys
  configure_avahi
  configure_remote_desktop
  configure_git
  summary
}

main "$@"
