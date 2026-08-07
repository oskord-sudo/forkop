# clear-forkop

**Build:** 2026-08-07T20:36:13Z  
**Codename:** clear-forkop

Full snapshot with all economy / transport-policy changes.

## Contents

- Backend modules (`files/usr/lib/...`): generator, nft, dns/nftset, https-dns-proxy, direct_path
- Default UCI: `files/etc/config/forkop`
- Installer: `install.sh` (opkg/apk, https-dns-proxy deps)
- LuCI: `luci-app-forkop/` (settings transport flags, no separate dashboard filter)

## Features

1. No FakeIP; DNS via dnsmasq + https-dns-proxy
2. Domains → dnsmasq nftset= → eco_* (timeout) → nft mark
3. VPN/AWG: policy routing; Zapret: NFQUEUE; ByeDPI: thin sing-box SOCKS
4. Proxy: TPROXY → short inbound→outbound (no large lists in SB)
5. Optional: torrents direct (+ custom ports), VoIP proxy, LAN client policy
6. Dashboard servers = URLTest filter only

## Apply on router (patch existing install)

```sh
tar -xzf clear-forkop-full.tar.gz -C /tmp/cf
# Backend (path may be /usr/lib/forkop)
cp -a /tmp/cf/files/usr/lib/forkop/* /usr/lib/forkop/ 2>/dev/null || \
  cp -a /tmp/cf/files/usr/lib/* /usr/lib/forkop/
cp /tmp/cf/files/etc/config/forkop /etc/config/forkop.example-clear
# LuCI views
cp /tmp/cf/luci-app-forkop/htdocs/luci-static/resources/view/forkop/*.js \
  /www/luci-static/resources/view/forkop/
/etc/init.d/forkop restart
```

Or run `install.sh` for a full install flow where supported.
