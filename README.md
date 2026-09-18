# nexus

## Configuration

| Variable | Default | Description |
| --- | --- | --- |
| `PASSWORD` | random | Shared password for Hysteria2, Snell PSK, **and** Trojan. If unset, a random password is generated on each container start. |
| `WARP` | `false` | Set to `true` to bring up Cloudflare WARP as a system-level WireGuard interface. All container traffic (every sing-box inbound, Snell included) egresses through WARP. |
| `WARP_ENDPOINT` | `engage.cloudflareclient.com:2408` | WARP server to connect to. The hostname is resolved by Cloudflare's anycast DNS to the nearest edge, and to IPv6 where the host has it — often the faster path. Pin a literal only if you have a reason. |
| `WARP_MTU` | `1420` | MTU for the WARP interface, replacing wgcf's inherited 1280. Lower it if the host's path is known to be smaller than 1500. |

## WARP

WARP is registered through [wgcf](https://github.com/ViRb3/wgcf) (registration is required — an unregistered keypair does not complete a handshake), and the account is persisted in `/data/wgcf-account.toml` so restarts reuse one device instead of registering against Cloudflare's rate limit again.

wgcf's generated profile is deliberately not used verbatim, because two of its values are wrong for a VPS:

- **Endpoint.** wgcf pins the IPv4 address `162.159.192.1`. That is what `engage.cloudflareclient.com` resolves to over IPv4, but the hostname also resolves to IPv6, which on a dual-stack host is frequently much closer — a few ms instead of tens or hundreds. The hostname is restored into the profile so Cloudflare's anycast DNS picks the edge, rather than the literal baked in at registration.
- **MTU.** wgcf inherits the 1280-byte MTU of the mobile app, which is conservative for a VPS on a 1500-byte path. `WARP_MTU` (1420 by default) replaces it. WireGuard costs 60 bytes over IPv4/UDP (20 IP + 8 UDP + 16 header + 16 auth tag), so 1420 is the largest inner MTU safe on a 1500-byte path without depending on Path MTU Discovery — if the host's path is smaller than that, lower `WARP_MTU` to match.

Both values are pinned rather than measured. If a host's path is smaller than 1500, the symptom of too large an MTU is small transfers working while large ones stall; set `WARP_MTU` accordingly.

### Upgrading an existing deployment

An existing `/data` carries over, and the saved account is **not** re-registered:

- `wgcf-account.toml` is reused as-is; a new device is registered only when it is missing, since Cloudflare rate-limits registration.
- An existing `warp.conf` is reused — its private key and assigned addresses are kept — but its `Endpoint` and `MTU` lines are rewritten on every start. That is deliberate: wgcf's own values are pinned in a profile generated once, so a profile created by an older image would otherwise keep the IPv4 endpoint and 1280-byte MTU forever.
- Those lines are replaced rather than appended if present, so a profile edited on every boot does not accumulate duplicates.

## Inbounds

Snell is served by sing-box's own `snell` inbound — there is no separate `snell-server` process or binary, so it egresses through sing-box like every other inbound (and therefore follows `WARP`).

The inbound is configured with `"version": 5`. sing-box accepts only `5` here, and in TCP mode that is the same wire protocol as Snell v4, so it serves v4/v5 clients; v3 and earlier are rejected outright. That version is also the interop-safe choice: sing-box's own Snell *outbound* speaks `4` or `6` but not `5`, so `6` is what would strand clients on the v4/v5 wire protocol.

This requires sing-box **1.14.0 or newer** — the `snell` inbound did not exist before then. The release workflow resolves sing-box's latest release automatically, and the image build fails loudly if that release lacks the Snell inbound rather than shipping a config sing-box would reject at startup.