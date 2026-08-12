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
const DEFAULT_SLOT_COUNT = 10;
const PROBE_TIMEOUT_SEC = 1;
const PROBE_MAX_CANDIDATES = 40;

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
    // Round-robin by protocol so VLESS does not occupy all slots when listed first
    let by_type = {};
    let type_order = [];
    for (let outbound in array_or_empty(outbounds)) {
        if (!is_leaf_proxy_outbound(outbound))
            continue;
        let t = as_string(outbound.type || "other");
        if (by_type[t] == null) {
            by_type[t] = [];
            push(type_order, t);
        }
        if (length(by_type[t]) < PROBE_MAX_CANDIDATES)
            push(by_type[t], outbound);
    }

    let candidates = [];
    let more = true;
    let idx = 0;
    while (more && length(candidates) < PROBE_MAX_CANDIDATES) {
        more = false;
        for (let t in type_order) {
            let arr = by_type[t];
            if (idx < length(arr)) {
                push(candidates, arr[idx]);
                more = true;
                if (length(candidates) >= PROBE_MAX_CANDIDATES)
                    break;
            }
        }
        idx++;
    }

    let alive = [];
    // Probe all candidates (do not stop at slot_count)
    for (let outbound in candidates) {
        let probe = probe_outbound(outbound);
        if (!probe.ok)
            continue;
        let copy = {};
        for (let k, v in outbound)
            copy[k] = v;
        copy.__forkop_probe_ms = probe.ms;
        push(alive, copy);
    }

    if (length(alive) == 0) {
        let selected = [];
        for (let t in type_order) {
            if (length(selected) >= slot_count)
                break;
            if (length(by_type[t]) > 0)
                push(selected, by_type[t][0]);
        }
        for (let outbound in candidates) {
            if (length(selected) >= slot_count)
                break;
            let already = false;
            for (let s in selected) {
                if (as_string(s.tag || "") == as_string(outbound.tag || "") &&
                    as_string(s.server || "") == as_string(outbound.server || "")) {
                    already = true;
                    break;
                }
            }
            if (!already)
                push(selected, outbound);
        }
        return { mode: "fallback-no-probe", outbounds: selected };
    }

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
    let used = {};
    for (let t in type_order) {
        if (length(selected) >= slot_count)
            break;
        for (let outbound in alive) {
            if (as_string(outbound.type || "") != t)
                continue;
            let key = as_string(outbound.tag || "") + "|" + as_string(outbound.server || "");
            if (used[key])
                continue;
            used[key] = true;
            push(selected, outbound);
            break;
        }
    }
    for (let outbound in alive) {
        if (length(selected) >= slot_count)
            break;
        let key = as_string(outbound.tag || "") + "|" + as_string(outbound.server || "");
        if (used[key])
            continue;
        used[key] = true;
        push(selected, outbound);
    }

    return { mode: "probed", outbounds: selected };
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

function slot_refresh_interval_seconds(settings) {
    settings = object_or_empty(settings);
    if (length(keys(settings)) == 0)
        settings = load_settings_section();
    let raw = trim(option(settings, "subscription_slot_refresh_interval", "15m"));
    // support Ns/Nm/Nh or plain minutes
    if (raw == "")
        return 900;
    let m = match(raw, /^([0-9]+)([smhd])?$/);
    if (m == null) {
        let n = int(raw);
        return n > 0 ? n * 60 : 900;
    }
    let n = int(m[1]);
    let u = m[2] || "m";
    if (u == "s") return n < 60 ? 60 : n;
    if (u == "m") return n * 60;
    if (u == "h") return n * 3600;
    if (u == "d") return n * 86400;
    return 900;
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
    is_leaf_proxy_outbound,
    slot_refresh_interval_seconds,
    DEFAULT_SLOT_COUNT
};
