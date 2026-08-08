#!/usr/bin/env ucode
/**
 * Direct (non-sing-box) datapaths:
 *  - Zapret/Zapret2: nft mark + NFQUEUE on prerouting
 *  - VPN/AWG interfaces: fwmark + policy routing to iface
 *  - ByeDPI: mark + TPROXY to local ciadpi port (SOCKS/transparent listen)
 */

let fs = require("fs");
let common = require("core.common");
let connections = require("config.connections");
let uci_core = require("core.uci");

const CONFIG_NAME = getenv("FORKOP_CONFIG_NAME") || "forkop";
const RT_TABLES = "/etc/iproute2/rt_tables";
const VPN_TABLE_BASE = 120;
const VPN_MARK_BASE = getenv("NFT_IFACE_MARK_BASE") || "0x06000000";
const ZAPRET_MARK_BASE = getenv("ZAPRET_ROUTE_MARK_BASE") || "0x01000000";
const ZAPRET_QUEUE_BASE = getenv("ZAPRET_QUEUE_BASE") || "4000";
const ZAPRET2_MARK_BASE = getenv("ZAPRET2_ROUTE_MARK_BASE") || "0x02000000";
const ZAPRET2_QUEUE_BASE = getenv("ZAPRET2_QUEUE_BASE") || "4500";
const BYEDPI_PORT_BASE = getenv("BYEDPI_PORT_BASE") || "1080";
const BYEDPI_MARK_BASE = getenv("BYEDPI_ROUTE_MARK_BASE") || "0x03000000";

function as_string(value) {
    return value == null ? "" : "" + value;
}

function option(section, key, fallback) {
    return common.option(section, key, fallback);
}

function bool_option(section, key, fallback) {
    return common.bool_option(section, key, fallback);
}

function list_option(section, key) {
    return common.list_option(section, key);
}

function run_args(args) {
    let parts = [];
    for (let a in args)
        push(parts, "'" + replace(as_string(a), /'/g, "'\\''") + "'");
    return system(join(" ", parts)) == 0;
}

function run_args_quiet(args) {
    let parts = [];
    for (let a in args)
        push(parts, "'" + replace(as_string(a), /'/g, "'\\''") + "'");
    return system(join(" ", parts) + " >/dev/null 2>&1") == 0;
}

function log_msg(message) {
    system("logger -t forkop " + "'" + replace("[direct_path] " + as_string(message), /'/g, "'\\''") + "'");
}

function parse_hex_mark(value) {
    value = trim(as_string(value));
    if (index(value, "0x") == 0 || index(value, "0X") == 0)
        value = substr(value, 2);
    let result = 0;
    for (let i = 0; i < length(value); i++) {
        let ch = substr(value, i, 1);
        let digit = index("0123456789abcdef", lc(ch));
        if (digit < 0)
            digit = index("0123456789ABCDEF", ch);
        if (digit < 0)
            return null;
        result = result * 16 + digit;
    }
    return result;
}

function mark_hex(base, index) {
    let b = parse_hex_mark(base);
    if (b == null)
        b = 0;
    return sprintf("0x%08x", b + int(index));
}

function nft_add_rule(table, chain, args) {
    let cmd = [ "nft", "add", "rule", "inet", table, chain ];
    for (let a in args)
        push(cmd, a);
    return run_args(cmd);
}

function section_set_names(section_name) {
    let safe = replace(as_string(section_name), /[^A-Za-z0-9_]/g, "_");
    if (length(safe) > 40)
        safe = substr(safe, 0, 40);
    return {
        v4: "forkop_rule_" + safe + "_subnets",
        v6: "forkop_rule_" + safe + "_subnets6",
        eco4: "eco_" + safe + "_v4",
        eco6: "eco_" + safe + "_v6"
    };
}

function ensure_ipv4_set(table, name) {
    return run_args_quiet([ "nft", "add", "set", "inet", table, name, "{ type ipv4_addr; flags interval; auto-merge; }" ]) ||
        run_args_quiet([ "nft", "list", "set", "inet", table, name ]);
}

function ensure_ipv6_set(table, name) {
    return run_args_quiet([ "nft", "add", "set", "inet", table, name, "{ type ipv6_addr; flags interval; auto-merge; }" ]) ||
        run_args_quiet([ "nft", "list", "set", "inet", table, name ]);
}

function ensure_section_sets(table, section) {
    let names = section_set_names(section[".name"]);
    return ensure_ipv4_set(table, names.v4) && ensure_ipv6_set(table, names.v6) &&
        ensure_ipv4_set(table, names.eco4) && ensure_ipv6_set(table, names.eco6);
}

function uci_enabled_sections() {
    let result = [];
    if (!uci_core.available())
        return result;
    // shell list
    let pipe = fs.popen("uci -q show " + CONFIG_NAME + " 2>/dev/null | grep '=section$' | cut -d. -f2 | cut -d= -f1", "r");
    let raw = pipe != null ? pipe.read("all") : "";
    if (pipe != null)
        pipe.close();
    for (let name in split(as_string(raw), "\n")) {
        name = trim(name);
        if (name == "")
            continue;
        let enabled = uci_core.get(CONFIG_NAME + "." + name + ".enabled");
        if (enabled == "0" || enabled == "false")
            continue;
        let action = as_string(uci_core.get(CONFIG_NAME + "." + name + ".action"));
        push(result, { ".name": name, action: action, enabled: "1" });
    }
    return result;
}

function section_action_of(section) {
    if (section.action != null)
        return as_string(section.action);
    return as_string(option(section, "action", ""));
}

/**
 * Zapret/Zapret2: match daddr in section sets → mark → NFQUEUE on prerouting.
 * No TPROXY / no sing-box.
 */
function apply_provider_prerouting_queues(table, interface_set, localv4, localv6, action, mark_base, queue_base) {
    let index = 0;
    let sections = uci_enabled_sections();
    for (let section in sections) {
        if (section_action_of(section) != action)
            continue;
        index++;
        if (!ensure_section_sets(table, section))
            return false;

        let names = section_set_names(section[".name"]);
        let mark = mark_hex(mark_base, index);
        let q = int(queue_base) + index - 1;

        // Mark by subnet sets (explicit + eco domain-filled)
        for (let set4 in [ names.v4, names.eco4 ]) {
            if (!nft_add_rule(table, "priority_rules", [
                "iifname", "@" + interface_set,
                "ip", "daddr", "@" + set4,
                "ip", "daddr", "!=", "@" + localv4,
                "meta", "mark", "set", mark, "counter"
            ]))
                return false;
        }
        for (let set6 in [ names.v6, names.eco6 ]) {
            if (!nft_add_rule(table, "priority_rules", [
                "iifname", "@" + interface_set,
                "ip6", "daddr", "@" + set6,
                "ip6", "daddr", "!=", "@" + localv6,
                "meta", "mark", "set", mark, "counter"
            ]))
                return false;
        }

        // Queue on prerouting by mark (LAN → nfqws directly)
        if (!nft_add_rule(table, "priority_rules", [
            "meta", "mark", mark, "meta", "l4proto", "tcp", "counter", "queue", "num", as_string(q), "bypass"
        ]))
            return false;
        if (!nft_add_rule(table, "priority_rules", [
            "meta", "mark", mark, "meta", "l4proto", "udp", "counter", "queue", "num", as_string(q), "bypass"
        ]))
            return false;

        log_msg(action + " section " + section[".name"] + " mark=" + mark + " queue=" + q);
    }
    return true;
}

function ensure_rt_table(table_id, table_name) {
    table_name = as_string(table_name);
    table_id = as_string(table_id);
    let data = fs.readfile(RT_TABLES);
    if (data != null && index(data, table_name) >= 0)
        return true;
    let line = table_id + " " + table_name + "\n";
    let existing = data != null ? data : "";
    return fs.writefile(RT_TABLES, existing + line) != null || system("echo " + table_id + " " + table_name + " >> " + RT_TABLES) == 0;
}

function iface_up(name) {
    return run_args_quiet([ "ip", "link", "show", "dev", name ]);
}

/**
 * VPN/AWG: mark matching traffic → ip rule → table with default via iface.
 */
function apply_vpn_interface_routing(table, interface_set, localv4, localv6) {
    let sections = uci_enabled_sections();
    let idx = 0;

    for (let section in sections) {
        let action = section_action_of(section);
        // vpn action OR connection with only interfaces (no proxy transport)
        let ifaces = [];
        // load interfaces from UCI
        let name = section[".name"];
        let pipe = fs.popen("uci -q get " + CONFIG_NAME + "." + name + ".interface 2>/dev/null; uci -q get " + CONFIG_NAME + "." + name + ".interfaces 2>/dev/null", "r");
        let raw = pipe != null ? pipe.read("all") : "";
        if (pipe != null)
            pipe.close();
        for (let iface in split(as_string(raw), /[ \t\n]/)) {
            iface = trim(iface);
            if (iface != "")
                push(ifaces, iface);
        }
        // section_interface children
        pipe = fs.popen("uci -q show " + CONFIG_NAME + " 2>/dev/null | grep 'section_interface.*name=' | head -50", "r");
        // simpler: list_option style via uci show
        pipe = fs.popen("uci -q each " + CONFIG_NAME + " 2>/dev/null", "r");
        if (pipe != null)
            pipe.close();

        if (action != "vpn" && length(ifaces) == 0)
            continue;
        if (action != "vpn" && action != "connection" && action != "proxy" && action != "outbound")
            continue;

        // For connection with proxy transport, interfaces are ignored here (sing-box handles proxy only)
        if (action != "vpn") {
            let has_proxy = false;
            for (let key in ["selector_proxy_links", "outbound_jsons", "outbound_json"]) {
                let v = as_string(uci_core.get(CONFIG_NAME + "." + name + "." + key));
                if (v != "")
                    has_proxy = true;
            }
            // subscription urls hard to detect simply - if has_proxy skip iface path for mixed
            if (has_proxy)
                continue;
            if (length(ifaces) == 0)
                continue;
        }

        if (length(ifaces) == 0)
            continue;

        idx++;
        let iface = ifaces[0];
        let table_id = VPN_TABLE_BASE + idx;
        let table_name = "forkop_if_" + replace(name, /[^A-Za-z0-9_]/g, "_");
        if (length(table_name) > 28)
            table_name = substr(table_name, 0, 28);
        let mark = mark_hex(VPN_MARK_BASE, idx);

        if (!ensure_section_sets(table, section))
            return false;
        if (!ensure_rt_table(table_id, table_name)) {
            log_msg("failed rt_table " + table_name);
            return false;
        }

        let names = section_set_names(name);
        for (let set4 in [ names.v4, names.eco4 ]) {
            nft_add_rule(table, "priority_rules", [
                "iifname", "@" + interface_set,
                "ip", "daddr", "@" + set4,
                "ip", "daddr", "!=", "@" + localv4,
                "meta", "mark", "set", mark, "counter"
            ]);
        }
        for (let set6 in [ names.v6, names.eco6 ]) {
            nft_add_rule(table, "priority_rules", [
                "iifname", "@" + interface_set,
                "ip6", "daddr", "@" + set6,
                "ip6", "daddr", "!=", "@" + localv6,
                "meta", "mark", "set", mark, "counter"
            ]);
        }

        // policy routing
        run_args_quiet([ "ip", "-4", "rule", "del", "fwmark", mark + "/" + mark, "table", table_name ]);
        run_args_quiet([ "ip", "-6", "rule", "del", "fwmark", mark + "/" + mark, "table", table_name ]);
        run_args([ "ip", "-4", "rule", "add", "fwmark", mark + "/" + mark, "table", table_name, "priority", as_string(120 + idx) ]);
        run_args([ "ip", "-6", "rule", "add", "fwmark", mark + "/" + mark, "table", table_name, "priority", as_string(120 + idx) ]);

        run_args_quiet([ "ip", "route", "flush", "table", table_name ]);
        run_args_quiet([ "ip", "-6", "route", "flush", "table", table_name ]);
        if (iface_up(iface)) {
            run_args([ "ip", "route", "add", "default", "dev", iface, "table", table_name ]);
            run_args_quiet([ "ip", "-6", "route", "add", "default", "dev", iface, "table", table_name ]);
            log_msg("vpn " + name + " → " + iface + " mark=" + mark + " table=" + table_name);
        } else {
            log_msg("vpn iface " + iface + " not up yet for section " + name);
        }
    }
    return true;
}

/**
 * ByeDPI: mark traffic matching section sets, TPROXY to local ciadpi port.
 * ciadpi must listen on that port (SOCKS or transparent).
 * Traffic does not enter the main sing-box TPROXY mark path.
 */
function apply_byedpi_direct(table, interface_set, localv4, localv6, tproxy_port_unused) {
    let sections = uci_enabled_sections();
    let index = 0;
    for (let section in sections) {
        if (section_action_of(section) != "byedpi")
            continue;
        index++;
        if (!ensure_section_sets(table, section))
            return false;

        // TPROXY into sing-box dedicated inbound per section (1603, 1604, …)
        let port = int(getenv("BYEDPI_TPROXY_PORT") || "1603") + index - 1;
        let mark = mark_hex(BYEDPI_MARK_BASE, index);
        let names = section_set_names(section[".name"]);

        for (let set4 in [ names.v4, names.eco4 ]) {
            nft_add_rule(table, "priority_rules", [
                "iifname", "@" + interface_set,
                "ip", "daddr", "@" + set4,
                "ip", "daddr", "!=", "@" + localv4,
                "meta", "mark", "set", mark, "counter"
            ]);
        }
        for (let set6 in [ names.v6, names.eco6 ]) {
            nft_add_rule(table, "priority_rules", [
                "iifname", "@" + interface_set,
                "ip6", "daddr", "@" + set6,
                "ip6", "daddr", "!=", "@" + localv6,
                "meta", "mark", "set", mark, "counter"
            ]);
        }

        // TPROXY to sing-box byedpi inbound (127.0.0.1:1603) — SOCKS client is sing-box
        if (!nft_add_rule(table, "proxy", [
            "meta", "mark", mark, "meta", "l4proto", "tcp",
            "tproxy", "ip", "to", "127.0.0.1:" + as_string(port), "counter"
        ]))
            return false;
        if (!nft_add_rule(table, "proxy", [
            "meta", "mark", mark, "meta", "l4proto", "udp",
            "tproxy", "ip", "to", "127.0.0.1:" + as_string(port), "counter"
        ]))
            return false;

        // Local route for this mark so TPROXY works
        let rt_name = "forkop_bd_" + index;
        ensure_rt_table(130 + index, rt_name);
        run_args_quiet([ "ip", "-4", "rule", "del", "fwmark", mark + "/" + mark, "table", rt_name ]);
        run_args([ "ip", "-4", "rule", "add", "fwmark", mark + "/" + mark, "table", rt_name, "priority", as_string(130 + index) ]);
        run_args_quiet([ "ip", "route", "replace", "local", "0.0.0.0/0", "dev", "lo", "table", rt_name ]);

        log_msg("byedpi section " + section[".name"] + " mark=" + mark + " tproxy=127.0.0.1:" + port + " → sing-box → ciadpi SOCKS");
    }
    return true;
}

function apply_all_direct_paths(table, interface_set, localv4, localv6) {
    interface_set = as_string(interface_set || "forkop_interfaces");
    localv4 = as_string(localv4 || "localv4");
    localv6 = as_string(localv6 || "localv6");

    if (!apply_provider_prerouting_queues(table, interface_set, localv4, localv6, "zapret", ZAPRET_MARK_BASE, ZAPRET_QUEUE_BASE))
        return false;
    if (!apply_provider_prerouting_queues(table, interface_set, localv4, localv6, "zapret2", ZAPRET2_MARK_BASE, ZAPRET2_QUEUE_BASE))
        return false;
    if (!apply_vpn_interface_routing(table, interface_set, localv4, localv6))
        return false;
    if (!apply_byedpi_direct(table, interface_set, localv4, localv6, null))
        return false;
    return true;
}

return {
    apply_all_direct_paths,
    apply_provider_prerouting_queues,
    apply_vpn_interface_routing,
    apply_byedpi_direct,
    mark_hex,
    section_set_names
};
