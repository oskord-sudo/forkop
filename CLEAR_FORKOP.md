# clear-forkop 2.0.19

- subscription_slot_count default **10**
- subscription_slot_refresh_interval default **15m** (cron → slots_refresh_if_due → reload)
- LuCI: conflict hints on textarea **title** (hover on field, not overlay)
- slots.uc library only (no CLI ARGV trap)
- DNS economy → https-dns-proxy
# clear-forkop 2.0.19

- Default /etc/config/forkop: economy + https-dns-proxy + slots(10)/15m + dont_touch_dhcp
- No user sections in default
