#!/usr/bin/env ucode
/**
 * DNS apply for Forkop.
 *
 * precise: dnsmasq → sing-box FakeIP inbound (legacy)
 * economy: dnsmasq → https-dns-proxy (DoH/DoT); domain lists via nftset=
 */

let fs = require("fs");
let uci = require("core.uci");

const CONFIG_NAME = getenv("FORKOP_CONFIG_NAME") || "forkop";
const SB_DNS_INBOUND_ADDRESS = getenv("SB_DNS_INBOUND_ADDRESS") || "127.0.0.42";
const DNSMASQ_INIT = getenv("DNSMASQ_INIT") || "/etc/init.d/dnsmasq";
const HTTPS_DNS_PROXY_INIT = getenv("HTTPS_DNS_PROXY_INIT") || "/etc/init.d/https-dns-proxy";
const DNSMASQ_CONF_DIR = getenv("FORKOP_DNSMASQ_CONF_DIR") || "/tmp/dnsmasq.d";
const ECONOMY_DNSMASQ_CONF = DNSMASQ_CONF_DIR + "/forkop-economy-dns.conf";
const NFTSET_CONF = DNSMASQ_CONF_DIR + "/forkop-economy-nftset.conf";

function as_string(value) {
    return value == null ? "" : "" + value;
}

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function run(command) {
    return system(command) == 0;
}

function uci_available() {
    return uci.available();
}

function uci_get(path) {
    return uci.get(path);
}

function uci_exists(path) {
    return uci.exists(path);
}

function uci_delete(path) {
    uci.delete(path);
}

function uci_set(path, value) {
    uci.set(path, value);
}

function uci_add_list(path, value) {
    uci.add_list(path, value);
}

function uci_del_list(path, value) {
    return uci.del_list(path, value);
}

function uci_commit(package_name) {
    uci.commit(package_name);
}

function words(value) {
    value = trim(as_string(value));
    return value == "" ? [] : split(value, /[ \t\r\n]+/);
}

function truthy(value) {
    value = lc(as_string(value));
    return value == "1" || value == "true" || value == "yes" || value == "on";
}

function list_has(values, needle) {
    for (let value in words(values))
        if (value == needle)
            return true;
    return false;
}

function log(message, level) {
    level = as_string(level || "info");
    run("logger -t " + shell_quote("forkop") + " " + shell_quote("[" + level + "] " + as_string(message)));
}

function restart_dnsmasq() {
    return run("[ -x " + shell_quote(DNSMASQ_INIT) + " ] && " + shell_quote(DNSMASQ_INIT) + " restart");
}

function ensure_https_dns_proxy_started() {
    if (!run("[ -x " + shell_quote(HTTPS_DNS_PROXY_INIT) + " ]"))
        return false;
    run(shell_quote(HTTPS_DNS_PROXY_INIT) + " enabled >/dev/null 2>&1 || " +
        shell_quote(HTTPS_DNS_PROXY_INIT) + " enable >/dev/null 2>&1");
    if (run(shell_quote(HTTPS_DNS_PROXY_INIT) + " running >/dev/null 2>&1"))
        return true;
    return run(shell_quote(HTTPS_DNS_PROXY_INIT) + " start >/dev/null 2>&1") ||
        run(shell_quote(HTTPS_DNS_PROXY_INIT) + " restart >/dev/null 2>&1");
}

function routing_mode_is_economy() {
    // FakeIP fully removed — always https-dns-proxy / dnsmasq path
    return true;
}

function economy_dns_backend() {
    let v = lc(trim(as_string(uci_get(CONFIG_NAME + ".settings.economy_dns_backend"))));
    if (v == "dnsmasq" || v == "plain")
        return "dnsmasq";
    if (v == "hybrid")
        return "hybrid";
    // default: full https-dns-proxy integration
    return "https-dns-proxy";
}

function dnsmasq_legacy_instance_exists() {
    return uci_exists("dhcp.forkop");
}

function dnsmasq_default_servers() {
    return uci_get("dhcp.@dnsmasq[0].server");
}

function dnsmasq_default_has_forkop_dns() {
    return list_has(dnsmasq_default_servers(), SB_DNS_INBOUND_ADDRESS);
}

function dnsmasq_has_forkop_dns() {
    return dnsmasq_default_has_forkop_dns() || dnsmasq_legacy_instance_exists();
}

function dnsmasq_has_forkop_managed_state() {
    return uci_get("dhcp.@dnsmasq[0].forkop_server") != "" ||
        uci_get("dhcp.@dnsmasq[0].forkop_noresolv") != "" ||
        uci_get("dhcp.@dnsmasq[0].forkop_cachesize") != "" ||
        uci_get("dhcp.@dnsmasq[0].forkop_notinterface") != "" ||
        uci_get("dhcp.@dnsmasq[0].forkop_economy") != "" ||
        dnsmasq_legacy_instance_exists();
}

function dnsmasq_management_disabled() {
    // Forkop never changes OpenWrt DHCP / dnsmasq UCI
    return true;
}

function dnsmasq_default_config_is_complete() {
    return dnsmasq_default_has_forkop_dns() &&
        uci_get("dhcp.@dnsmasq[0].noresolv") == "1" &&
        uci_get("dhcp.@dnsmasq[0].cachesize") == "0" &&
        !dnsmasq_legacy_instance_exists();
}

function backup_dnsmasq_config_option(key, backup_key) {
    if (uci_get("dhcp.@dnsmasq[0]." + backup_key) != "")
        return;
    let value = uci_get("dhcp.@dnsmasq[0]." + key);
    if (value != null && as_string(value) != "")
        uci_set("dhcp.@dnsmasq[0]." + backup_key, value);
}

function backup_dnsmasq_server_list() {
    if (uci_get("dhcp.@dnsmasq[0].forkop_server") != "")
        return;
    for (let server in words(dnsmasq_default_servers())) {
        if (server != SB_DNS_INBOUND_ADDRESS)
            uci_add_list("dhcp.@dnsmasq[0].forkop_server", server);
    }
}

function restore_dnsmasq_config_option(key, backup_key, default_value) {
    let value = uci_get("dhcp.@dnsmasq[0]." + backup_key);
    if (value != null && as_string(value) != "") {
        uci_set("dhcp.@dnsmasq[0]." + key, value);
        uci_delete("dhcp.@dnsmasq[0]." + backup_key);
    } else if (default_value != null) {
        uci_set("dhcp.@dnsmasq[0]." + key, default_value);
    } else {
        uci_delete("dhcp.@dnsmasq[0]." + key);
    }
}

function dnsmasq_cleanup_legacy_instance() {
    if (!dnsmasq_legacy_instance_exists())
        return;
    uci_delete("dhcp.forkop");
    log("Removed legacy dhcp.forkop dnsmasq instance", "info");
}

function clear_dnsmasq_server_list() {
    // delete all server entries
    run("uci -q delete dhcp.@dnsmasq[0].server");
}

function dnsmasq_configure_precise_instance() {
    // FakeIP/precise DNS path disabled — never touch dnsmasq UCI
    return true;
}

function load_https_dns_proxy() {
    try {
        return require("dns.https_dns_proxy");
    } catch (e) {
        return null;
    }
}

function load_nftset() {
    try {
        return require("dns.nftset");
    } catch (e) {
        return null;
    }
}

function ensure_dir(path) {
    return run("mkdir -p " + shell_quote(path));
}

function write_economy_dnsmasq_conf(upstream_servers) {
    // Do not drop server= files into conf.d — that would override OpenWrt DNS
    return true;
}

function remove_economy_conf_files() {
    run("rm -f " + shell_quote(ECONOMY_DNSMASQ_CONF) + " " + shell_quote(NFTSET_CONF));
}

/**
 * Economy: point dnsmasq at https-dns-proxy, generate nftset conf, ensure service up.
 */
function dnsmasq_configure_economy() {
    // Do not modify /etc/config/dhcp or dnsmasq UCI.
    // Optional: write domain→nftset conf into existing conf.d if present (no UCI commit).
    log("DNS/DHCP left to OpenWrt / https-dns-proxy; Forkop only updates optional nftset conf", "info");

    let nftset = load_nftset();
    if (nftset != null) {
        let gen = nftset.generate_nftset_conf();
        if (gen != null && gen.ok)
            log("Economy nftset conf written: " + gen.path + " lines=" + gen.lines, "info");
        else
            log("Economy nftset conf generation skipped or failed", "info");
    }
    return true;
}

function dnsmasq_configure_default_instance() {
    if (routing_mode_is_economy())
        return dnsmasq_configure_economy();
    remove_economy_conf_files();
    dnsmasq_configure_precise_instance();
    return true;
}

function dnsmasq_restore_default_instance() {
    remove_economy_conf_files();

    // restore servers from backup
    clear_dnsmasq_server_list();
    let backed = uci_get("dhcp.@dnsmasq[0].forkop_server");
    if (backed != null && as_string(backed) != "") {
        for (let s in words(backed))
            uci_add_list("dhcp.@dnsmasq[0].server", s);
        uci_delete("dhcp.@dnsmasq[0].forkop_server");
    }

    restore_dnsmasq_config_option("noresolv", "forkop_noresolv", null);
    restore_dnsmasq_config_option("cachesize", "forkop_cachesize", null);
    uci_delete("dhcp.@dnsmasq[0].forkop_economy");
    dnsmasq_cleanup_legacy_instance();
    uci_commit("dhcp");
    return true;
}

function dnsmasq_configure(force) {
    // Never rewrite DHCP. Only optional nftset file for routing classification.
    return dnsmasq_configure_economy();
}

function dnsmasq_restore(force, quiet) {
    if (!uci_available())
        return false;
    if (!dnsmasq_has_forkop_managed_state() && !force)
        return true;
    dnsmasq_restore_default_instance();
    if (!quiet)
        restart_dnsmasq();
    return true;
}

function failsafe_restore() {
    if (dnsmasq_management_disabled()) {
        if (!dnsmasq_has_forkop_managed_state()) {
            log("DNS rollback skipped: dont_touch_dhcp is enabled and no Forkop dnsmasq changes were found", "info");
            return true;
        }
        log("Rolling back previous Forkop dnsmasq changes because dont_touch_dhcp is enabled", "warn");
    }
    return dnsmasq_restore(true, false);
}

function economy_status() {
    let hdp = load_https_dns_proxy();
    let st = hdp != null ? hdp.status_summary() : { installed: false, running: false, instances: [], upstream_servers: [] };
    return {
        mode: routing_mode_is_economy() ? "economy" : "precise",
        backend: economy_dns_backend(),
        https_dns_proxy: st,
        nftset_conf: NFTSET_CONF,
        economy_conf: ECONOMY_DNSMASQ_CONF
    };
}

// CLI
let mode = ARGV[0] || "";

if (mode == "configure")
    exit(dnsmasq_configure(ARGV[1]) ? 0 : 1);
else if (mode == "restore" || mode == "dnsmasq_restore")
    exit(dnsmasq_restore(ARGV[1], false) ? 0 : 1);
else if (mode == "failsafe-restore")
    exit(failsafe_restore() ? 0 : 1);
else if (mode == "economy-status") {
    let st = economy_status();
    print(sprintf("%J\n", st));
    exit(0);
}
else if (mode == "economy-nftset") {
    let nftset = load_nftset();
    if (nftset == null) {
        warn("nftset module missing\n");
        exit(1);
    }
    let gen = nftset.generate_nftset_conf();
    print(sprintf("%J\n", gen));
    exit(gen != null && gen.ok ? 0 : 1);
}
else if (mode == "https-dns-proxy-status") {
    let hdp = load_https_dns_proxy();
    if (hdp == null) {
        warn("module missing\n");
        exit(1);
    }
    print(sprintf("%J\n", hdp.status_summary()));
    exit(0);
}
else {
    warn("Usage: dns/apply.uc <configure|restore|failsafe-restore|economy-status|economy-nftset|https-dns-proxy-status>\n");
    exit(1);
}
