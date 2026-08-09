#!/usr/bin/env ucode

const DNS_SERVER_TAG = "dns-server";
const BOOTSTRAP_DNS_SERVER_TAG = "bootstrap-dns-server";
const DNSMASQ_DNS_SERVER_TAG = "dnsmasq-server";

const TPROXY_INBOUND_TAG = "tproxy-in";
const TPROXY_INBOUND_ADDRESS = "0.0.0.0";
const TPROXY_INBOUND6_TAG = "tproxy6-in";
const TPROXY_INBOUND6_ADDRESS = "::1";
const TPROXY_INBOUND_PORT = 1602;
const DNS_INBOUND_TAG = "dns-in";
const DNS_INBOUND_ADDRESS = "127.0.0.42";
const DNS_INBOUND_PORT = 53;
const SOURCE_DNS_INBOUND_TAG = "source-dns-in";
const SOURCE_DNS_INBOUND_ADDRESS = "::";
const SOURCE_DNS_INBOUND_PORT = 1603;

const SERVICE_MIXED_INBOUND_TAG = "service-mixed-in";
const SERVICE_MIXED_INBOUND_ADDRESS = "127.0.0.1";
const SERVICE_MIXED_INBOUND_PORT = 4534;
const DIRECT_OUTBOUND_TAG = "direct-out";
const BYPASS_OUTBOUND_TAG = "bypass-out";
const OUTBOUND_MARK = 134217728;

const DISABLED_UPDATE_INTERVAL = "876000h";
const URLTEST_DEFAULT_IDLE_TIMEOUT = "30m";
const CHECK_PROXY_IP_DOMAIN = "ip.podkop.fyi";
const TMP_SING_BOX_FOLDER = "/tmp/sing-box";
const TMP_RULESET_FOLDER = TMP_SING_BOX_FOLDER + "/rulesets";
const ZAPRET_ROUTE_MARK_BASE = 0x01000000;
const ZAPRET2_ROUTE_MARK_BASE = 0x02000000;
const BYEDPI_LISTEN_ADDRESS = "127.0.0.1";
const BYEDPI_PORT_BASE = 1080;

const RESERVED_TAGS = {
    [DNS_SERVER_TAG]: true,
    [BOOTSTRAP_DNS_SERVER_TAG]: true,
    [DNSMASQ_DNS_SERVER_TAG]: true,
    [TPROXY_INBOUND_TAG]: true,
    [TPROXY_INBOUND6_TAG]: true,
    [DNS_INBOUND_TAG]: true,
    [SOURCE_DNS_INBOUND_TAG]: true,
    [SERVICE_MIXED_INBOUND_TAG]: true,
    [DIRECT_OUTBOUND_TAG]: true,
    [BYPASS_OUTBOUND_TAG]: true
};

function as_string(value) {
    return value == null ? "" : "" + value;
}

function tag(base, postfix) {
    let candidate = as_string(base) + "-" + as_string(postfix);
    return RESERVED_TAGS[candidate] ? candidate + "-1" : candidate;
}

function inbound_tag(section_name) {
    return tag(section_name, "in");
}

function outbound_tag(section_name) {
    return tag(section_name, "out");
}

function domain_resolver_tag(section_name) {
    return tag(section_name, "domain-resolver");
}

function server_inbound_tag(section_name) {
    return tag("server-" + as_string(section_name), "in");
}

function tailscale_dns_server_tag(section_name) {
    return tag("server-" + as_string(section_name), "tailscale-dns");
}

return {
    DNS_SERVER_TAG,
    BOOTSTRAP_DNS_SERVER_TAG,
    DNSMASQ_DNS_SERVER_TAG,
    TPROXY_INBOUND_TAG,
    TPROXY_INBOUND_ADDRESS,
    TPROXY_INBOUND6_TAG,
    TPROXY_INBOUND6_ADDRESS,
    TPROXY_INBOUND_PORT,
    DNS_INBOUND_TAG,
    DNS_INBOUND_ADDRESS,
    DNS_INBOUND_PORT,
    SOURCE_DNS_INBOUND_TAG,
    SOURCE_DNS_INBOUND_ADDRESS,
    SOURCE_DNS_INBOUND_PORT,
    SERVICE_MIXED_INBOUND_TAG,
    SERVICE_MIXED_INBOUND_ADDRESS,
    SERVICE_MIXED_INBOUND_PORT,
    DIRECT_OUTBOUND_TAG,
    BYPASS_OUTBOUND_TAG,
    OUTBOUND_MARK,
    DISABLED_UPDATE_INTERVAL,
    URLTEST_DEFAULT_IDLE_TIMEOUT,
    CHECK_PROXY_IP_DOMAIN,
    TMP_SING_BOX_FOLDER,
    TMP_RULESET_FOLDER,
    ZAPRET_ROUTE_MARK_BASE,
    ZAPRET2_ROUTE_MARK_BASE,
    BYEDPI_LISTEN_ADDRESS,
    BYEDPI_PORT_BASE,
    RESERVED_TAGS,
    tag,
    inbound_tag,
    outbound_tag,
    domain_resolver_tag,
    server_inbound_tag,
    tailscale_dns_server_tag
};
