`wg-udp2raw`
============

Runs WireGuard over a fake TCP connection using `udp2raw`.

`wg-udp2raw` was created to ease running a [WireGuard](https://www.wireguard.com/) connection over a fake TCP connection using [`udp2raw`](https://github.com/wangyu-/udp2raw). It doesn't just setup `udp2raw` to wrap WireGuard, but also implements a watchdog that periodically checks whether the route to the WireGuard endpoint has changed and restarts `udp2raw` if necessary.

One can e.g. use hooks to nicely integrate `wg-udp2raw` into WireGuard. You'll find an [example WireGuard config](./etc/wireguard/wg-udp2raw.conf) (check `/etc/wireguard/<config>.conf`) intended to be used with [`wg-quick`](https://www.man7.org/linux/man-pages/man8/wg-quick.8.html) in this repository, but any other WireGuard management solution (e.g. NetworkManager) should work equally well if it has support for hooks. Take special care about the example's lower `MTU` of 1342 bytes due to `udp2raw`'s package size limitations, the `PreUp`, `PostUp`, and `PostDown` hooks, as well as the `Endpoint` always pointing to `127.0.0.1` (with an arbitrary local port) to tell WireGuard to connect to the endpoint via `udp2raw`.

`wg-udp2raw` expects the `udp2raw@.service` Systemd unit to start `udp2raw` using the `/etc/udp2raw/<config>.conf` config file. `wg-udp2raw` will modify this config file to match what was passed to it as arguments. It will also be responsible for resolving the endpoint's hostname, and adding a direct route to the endpoint via the default interface (i.e. bypassing any VPN and thus not creating a traffic loop). You'll find the correct [`udp2raw` config](./etc/udp2raw/wg-udp2raw.conf) in this repository. It's strongly recommended that the Systemd unit starts `udp2raw` with an unprivileged user. If your distribution doesn't ship `udp2raw` with such Systemd unit, you can find an [example Systemd unit](./etc/systemd/system/udp2raw@.service) in this repository.

On the endpoint's side one should use a similar `udp2raw@.service` Systemd unit to permanently run a `udp2raw` server instance with matching configuration. On the server's side there's no need for `wg-udp2raw`.

`wg-udp2raw` was written to run with [GNU Bash](https://www.gnu.org/software/bash/). It requires the [iproute2](https://wiki.linuxfoundation.org/networking/iproute2) utilities, [sed](https://sed.sourceforge.io/), [GNU awk](https://www.gnu.org/software/gawk/), [GNU grep](https://www.gnu.org/software/grep/), `getent` from the [GNU C library](https://www.gnu.org/software/libc/), and - obviously - [`udp2raw`](https://github.com/wangyu-/udp2raw) to be installed.

Made with ❤️ by [Daniel Rudolf](https://www.daniel-rudolf.de/) ([@PhrozenByte](https://github.com/PhrozenByte)). `wg-udp2raw` is free and open source software, released under the terms of the [MIT license](LICENSE).

Usage
-----

To get started simply install the [`wg-udp2raw.sh`](./wg-udp2raw.sh) script to `/usr/local/lib/wg-udp2raw/wg-udp2raw.sh`, create the [`/etc/wireguard/wg-udp2raw.conf`](./etc/wireguard/wg-udp2raw.conf) and [`/etc/udp2raw/wg-udp2raw.conf`](./etc/udp2raw/wg-udp2raw.conf) configs, make sure that the [`wg-quick@.service`](https://www.man7.org/linux/man-pages/man8/wg-quick.8.html) and [`udp2raw@.service`](./etc/systemd/system/udp2raw@.service) Systemd units are present, and start WireGuard with `systemctl start wg-quick@wg-udp2raw.service`.

The `wg-udp2raw.sh` script accepts the following arguments:

```console
$ ./wg-udp2raw.sh --help
Usage:
  ./wg-udp2raw.sh up <config> <endpoint_hostname> <endpoint_port> <local_port>
  ./wg-udp2raw.sh down <config>
  ./wg-udp2raw.sh watchdog <config> <interval>
```

On the server's side you don't need `wg-udp2raw`: You simply run both WireGuard and `udp2raw` permanently. The WireGuard setup doesn't differ from your usual setup. For `udp2raw` to work you just need to create a matching server config and start the `udp2raw@.service` Systemd unit permamently (`systemctl enable udp2raw@wg.service` and `systemctl start udp2raw@wg.service`). Here's an example `udp2raw` config (`/etc/udp2raw/wg.config`) for the server:

```
-s
-l 0.0.0.0:51820
-r 127.0.0.1:51820
--raw-mode faketcp
--cipher-mode xor
--auth-mode simple
-k wg-udp2raw vpn.example.com:51820
```
