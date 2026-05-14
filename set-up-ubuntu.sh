#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
  echo "This script needs bash 4 or newer." >&2
  exit 1
fi

readonly GIT_NAME="Konstantin Bender"
readonly GIT_EMAIL="me@konstantinbender.com"
readonly TRACE_COMMANDS="${TRACE_COMMANDS:-1}"

CURRENT_USER="${SUDO_USER:-$(id -un)}"
USER_HOME="$(getent passwd "$CURRENT_USER" | cut -d: -f6 || true)"
readonly CURRENT_USER USER_HOME
readonly SUDOERS_FILE="/etc/sudoers.d/90-${CURRENT_USER}-passwordless"

LOGIN_PASSWORD=""
PS4='+ ${BASH_SOURCE##*/}:${LINENO}: '

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
info() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok() { printf '\033[1;32m✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m! %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31mError: %s\033[0m\n' "$*" >&2; exit 1; }

on_error() {
  local exit_code=$?
  local line_no="${1:-unknown}"
  set +x 2>/dev/null || true
  fail "setup failed at line ${line_no} with exit code ${exit_code}"
}
trap 'on_error "$LINENO"' ERR

enable_command_trace() {
  [[ "$TRACE_COMMANDS" == "0" ]] && return 0
  set -x
}

sudo_authenticate() {
  sudo -n true 2>/dev/null && return 0

  local xtrace_was_enabled=0
  if [[ $- == *x* ]]; then
    xtrace_was_enabled=1
    set +x
  fi

  local status=0
  sudo -S -v <<<"$LOGIN_PASSWORD" || status=$?

  if (( xtrace_was_enabled )); then
    set -x
  fi

  return "$status"
}

run_sudo() {
  sudo_authenticate
  sudo "$@"
}

run_as_user() {
  run_sudo -H -u "$CURRENT_USER" "$@"
}

ufw_allow_if_active() {
  command -v ufw >/dev/null 2>&1 || return 0
  run_sudo ufw status | grep -q 'Status: active' || return 0
  run_sudo ufw allow "$@"
}

require_ubuntu() {
  [[ -r /etc/os-release ]] || fail "Cannot find /etc/os-release. This script is intended for Ubuntu."
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || fail "This script is intended for Ubuntu; detected '${ID:-unknown}'."
  [[ -n "$USER_HOME" ]] || fail "Could not determine home directory for ${CURRENT_USER}."
  [[ "$CURRENT_USER" != "root" ]] || fail "Run this as the normal Ubuntu user, not directly as root."
}

confirm_plan() {
  cat <<EOF
$(bold "Fresh Ubuntu test-machine setup")

This script is idempotent: it is safe to run repeatedly. Existing packages,
keys, sudo rules, SSH settings, and git settings will be reused or updated
without creating duplicates. Bash xtrace is enabled after password collection
so you can see what is being called; password-specific calls are redacted.

This script will configure this machine for testing by doing the following:

  • Install packages:
      OpenSSH server/client first, then git, curl, Swift via swiftly,
      Avahi/mDNS tools, GNOME Remote Desktop support, and Neovim.

  • Configure:
      SSH login via openssh-server as early as possible
      SSH key generation for ${CURRENT_USER}
      Passwordless SSH login keys for konstantinbe and ai
      Neovim as the default CLI editor
      Passwordless sudo for user: ${CURRENT_USER}
      Avahi/mDNS discovery and name resolution
      Remote Desktop sharing + control using the same username/password as ${CURRENT_USER}
      No automatic suspend, dimming, screen blanking, or locking while on AC power
      Global git user.name (${GIT_NAME}) and user.email (${GIT_EMAIL}) for ${CURRENT_USER}

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

ask_for_password() {
  printf '\nUbuntu login password for %s: ' "$CURRENT_USER"
  read -rs LOGIN_PASSWORD
  printf '\n'
  [[ -n "$LOGIN_PASSWORD" ]] || fail "Ubuntu login password cannot be empty; it is required for Remote Desktop credentials."

  info "Checking sudo access"
  sudo_authenticate || fail "sudo authentication failed."
  ok "sudo access confirmed"

  ok "git identity will be set to ${GIT_NAME} <${GIT_EMAIL}>"
}

install_ssh_packages() {
  info "Installing OpenSSH server/client first"
  run_sudo apt-get update
  run_sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    openssh-client \
    openssh-server
  ok "OpenSSH packages installed"
}

install_packages() {
  info "Updating apt package indexes"
  run_sudo apt-get update
  ok "apt package indexes updated"

  info "Ensuring Ubuntu universe repository is available"
  run_sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates \
    curl \
    software-properties-common

  if ! grep -RhsE '^[^#].*\buniverse\b' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
    run_sudo add-apt-repository -y universe
    run_sudo apt-get update
  fi
  ok "universe repository is available"

  info "Installing base tools, Avahi, GNOME Remote Desktop, and Neovim"
  run_sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    avahi-autoipd \
    avahi-daemon \
    avahi-discover \
    avahi-utils \
    ca-certificates \
    curl \
    dbus-x11 \
    git \
    gnome-remote-desktop \
    libnss-mdns \
    mdns-scan \
    neovim
  ok "packages installed"
}

install_swiftly() {
  if run_as_user bash -c '
    swiftly_env="${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}/env.sh"
    [[ ! -f "$swiftly_env" ]] || . "$swiftly_env"
    command -v swiftly >/dev/null 2>&1
  '; then
    ok "swiftly is already installed"
  else
    info "Installing swiftly for ${CURRENT_USER}"
    run_as_user bash -c '
      set -euo pipefail
      tmp_dir="$(mktemp -d)"
      cleanup() { rm -rf "$tmp_dir"; }
      trap cleanup EXIT

      cd "$tmp_dir"
      archive="swiftly-$(uname -m).tar.gz"
      curl -fLO "https://download.swift.org/swiftly/linux/${archive}"
      tar zxf "$archive"
      ./swiftly init --quiet-shell-followup
      . "${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}/env.sh"
      hash -r
    '
    ok "swiftly installed"
  fi

  info "Ensuring a Swift toolchain is installed via swiftly"
  run_as_user bash -c '
    set -euo pipefail

    swiftly_env="${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}/env.sh"
    if [[ -f "$swiftly_env" ]]; then
      source "$swiftly_env"
    fi

    if ! command -v swiftly >/dev/null 2>&1; then
      echo "swiftly was installed, but is not on PATH yet. Open a new shell and run: swiftly install latest"
    elif command -v swift >/dev/null 2>&1; then
      swift --version | head -n 1
    else
      swiftly install latest
      swiftly use latest
    fi
  '
  ok "Swift toolchain is available"
}

configure_editor() {
  info "Setting Neovim as the default CLI editor"
  run_sudo update-alternatives --install /usr/bin/editor editor /usr/bin/nvim 100
  run_sudo update-alternatives --set editor /usr/bin/nvim

  run_as_user bash -c '
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
  ufw_allow_if_active OpenSSH

  run_sudo install -d -m 0755 /etc/ssh/sshd_config.d
  run_sudo tee /etc/ssh/sshd_config.d/99-testing-login.conf >/dev/null <<'EOF'
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

  run_as_user bash -c '
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

  local key key_type key_body
  local authorized_keys="$USER_HOME/.ssh/authorized_keys"
  local authorized_login_keys=(
    'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGYXUzgS66WuArPebeKxMU7NG7k1/9xnsG86B0+BjZqe me@konstantinbender.com'
    'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM17W+YWrRkj1ME61zw+Mrorq1cchRgE1KGv0PR/X4JP me@konstantinbender.com'
  )

  for key in "${authorized_login_keys[@]}"; do
    key_type="$(awk '{print $1}' <<<"$key")"
    key_body="$(awk '{print $2}' <<<"$key")"

    if ! run_as_user awk -v type="$key_type" -v body="$key_body" \
      '$1 == type && $2 == body { found = 1 } END { exit !found }' "$authorized_keys"; then
      printf '%s\n' "$key" | run_as_user tee -a "$authorized_keys" >/dev/null
    fi
  done

  run_as_user chmod 700 "$USER_HOME/.ssh"
  run_as_user chmod 600 "$authorized_keys"
  ok "SSH keys configured"
}

configure_avahi() {
  info "Enabling Avahi/mDNS services"
  run_sudo systemctl enable --now avahi-daemon
  ufw_allow_if_active 5353/udp comment 'mDNS/Avahi'

  if [[ -f /etc/nsswitch.conf ]] && ! grep -Eq '^hosts:.*mdns4_minimal' /etc/nsswitch.conf; then
    run_sudo cp /etc/nsswitch.conf /etc/nsswitch.conf.bak-before-avahi
    run_sudo sed -i -E 's/^(hosts:[[:space:]]*files)([[:space:]]|$)/\1 mdns4_minimal [NOTFOUND=return] /' /etc/nsswitch.conf
  fi

  ok "Avahi/mDNS enabled"
}

configure_remote_desktop() {
  info "Configuring GNOME Remote Desktop sharing + control"

  if ! command -v grdctl >/dev/null 2>&1; then
    warn "grdctl was not found; gnome-remote-desktop may not support CLI setup on this Ubuntu release."
    return 0
  fi

  local uid runtime_dir session_bus
  uid="$(id -u "$CURRENT_USER")"
  runtime_dir="/run/user/${uid}"
  session_bus="unix:path=${runtime_dir}/bus"

  if [[ ! -S "${runtime_dir}/bus" ]]; then
    warn "No active GNOME user session bus found. Log in graphically as ${CURRENT_USER}, then rerun this script to finish Remote Desktop setup."
    return 0
  fi

  local xtrace_was_enabled=0 set_credentials_status=0
  if [[ $- == *x* ]]; then
    xtrace_was_enabled=1
    set +x
  fi

  printf '\033[2m$ sudo -H -u %q env XDG_RUNTIME_DIR=%q DBUS_SESSION_BUS_ADDRESS=%q grdctl rdp set-credentials %q <password>\033[0m\n' \
    "$CURRENT_USER" "$runtime_dir" "$session_bus" "$CURRENT_USER" >&2

  run_sudo -H -u "$CURRENT_USER" env \
    XDG_RUNTIME_DIR="$runtime_dir" \
    DBUS_SESSION_BUS_ADDRESS="$session_bus" \
    grdctl rdp set-credentials "$CURRENT_USER" "$LOGIN_PASSWORD" || set_credentials_status=$?

  if (( xtrace_was_enabled )); then
    set -x
  fi

  if (( set_credentials_status != 0 )); then
    warn "Could not set RDP credentials."
  fi

  run_sudo -H -u "$CURRENT_USER" env \
    XDG_RUNTIME_DIR="$runtime_dir" \
    DBUS_SESSION_BUS_ADDRESS="$session_bus" \
    grdctl rdp enable || warn "Could not enable RDP."

  run_sudo -H -u "$CURRENT_USER" env \
    XDG_RUNTIME_DIR="$runtime_dir" \
    DBUS_SESSION_BUS_ADDRESS="$session_bus" \
    grdctl rdp disable-view-only >/dev/null 2>&1 || true

  run_sudo -H -u "$CURRENT_USER" env \
    XDG_RUNTIME_DIR="$runtime_dir" \
    DBUS_SESSION_BUS_ADDRESS="$session_bus" \
    gsettings set org.gnome.desktop.remote-desktop.rdp enable true >/dev/null 2>&1 || true

  run_sudo -H -u "$CURRENT_USER" env \
    XDG_RUNTIME_DIR="$runtime_dir" \
    DBUS_SESSION_BUS_ADDRESS="$session_bus" \
    gsettings set org.gnome.desktop.remote-desktop.rdp view-only false >/dev/null 2>&1 || true

  ufw_allow_if_active 3389/tcp comment 'GNOME Remote Desktop RDP'
  run_sudo systemctl --global enable gnome-remote-desktop.service >/dev/null 2>&1 || true
  ok "GNOME Remote Desktop configured where supported"
}

configure_power_settings() {
  info "Disabling automatic sleep, dimming, and locking while on AC power"

  run_sudo tee /usr/local/bin/ubuntu-test-ac-power-mode >/dev/null <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

readonly CHECK_INTERVAL_SECONDS="${CHECK_INTERVAL_SECONDS:-30}"
readonly STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/ubuntu-test-setup"
readonly DEFAULTS_FILE="${STATE_DIR}/power-defaults.env"

mkdir -p "$STATE_DIR"
touch "$DEFAULTS_FILE"

run_gsettings() {
  if [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
    gsettings "$@"
  elif command -v dbus-launch >/dev/null 2>&1; then
    dbus-launch gsettings "$@"
  else
    gsettings "$@"
  fi
}

setting_exists() {
  run_gsettings range "$1" "$2" >/dev/null 2>&1
}

set_setting() {
  local schema="$1" key="$2" value="$3"
  setting_exists "$schema" "$key" || return 0
  run_gsettings set "$schema" "$key" "$value"
}

save_default() {
  local name="$1" schema="$2" key="$3" value
  setting_exists "$schema" "$key" || return 0
  grep -q "^${name}=" "$DEFAULTS_FILE" && return 0

  value="$(run_gsettings get "$schema" "$key")"
  printf '%s=%q\n' "$name" "$value" >> "$DEFAULTS_FILE"
}

restore_default() {
  local name="$1" schema="$2" key="$3" value
  setting_exists "$schema" "$key" || return 0

  # shellcheck disable=SC1090
  source "$DEFAULTS_FILE"
  eval "value=\${${name}:-}"
  [[ -n "${value:-}" ]] || return 0
  run_gsettings set "$schema" "$key" "$value"
}

save_defaults() {
  save_default IDLE_DIM org.gnome.settings-daemon.plugins.power idle-dim
  save_default IDLE_DELAY org.gnome.desktop.session idle-delay
  save_default LOCK_ENABLED org.gnome.desktop.screensaver lock-enabled
  save_default LOCK_DELAY org.gnome.desktop.screensaver lock-delay
  save_default UBUNTU_LOCK_ON_SUSPEND org.gnome.desktop.screensaver ubuntu-lock-on-suspend
}

is_on_ac_power() {
  local supply type online found_battery=0

  for supply in /sys/class/power_supply/*; do
    [[ -r "$supply/type" ]] || continue
    type="$(<"$supply/type")"

    if [[ "$type" == "Battery" ]]; then
      found_battery=1
      continue
    fi

    if [[ "$type" == "Mains" || "$type" == "USB" || "$type" == "USB_C" || "$type" == "USB_PD" ]]; then
      online="$(<"$supply/online" 2>/dev/null || printf '0')"
      [[ "$online" == "1" ]] && return 0
    fi
  done

  # Desktops and VMs often have no battery; treat them as AC-powered.
  (( found_battery == 0 ))
}

apply_ac_policy() {
  # AC-specific suspend behavior. Battery suspend settings are intentionally
  # left at their Ubuntu/GNOME defaults.
  set_setting org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type "nothing"
  set_setting org.gnome.settings-daemon.plugins.power sleep-inactive-ac-timeout 0

  # GNOME does not expose AC-only keys for dimming, blanking, or locking, so
  # this service applies those settings only while AC is connected and restores
  # the previous values when the machine switches back to battery.
  set_setting org.gnome.settings-daemon.plugins.power idle-dim false
  set_setting org.gnome.desktop.session idle-delay "uint32 0"
  set_setting org.gnome.desktop.screensaver lock-enabled false
  set_setting org.gnome.desktop.screensaver lock-delay "uint32 0"
  set_setting org.gnome.desktop.screensaver ubuntu-lock-on-suspend false
}

apply_battery_policy() {
  restore_default IDLE_DIM org.gnome.settings-daemon.plugins.power idle-dim
  restore_default IDLE_DELAY org.gnome.desktop.session idle-delay
  restore_default LOCK_ENABLED org.gnome.desktop.screensaver lock-enabled
  restore_default LOCK_DELAY org.gnome.desktop.screensaver lock-delay
  restore_default UBUNTU_LOCK_ON_SUSPEND org.gnome.desktop.screensaver ubuntu-lock-on-suspend
}

apply_current_policy() {
  save_defaults

  if is_on_ac_power; then
    apply_ac_policy
  else
    apply_battery_policy
  fi
}

case "${1:-}" in
  --once)
    apply_current_policy
    ;;
  *)
    while true; do
      apply_current_policy
      sleep "$CHECK_INTERVAL_SECONDS"
    done
    ;;
esac
EOF
  run_sudo chmod 0755 /usr/local/bin/ubuntu-test-ac-power-mode

  local uid runtime_dir session_bus user_unit_dir
  uid="$(id -u "$CURRENT_USER")"
  runtime_dir="/run/user/${uid}"
  session_bus="unix:path=${runtime_dir}/bus"
  user_unit_dir="$USER_HOME/.config/systemd/user"

  run_as_user install -d -m 0755 "$user_unit_dir" "$user_unit_dir/default.target.wants"
  run_as_user tee "$user_unit_dir/ubuntu-test-ac-power-mode.service" >/dev/null <<'EOF'
[Unit]
Description=Apply Ubuntu test-machine AC power policy
After=graphical-session.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ubuntu-test-ac-power-mode
Restart=always
RestartSec=5s

[Install]
WantedBy=default.target
EOF
  run_as_user ln -sfn ../ubuntu-test-ac-power-mode.service \
    "$user_unit_dir/default.target.wants/ubuntu-test-ac-power-mode.service"

  run_sudo loginctl enable-linger "$CURRENT_USER"

  if [[ -S "${runtime_dir}/bus" ]]; then
    run_as_user env XDG_RUNTIME_DIR="$runtime_dir" DBUS_SESSION_BUS_ADDRESS="$session_bus" \
      /usr/local/bin/ubuntu-test-ac-power-mode --once
    run_as_user env XDG_RUNTIME_DIR="$runtime_dir" DBUS_SESSION_BUS_ADDRESS="$session_bus" \
      systemctl --user daemon-reload
    run_as_user env XDG_RUNTIME_DIR="$runtime_dir" DBUS_SESSION_BUS_ADDRESS="$session_bus" \
      systemctl --user enable --now ubuntu-test-ac-power-mode.service
  else
    warn "No active user session bus found; AC power policy service will start on the next login."
  fi

  run_sudo install -d -m 0755 /etc/systemd/logind.conf.d
  run_sudo tee /etc/systemd/logind.conf.d/99-testing-ac-power.conf >/dev/null <<'EOF'
[Login]
HandleLidSwitchExternalPower=ignore
EOF
  run_sudo systemctl reload systemd-logind || run_sudo systemctl restart systemd-logind

  ok "AC power policy configured; battery defaults are restored while on battery"
}

configure_git() {
  info "Configuring git identity for ${CURRENT_USER}"
  run_as_user git config --global user.name "$GIT_NAME"
  run_as_user git config --global user.email "$GIT_EMAIL"
  ok "git identity configured"
}

summary() {
  local hostname_ip public_key
  hostname_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  public_key="$(run_as_user bash -c 'cat "$HOME/.ssh/id_ed25519.pub" 2>/dev/null || true')"

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
  ask_for_password
  enable_command_trace
  install_ssh_packages
  configure_ssh
  configure_ssh_keys
  configure_passwordless_sudo
  install_packages
  install_swiftly
  configure_editor
  configure_avahi
  configure_remote_desktop
  configure_power_settings
  configure_git
  summary
}

main "$@"
