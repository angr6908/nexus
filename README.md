# nexus

## Configuration

| Variable | Default | Description |
| --- | --- | --- |
| `PASSWORD` | random | Shared password for Hysteria2, Snell PSK, **and** Trojan. If unset, a random password is generated on each container start. |
| `WARP` | `false` | Set to `true` to bring up Cloudflare WARP as a system-level WireGuard interface. All container traffic (sing-box **and** snell-server) egresses through WARP. |