#!/usr/bin/env ucode
/**
 * Discover all https-dns-proxy instances (any count / any ports).
 */

let fs = require("fs");
let uci = require("core.uci");

function as_string(value) {
    return value == null ? "" : "" + value;
}

function truthy(value) {
    value = lc(as_string(value));
    return value == "1" || value == "true" || value == "yes" || value == "on";
}

function package_installed() {
    return system("opkg list-installed 2>/dev/null | grep -q '^https-dns-proxy '") == 0 ||
        system("apk info -e https-dns-proxy >/dev/null 2>&1") == 0 ||
        system("[ -x /etc/init.d/https-dns-proxy ]") == 0;
}

function service_running() {
    return system("[ -x /etc/init.d/https-dns-proxy ] && /etc/init.d/https-dns-proxy running >/dev/null 2>&1") == 0 ||
        system("pgrep -f https-dns-proxy >/dev/null 2>&1") == 0;
}

/**
 * Enumerate every https-dns-proxy UCI section that looks like an instance.
 * Supports any number of instances and any listen_port values.
 */
function collect_instances() {
    let result = [];
    if (!uci.available())
        return result;

    let cursor = null;
    try {
        cursor = uci.cursor();
    } catch (e) {
        cursor = null;
    }
    if (cursor == null)
        return result;

    cursor.load("https-dns-proxy");
    let all = cursor.get_all("https-dns-proxy");
    if (all == null)
        return result;

    for (let sec in all) {
        let s = all[sec];
        if (s == null)
            continue;
        let typ = as_string(s[".type"]);
        // OpenWrt package uses type https-dns-proxy or anonymous sections
        if (typ != "" && typ != "https-dns-proxy" && typ != "main")
            continue;
        if (truthy(s.disabled))
            continue;

        let port = as_string(s.listen_port);
        let addr = as_string(s.listen_addr != null ? s.listen_addr : s.listen_address);
        let resolver = as_string(s.resolver_url != null ? s.resolver_url : s.url);
        // skip pure metadata sections without port/resolver
        if (port == "" && resolver == "" && addr == "")
            continue;
        if (port == "")
            port = "5053";
        if (addr == "" || addr == "0.0.0.0" || addr == "::")
            addr = "127.0.0.1";

        push(result, {
            section: as_string(sec),
            listen_addr: addr,
            listen_port: port,
            bootstrap: as_string(s.bootstrap_dns != null ? s.bootstrap_dns : s.bootstrap),
            resolver_url: resolver,
            dnsmasq_server: addr + "#" + port
        });
    }
    return result;
}

function dnsmasq_upstream_servers() {
    let instances = collect_instances();
    let servers = [];
    let seen = {};
    for (let inst in instances) {
        let entry = as_string(inst.dnsmasq_server);
        if (entry != "" && !seen[entry]) {
            seen[entry] = true;
            push(servers, entry);
        }
    }
    return servers;
}

function status_summary() {
    let instances = collect_instances();
    return {
        installed: package_installed(),
        running: service_running(),
        instance_count: length(instances),
        instances: instances,
        upstream_servers: dnsmasq_upstream_servers()
    };
}

return {
    package_installed,
    service_running,
    collect_instances,
    dnsmasq_upstream_servers,
    status_summary
};
