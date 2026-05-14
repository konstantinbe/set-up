# Set Up

Utilities for preparing fresh machines.

## Ubuntu test-machine setup

`set-up-ubuntu.sh` configures a fresh Ubuntu machine for testing and development. It is designed to be idempotent, so it can be run repeatedly to refresh configuration without duplicating entries.

It installs and configures:

- Git, curl, OpenSSH, Avahi/mDNS, GNOME Remote Desktop, Neovim
- Swift via `swiftly`
- Passwordless sudo for the current user
- SSH server access and authorized login keys
- Neovim as the default CLI editor
- Global Git identity

## Usage

On an Ubuntu machine:

```bash
./set-up-ubuntu.sh
```

The script will explain the changes it plans to make, ask for confirmation, and request the Ubuntu login password once for privileged setup steps.

## License

MIT. See [LICENSE](LICENSE).
