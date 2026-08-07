#!/usr/bin/env ucode
/**
 * Discover and describe https-dns-proxy instances for economy DNS backend.
 */

let uci = require("core.uci");

function as_string(value) {
    return value == null ? "" : "" + value;
}

function truthy(value) {
    value = lc(as_string(value));
    return value == "1" || value == "true" || value == "yes" || value == "on";
}

function package_installed() {
    // opkg/apk presence markers
    return system("opkg list-installed 2>/dev/null | grep -q '^https-dns-proxy '") == 0 ||
        system("apk info -e https-dns-proxy >/dev/null 2>&1") == 0 ||
        uci.exists("https-dns-proxy") ||
        system("[ -x /etc/init.d/https-dns-proxy ]") == 0;
}

function service_running() {
    return system("[ -x /etc/init.d/https-dns-proxy ] && /etc/init.d/https-dns-proxy running >/dev/null 2>&1") == 0 ||
        system("pgrep -f https-dns-proxy >/dev/null 2>&1") == 0;
}

/**
 * Collect listen endpoints from UCI https-dns-proxy.
 * Typical OpenWrt schema:
 *   config https-dns-proxy
 *     option listen_addr '127.0.0.1'
 *     option listen_port '5053'
 *     option bootstrap_dns '1.1.1.1,1.0.0.1'
 *     option resolver_url 'https://...'
 */
function collect_instances() {
    let result = [];
    if (!uci.available())
        return result;

    // https-dns-proxy may use named sections or anonymous
    // Try foreach via shell-backed uci show parse is fragile; use known paths
    let raw = "";
    let pipe = popen("uci -q show https-dns-proxy 2>/dev/null", "r");
    if (pipe != null) {
        raw = pipe.read("all");
        pipe.close();
    }
    if (raw == null || raw == "")
        return result;

    // Map section -> fields
    let sections = {};
    for (let line in split(raw, "\n")) {
        line = trim(line);
        if (line == "")
            continue;
        // https-dns-proxy.cfg123456.listen_port='5053'
        let m = match(line, /^https-dns-proxy\.([^.]+)\.([^=]+)='(.*)'$/);
        if (m == null)
            m = match(line, /^https-dns-proxy\.([^.]+)\.([^=]+)=(.*)$/);
        if (m == null)
            continue;
        let sec = m[1];
        let key = m[2];
        let val = m[3];
        if (sections[sec] == null)
            sections[sec] = {};
        sections[sec][key] = val;
    }

    for (let sec in keys(sections)) {
        let s = sections[sec];
        // skip non-instance metadata
        if (s.listen_port == null && s.listen_addr == null && s.resolver_url == null && s.url == null)
            continue;
        let addr = as_string(s.listen_addr != null ? s.listen_addr : s.listen_address);
        if (addr == "" || addr == "0.0.0.0")
            addr = "127.0.0.1";
        let port = as_string(s.listen_port != null ? s.listen_port : "5053");
        let enabled = s.disabled == null || !truthy(s.disabled);
        if (!enabled)
            continue;
        push(result, {
            section: sec,
            listen_addr: addr,
            listen_port: port,
            bootstrap: as_string(s.bootstrap_dns != null ? s.bootstrap_dns : s.bootstrap),
            resolver_url: as_string(s.resolver_url != null ? s.resolver_url : s.url),
            dnsmasq_server: addr + "#" + port
        });
    }
    return result;
}

/**
 * Build dnsmasq server= list entries pointing at https-dns-proxy.
 * Fallback: 127.0.0.1#5053 (common default).
 */
function dnsmasq_upstream_servers() {
    let instances = collect_instances();
    let servers = [];
    let seen = {};
    for (let inst in instances) {
        let entry = inst.dnsmasq_server;
        if (entry != "" && !seen[entry]) {
            seen[entry] = true;
            push(servers, entry);
        }
    }
    if (length(servers) == 0)
        push(servers, "127.0.0.1#5053");
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
