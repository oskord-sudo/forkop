# clear-forkop (economy / transport-only)

## Architecture

| Section action | Path |
|----------------|------|
| **Proxy** (`connection`) | nft → TPROXY → sing-box → proxy outbound |
| **VPN** (`vpn`) | nft-set (real IP) → fwmark → policy routing → interface (AWG/WG) + MASQUERADE |
| Zapret / Zapret2 | nft → NFQUEUE (no sing-box) |
| ByeDPI | mark + local TPROXY → sing-box → ciadpi SOCKS |

- No FakeIP
- DNS: OpenWrt dnsmasq + https-dns-proxy
- Domain lists → dnsmasq `nftset=` → `eco_<section>_v4/v6`
- Proxy mark: `0x04000000` (TPROXY)
- VPN mark base: `0x20000000` (must NOT overlap `0x04xxxxxx`)

## Marks

- Never use `0x06xxxxxx` for VPN — overlaps proxy mask `0x04000000`
- VPN uses `0x20000001`, `0x20000002`, …

## UI

- Action **Proxy** = subscriptions / VLESS / SS / …
- Action **VPN** = network interface only (AWG etc.)

## Diagnostics

- Outbounds check does not apply to VPN sections (expected “no response”)
