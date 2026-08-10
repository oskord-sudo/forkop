# clear-forkop 2.0.12

## VPN + community (youtube)

Without FakeIP, CDN IP sets alone are incomplete. For VPN sections with
community_lists/domains:

- LAN TCP 80/443 (+ UDP 443) → TPROXY mark
- sing-box sniffs SNI + remote rule_set (youtube.srs)
- outbound: direct bind_interface (AWG)

Static IP/CIDR lists still use nft sets.
Proxy sections stay transport-only.
