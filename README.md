# river

river is a dynamic tiling wayland compositor that takes inspiration from
[dwm](https://dwm.suckless.org) and
[bspwm](https://github.com/baskerville/bspwm).

*Note: river is currently early in development. Expect breaking changes
and missing features. If you run into a bug don't hesitate to
[open an issue](https://github.com/ifreund/river/issues/new)*

## Design goals

- Simplicity and minimalism, river should not overstep the bounds of a
window manager.
- Window management based on a stack of views and tags.
- Dynamic layouts generated by external, user-written executables. (A default
`rivertile` layout generator is provided.)
- Scriptable configuration and control through a custom wayland protocol and
separate `riverctl` binary implementing it.

## Building

On cloning the repository, you must init and update the submodules as well
with e.g.

```
git submodule update --init
```

To compile river first ensure that you have the following dependencies
installed:

- [zig](https://ziglang.org/download/) 0.7.1
- wayland
- wayland-protocols
- [wlroots](https://github.com/swaywm/wlroots) 0.13.0
- xkbcommon
- libevdev
- pixman
- pkg-config
- scdoc (optional, but required for man page generation)

*Note: NixOS users may refer to the
[Building on NixOS wiki page](https://github.com/ifreund/river/wiki/Building-on-NixOS)*

Then run, for example:
```
zig build -Drelease-safe --prefix /usr install
```
To enable experimental Xwayland support pass the `-Dxwayland` option as well.

## Install from package manager
Currently river is available in [nixpkgs](https://github.com/NixOS/nixpkgs) for Nix package manager users which follow **nixpkgs-master** channel.

*Note: river in nixpkgs is prebuild with manpages and xwayland support*
```
nix-env -iA nixpkgs.river
```

## Usage

River can either be run nested in an X11/wayland session or directly
from a tty using KMS/DRM.

On startup river will look for and run an executable file at one of the
following locations, checked in the order listed:

- `$XDG_CONFIG_HOME/river/init`
- `$HOME/.config/river/init`
- `/etc/river/init`

Usually this executable init file will be a shell script invoking riverctl
to create mappings and preform other configuration.

An example init script with sane defaults is provided [here](example/init)
in the example directory and installed to `/etc/river/init`.

For complete documentation see the `river(1)`, `riverctl(1)`, and
`rivertile(1)` man pages.

## Development

If you are interested in the development of river, please join us at
[#river](https://webchat.freenode.net/#river) on freenode. You should also
read [CONTRIBUTING.md](CONTRIBUTING.md) if you intend to submit patches.

## Licensing

river is released under the GNU General Public License version 3, or (at your
option) any later version.

The protocols in the `protocol` directory are released under various licenses by
various parties. You should refer to the copyright block of each protocol for
the licensing information. The protocols prefixed with `river` and developed by
this project are released under the ISC license (as stated in their copyright
blocks).
