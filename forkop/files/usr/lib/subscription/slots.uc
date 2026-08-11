#!/usr/bin/env ucode
/**
 * Slot manager for clear-forkop.
 *
 * Keeps only a few live subscription outbounds ("slots") for sing-box,
 * instead of dumping the entire subscription into config.json.
 *
 * Flow:
 *   1) Read cached subscription outbounds
 *   2) TCP probe server:port (first-alive)
 *   3) Optional rough ranking by connect time
 *   4) Write /tmp/forkop/slots/<section>.json
 *
 * Generator reads slots when settings.subscription_mode = slots (default).
 */

let fs = require("fs");
let common = require("core.common");
let uci_core = require("core.uci");

let as_string = common.as_string;
let object_or_empty = common.object_or_empty;
let array_or_empty = common.array_or_empty;
let option = common.option;
let bool_option = common.bool_option;
let list_option = common.list_option;
let read_json_file = common.read_json_file;

const SLOTS_DIR = getenv("FORKOP_SLOTS_DIR") || "/tmp/forkop/slots";
const DEFAULT_SLOT_COUNT = 3;
const PROBE_TIMEOUT_SEC = 1;
const PROBE_MAX_CANDIDATES = 15;

function trim(value) {
    return replace(replace(as_string(value), /^\s+/, ""), /\s+$/, "");
}

function lc(value) {
    return lc_str(as_string(value));
}

function lc_str(value) {
    // ucode has no built-in lower for all; use replace map for protocol types only when needed
    return as_string(value);
}

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function log_msg(message, level) {
    level = as_string(level || "info");
    system("logger -t forkop " + shell_quote("[" + level + "] slots: " + as_string(message)));
}

function slots_path(section_name) {
    return SLOTS_DIR + "/" + as_string(section_name) + ".json";
}

function ensure_slots_dir() {
    system("mkdir -p " + shell_quote(SLOTS_DIR));
}

function load_settings_section() {
    try {
        let cursor = uci_core.cursor();
        if (cursor == null)
            return {};
        cursor.load("forkop");
        let all = cursor.get_all("forkop");
        for (let name, section in object_or_empty(all)) {
            if (as_string(object_or_empty(section)[".type"] || "") == "settings" || name == "settings")
                return section;
        }
    } catch (e) {
    }
    return {};
}

function subscription_mode_from_settings(settings) {
    settings = object_or_empty(settings);
    if (length(keys(settings)) == 0)
        settings = load_settings_section();
    let mode = trim(option(settings, "subscription_mode", "slots"));
    if (getenv("FORKOP_SUBSCRIPTION_MODE") != "")
        mode = getenv("FORKOP_SUBSCRIPTION_MODE");
    if (mode == "full" || mode == "all")
        return "full";
    return "slots";
}

function slot_count_from_settings(settings) {
    settings = object_or_empty(settings);
    if (length(keys(settings)) == 0)
        settings = load_settings_section();
    let n = int(option(settings, "subscription_slot_count", DEFAULT_SLOT_COUNT));
    if (n < 1)
        n = 1;
    if (n > 10)
        n = 10;
    return n;
}

function is_leaf_proxy_outbound(outbound) {
    if (type(outbound) != "object")
        return false;
    let t = as_string(outbound.type || "");
    if (t == "" || t == "direct" || t == "block" || t == "dns" || t == "selector" || t == "urltest")
        return false;
    let server = as_string(outbound.server || "");
    return server != "";
}

function outbound_port(outbound) {
    let port = outbound.server_port;
    if (port == null || as_string(port) == "")
        port = outbound.port;
    port = int(port);
    return port > 0 && port < 65536 ? port : 0;
}

function tcp_probe_ms(host, port, timeout_sec) {
    host = trim(host);
    port = int(port);
    if (host == "" || port <= 0)
        return -1;
    timeout_sec = int(timeout_sec || PROBE_TIMEOUT_SEC);
    if (timeout_sec < 1)
        timeout_sec = 1;

    // Prefer busybox nc; fall back to /dev/tcp via shell
    let start = time();
    let cmd = "nc -z -w " + timeout_sec + " " + shell_quote(host) + " " + port + " >/dev/null 2>&1";
    let rc = system(cmd);
    if (rc != 0) {
        // /dev/tcp fallback (ash/bash)
        cmd = "out=$(echo >/dev/tcp/" + replace(host, /[^A-Za-z0-9._:-]/g, "") + "/" + port + " 2>/dev/null); echo $?";
        // simpler: use timeout + nc only; if nc missing, skip probe success
        return -1;
    }
    let elapsed = time() - start;
    // time() is seconds; use 0 as "fast" and scale
    return elapsed <= 0 ? 1 : elapsed * 1000;
}

function probe_outbound(outbound) {
    if (!is_leaf_proxy_outbound(outbound))
        return { ok: false, ms: -1 };
    let host = as_string(outbound.server || "");
    let port = outbound_port(outbound);
    if (host == "" || port <= 0)
        return { ok: false, ms: -1 };

    let start_ms = time();
    // nc -z
    let rc = system("nc -z -w " + PROBE_TIMEOUT_SEC + " " + shell_quote(host) + " " + port + " >/dev/null 2>&1");
    if (rc != 0)
        return { ok: false, ms: -1 };
    let ms = (time() - start_ms);
    if (ms < 0)
        ms = 0;
    return { ok: true, ms: ms == 0 ? 1 : ms * 1000 };
}

function read_slots(section_name) {
    let data = read_json_file(slots_path(section_name));
    if (type(data) != "object")
        return null;
    return data;
}

function write_slots(section_name, payload) {
    ensure_slots_dir();
    let path = slots_path(section_name);
    let tmp = path + ".tmp";
    if (!fs.writefile(tmp, sprintf("%J\n", payload))) {
        log_msg("failed to write " + tmp, "error");
        return false;
    }
    system("mv -f " + shell_quote(tmp) + " " + shell_quote(path));
    return true;
}

function select_slots_from_outbounds(outbounds, slot_count) {
    let candidates = [];
    for (let outbound in array_or_empty(outbounds)) {
        if (!is_leaf_proxy_outbound(outbound))
            continue;
        push(candidates, outbound);
        if (length(candidates) >= PROBE_MAX_CANDIDATES)
            break;
    }

    let alive = [];
    // First-alive pass: stop early when we have slot_count
    for (let outbound in candidates) {
        let probe = probe_outbound(outbound);
        if (!probe.ok)
            continue;
        let copy = {};
        for (let k, v in outbound)
            copy[k] = v;
        copy.__forkop_probe_ms = probe.ms;
        push(alive, copy);
        if (length(alive) >= slot_count)
            break;
    }

    // If nothing alive, fall back to first leaf candidates (no probe) so traffic can still try
    if (length(alive) == 0) {
        for (let outbound in candidates) {
            let copy = {};
            for (let k, v in outbound)
                copy[k] = v;
            push(alive, copy);
            if (length(alive) >= slot_count)
                break;
        }
        return {
            mode: "fallback-no-probe",
            outbounds: alive
        };
    }

    // Sort by probe ms ascending (rough "fastest")
    for (let i = 0; i < length(alive); i++) {
        for (let j = i + 1; j < length(alive); j++) {
            let a = int(alive[i].__forkop_probe_ms || 999999);
            let b = int(alive[j].__forkop_probe_ms || 999999);
            if (b < a) {
                let tmp = alive[i];
                alive[i] = alive[j];
                alive[j] = tmp;
            }
        }
    }

    let selected = [];
    for (let i = 0; i < length(alive) && i < slot_count; i++)
        push(selected, alive[i]);

    return {
        mode: "probed",
        outbounds: selected
    };
}

function refresh_section_slots(section_name, source_outbounds, slot_count) {
    section_name = as_string(section_name);
    if (section_name == "")
        return false;

    let result = select_slots_from_outbounds(source_outbounds, slot_count);
    let payload = {
        version: 1,
        section: section_name,
        updated_at: time(),
        mode: result.mode,
        slot_count: length(result.outbounds),
        outbounds: result.outbounds
    };
    if (!write_slots(section_name, payload))
        return false;
    log_msg(section_name + ": " + length(result.outbounds) + " slot(s) (" + result.mode + ")");
    return true;
}

function slots_outbounds_for_section(section_name) {
    let data = read_slots(section_name);
    if (data == null)
        return [];
    return array_or_empty(data.outbounds);
}

function settings_from_uci() {
    try {
        let cursor = uci_core.cursor();
        if (cursor == null)
            return {};
        cursor.load("forkop");
        let all = cursor.get_all("forkop");
        for (let name, section in object_or_empty(all)) {
            if (as_string(object_or_empty(section)[".type"] || "") == "settings")
                return section;
        }
    } catch (e) {
    }
    return {};
}

// CLI
let mode = as_string(ARGV[0] || "");
if (mode == "path") {
    print(slots_path(as_string(ARGV[1] || "x")), "\n");
} else if (mode == "read") {
    let data = read_slots(as_string(ARGV[1] || ""));
    print(sprintf("%J\n", data == null ? {} : data));
} else if (mode == "refresh-json") {
    // ARGV[1] = path to json file with section/outbounds/slot_count
    let data = object_or_empty(read_json_file(as_string(ARGV[1] || "")));
    let ok = refresh_section_slots(
        as_string(data.section || ""),
        array_or_empty(data.outbounds),
        int(data.slot_count || DEFAULT_SLOT_COUNT)
    );
    print(ok ? "ok\n" : "fail\n");
    exit(ok ? 0 : 1);
} else if (mode != "") {
    warn("Usage: slots.uc path <section>|read <section>|refresh-json\n");
    exit(1);
}

return {
    SLOTS_DIR,
    subscription_mode_from_settings,
    slot_count_from_settings,
    slots_path,
    read_slots,
    write_slots,
    slots_outbounds_for_section,
    refresh_section_slots,
    select_slots_from_outbounds,
    is_leaf_proxy_outbound
};
