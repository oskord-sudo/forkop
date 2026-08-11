# clear-forkop 2.0.18

## 2.0.18 — LuCI cross-section conflict hints
- Domains / IP / CIDR fields: red wavy underline if the same value is already present in another section
- Hover shows: «Already used in: SectionLabel/action (disabled)»
- Lines starting with `#` or `//` are ignored (not treated as conflicts)
- Does **not** block Save — only visual + message
- Russian strings in luci-i18n-forkop-ru

## 2.0.17 — DNS + subscription slots
- Economy DNS forced to https-dns-proxy
- Subscription slots (default): few live nodes in sing-box, not full dump
- UCI: `subscription_mode` (`slots`|`full`), `subscription_slot_count`

## GitHub paths to overwrite
```
forkop/files/usr/lib/singbox/generator.uc
forkop/files/usr/lib/singbox/dns.uc
forkop/files/usr/lib/subscription/slots.uc
forkop/files/usr/lib/config/migration.uc
luci-app-forkop/htdocs/luci-static/resources/view/forkop/section.js
luci-app-forkop/po/ru/forkop.po
```
