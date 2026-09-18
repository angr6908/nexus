# nexus

Hysteria2, VLESS-Reality, Trojan and Snell v5 in one sing-box container, with optional Cloudflare WARP egress.

Inbounds: Hysteria2 `:55555/udp` · VLESS-Reality `:55556` · Trojan `:55557` · Snell v5 `:55558`. Client URLs are printed on start. Requires sing-box ≥ 1.14.0.

## Configuration

| Variable | Default | Description |
| --- | --- | --- |
| `PASSWORD` | random | Shared secret for Hysteria2, Trojan and Snell. Regenerated on every start if unset. |
| `WARP` | `false` | `true` brings up WARP (WireGuard) and routes all egress through it. Needs `NET_ADMIN`. |
| `WARP_ENDPOINT` | `engage.cloudflareclient.com:2408` | WARP server; anycast, IPv6 where available. |
| `WARP_MTU` | `1420` | WARP interface MTU. |
| `WARP_KEEPALIVE` | `25` | `PersistentKeepalive` seconds; `0` disables. |

Persist `/data` across restarts (WARP account, generated config, `nexus.log`). See `compose.yml` for a full example.
