#!/usr/bin/env ucode
/**
 * Routing mode: precise (FakeIP) vs economy (transport-only, no FakeIP).
 */

let uci = require("core.uci");

const MODE_PRECISE = "precise";
const MODE_ECONOMY = "economy";

function as_string(value) {
    return value == null ? "" : "" + value;
}

function config_name() {
    return getenv("FORKOP_CONFIG_NAME") || "forkop";
}

function normalize_mode(value) {
    value = lc(trim(as_string(value)));
    if (value == MODE_ECONOMY || value == "transport" || value == "transport-only" || value == "lite")
        return MODE_ECONOMY;
    return MODE_PRECISE;
}

function routing_mode_from_settings(settings) {
    if (type(settings) != "object" || settings == null)
        return MODE_PRECISE;
    let value = settings.routing_mode;
    if (value == null || as_string(value) == "")
        return MODE_PRECISE;
    return normalize_mode(value);
}

function routing_mode_from_uci() {
    if (!uci.available())
        return MODE_PRECISE;
    let value = uci.get(config_name() + ".settings.routing_mode");
    return normalize_mode(value);
}

function is_economy_mode(settings) {
    if (settings != null)
        return routing_mode_from_settings(settings) == MODE_ECONOMY;
    return routing_mode_from_uci() == MODE_ECONOMY;
}

function is_precise_mode(settings) {
    return !is_economy_mode(settings);
}

function economy_proxy_mark() {
    return getenv("NFT_PROXY_MARK") || "0x05000000";
}

function economy_iface_mark_base() {
    return getenv("NFT_IFACE_MARK_BASE") || "0x06000000";
}

return {
    MODE_PRECISE,
    MODE_ECONOMY,
    normalize_mode,
    routing_mode_from_settings,
    routing_mode_from_uci,
    is_economy_mode,
    is_precise_mode,
    economy_proxy_mark,
    economy_iface_mark_base
};
