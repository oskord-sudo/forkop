"use strict";
"require form";
"require uci";
"require baseclass";
"require tools.widgets as widgets";
"require view.forkop.main as main";

const UCI_PACKAGE = main.FORKOP_UCI_PACKAGE;

function isSingBoxDuration(value) {
  return /^(?=.*[1-9])([0-9]+(?:\.[0-9]+)?(?:ns|us|ms|s|m|h|d))+$/.test(value);
}

function latencyTestUrlChoices() {
  return Array.isArray(main.LATENCY_TEST_URL_OPTIONS)
    ? main.LATENCY_TEST_URL_OPTIONS
    : [main.DEFAULT_LATENCY_TEST_URL || "https://www.gstatic.com/generate_204"];
}

function validateLatencyTestUrl(value) {
  const validation = main.validateUrl(`${value || ""}`.trim());
  return validation.valid ? true : validation.message;
}

function isDownloadSectionAction(action, capabilities) {
  switch (action) {
    case "connection":
    case "proxy":
    case "outbound":
    case "vpn":
      return true;
    case "zapret":
      return !capabilities?.loaded || Boolean(capabilities.zapretInstalled);
    case "zapret2":
      return !capabilities?.loaded || Boolean(capabilities.zapret2Installed);
    case "byedpi":
      return !capabilities?.loaded || Boolean(capabilities.byedpiInstalled);
    default:
      return false;
  }
}

function refreshDownloadSectionChoices(option, capabilities) {
  const sections = option.map?.data?.state?.values?.[UCI_PACKAGE] ?? {};

  option.keylist = [];
  option.vallist = [];

  for (const secName in sections) {
    const sec = sections[secName];
    if (
      sec[".type"] === "section" &&
      sec.enabled !== "0" &&
      isDownloadSectionAction(sec.action, capabilities)
    ) {
      option.value(secName, sec.label || secName);
    }
  }
}

function configureDownloadSectionOption(option, sectionOption, capabilities) {
  option.default = "";
  option.rmempty = false;
  option.cfgvalue = function (section_id) {
    return uci.get(UCI_PACKAGE, section_id, sectionOption) || "";
  };
  option.load = function (section_id) {
    refreshDownloadSectionChoices(this, capabilities);
    return this.cfgvalue(section_id);
  };
  option.write = function (section_id, value) {
    const normalized = value ? `${value}`.trim() : "";

    if (normalized) {
      uci.set(UCI_PACKAGE, section_id, sectionOption, normalized);
    } else {
      uci.unset(UCI_PACKAGE, section_id, sectionOption);
    }
  };
  option.remove = function (section_id) {
    uci.unset(UCI_PACKAGE, section_id, sectionOption);
  };
  option.validate = function (_section_id, value) {
    return value ? true : _("Select a section");
  };
}

function configureDownloadViaProxyFlag(option, sectionOption) {
  option.default = "0";
  option.rmempty = false;
  option.write = function (section_id, value) {
    const enabled = value === "1" || value === true;
    uci.set(UCI_PACKAGE, section_id, this.option, enabled ? "1" : "0");
    if (!enabled) {
      uci.unset(UCI_PACKAGE, section_id, sectionOption);
    }
  };
}

function optionListValues(option, section_id) {
  const formValue = option.formvalue(section_id);
  const value = formValue != null ? formValue : option.cfgvalue(section_id);
  return L.toArray(value)
    .map((item) => `${item || ""}`.trim())
    .filter(Boolean);
}

function configureDnsList(option, choices, defaultValue) {
  Object.entries(choices).forEach(([key, label]) => {
    option.value(key, _(label));
  });
  option.default = [defaultValue];
  option.rmempty = false;
  option.validate = function (_section_id, value) {
    const normalized = `${value || ""}`.trim();
    if (!normalized) {
      return optionListValues(option, _section_id).length > 0
        ? true
        : _("Add at least one DNS server");
    }
    const validation = main.validateDNS(normalized);
    return validation.valid ? true : validation.message;
  };
}

function configureDnsFailoverVisibility(option, dnsOption, bootstrapOption) {
  option.depends("dns_server", "__forkop_multiple_dns__");
  option.depends("bootstrap_dns_server", "__forkop_multiple_dns__");
  option.retain = true;
  option.checkDepends = function (section_id) {
    return (
      optionListValues(dnsOption, section_id).length > 1 ||
      optionListValues(bootstrapOption, section_id).length > 1
    );
  };
}

function configureDnsDuration(
  option,
  defaultValue,
  dnsOption,
  bootstrapOption,
) {
  option.default = defaultValue;
  option.rmempty = false;
  option.validate = function (_section_id, value) {
    const normalized = `${value || ""}`.trim();
    if (!normalized || !isSingBoxDuration(normalized)) {
      return _("Use sing-box duration format like 10s, 1m or 2m30s");
    }
    return true;
  };
  configureDnsFailoverVisibility(option, dnsOption, bootstrapOption);
}

function createSettingsContent(section, capabilities) {
  let o;

  o = section.option(
    widgets.DeviceSelect,
    "source_network_interfaces",
    _("Source Network Interface"),
    _("Select the network interface from which the traffic will originate"),
  );
  o.default = "br-lan";
  o.noaliases = true;
  o.nobridges = false;
  o.noinactive = false;
  o.multiple = true;

  o = section.option(
    form.Flag,
    "no_proxy_torrents",
    _("Torrents without proxy"),
    _(
      "Send BitTorrent traffic direct (not through proxy/VPN). Uses protocol detection, common BT ports, and optional custom ports.",
    ),
  );
  o.default = "1";
  o.rmempty = false;

  o = section.option(
    form.DynamicList,
    "torrent_direct_ports",
    _("Extra BitTorrent ports"),
    _(
      "Additional TCP/UDP ports treated as BitTorrent and sent direct. Examples: 51413, 6881-6889.",
    ),
  );
  o.depends("no_proxy_torrents", "1");
  o.placeholder = "51413";
  o.rmempty = true;

  o = section.option(
    form.Flag,
    "proxy_calls",
    _("Proxy VoIP / calls"),
    _("Route typical call/media ports through the selected proxy section."),
  );
  o.default = "0";
  o.rmempty = false;

  o = section.option(
    form.ListValue,
    "proxy_calls_section",
    _("VoIP / calls section"),
    _("Proxy section used for call/media traffic when Proxy VoIP is enabled."),
  );
  o.depends("proxy_calls", "1");
  configureDownloadSectionOption(o, "proxy_calls_section", capabilities);

  o = section.option(
    form.Flag,
    "zapret_voice",
    _("Discord voice via direct (Zapret-friendly)"),
    _(
      "Prefer direct for Discord voice UDP ranges so traffic can use Zapret path when configured.",
    ),
  );
  o.default = "0";
  o.rmempty = false;

  o = section.option(
    form.ListValue,
    "lan_proxy_mode",
    _("LAN client policy"),
    _("Limit which devices on the LAN are processed by Forkop routing."),
  );
  o.value("disabled", _("All devices"));
  o.value("except_listed", _("All except listed (IP/MAC)"));
  o.value("listed_only", _("Only listed devices (IP/MAC)"));
  o.default = "disabled";
  o.rmempty = false;

  o = section.option(
    form.DynamicList,
    "lan_direct_ipv4_ips",
    _("Direct IPv4 clients"),
    _("These clients skip proxy/VPN routing (except listed mode)."),
  );
  o.datatype = "ip4addr";
  o.depends("lan_proxy_mode", "except_listed");
  o.rmempty = true;

  o = section.option(
    form.DynamicList,
    "lan_direct_mac_addrs",
    _("Direct MAC clients"),
    _("These clients skip proxy/VPN routing (except listed mode)."),
  );
  o.datatype = "macaddr";
  o.depends("lan_proxy_mode", "except_listed");
  o.rmempty = true;

  o = section.option(
    form.DynamicList,
    "lan_proxy_ipv4_ips",
    _("Proxied IPv4 clients"),
    _("Only these clients are routed by Forkop (listed only mode)."),
  );
  o.datatype = "ip4addr";
  o.depends("lan_proxy_mode", "listed_only");
  o.rmempty = true;

  o = section.option(
    form.DynamicList,
    "lan_proxy_mac_addrs",
    _("Proxied MAC clients"),
    _("Only these clients are routed by Forkop (listed only mode)."),
  );
  o.datatype = "macaddr";
  o.depends("lan_proxy_mode", "listed_only");
  o.rmempty = true;

  o = section.option(
    form.Flag,
    "download_lists_via_proxy",
    _("Download lists through a section"),
    _("Download remote lists and rule sets via the selected section"),
  );
  configureDownloadViaProxyFlag(o, "download_lists_via_proxy_section");

  o = section.option(
    form.ListValue,
    "download_lists_via_proxy_section",
    _("Download lists through"),
  );
  o.depends("download_lists_via_proxy", "1");
  configureDownloadSectionOption(o, "download_lists_via_proxy_section", capabilities);

  o = section.option(
    form.Flag,
    "download_components_via_proxy",
    _("Download components through a section"),
    _("Download component packages via the selected section"),
  );
  configureDownloadViaProxyFlag(o, "download_components_via_proxy_section");

  o = section.option(
    form.ListValue,
    "download_components_via_proxy_section",
    _("Download components through"),
  );
  o.depends("download_components_via_proxy", "1");
  configureDownloadSectionOption(o, "download_components_via_proxy_section", capabilities);

  o = section.option(
    form.ListValue,
    "config_path",
    _("Config File Path"),
    _(
      "Select path for sing-box config file. Change this ONLY if you know what you are doing",
    ),
  );
  o.value("/etc/sing-box/config.json", "Flash (/etc/sing-box/config.json)");
  o.value("/tmp/sing-box/config.json", "RAM (/tmp/sing-box/config.json)");
  o.default = "/etc/sing-box/config.json";
  o.rmempty = false;

  o = section.option(
    form.Value,
    "cache_path",
    _("Cache File Path"),
    _(
      "Select or enter path for sing-box cache file. Change this ONLY if you know what you are doing",
    ),
  );
  o.value("/tmp/sing-box/cache.db", "RAM (/tmp/sing-box/cache.db)");
  o.value("/usr/share/sing-box/cache.db", "Flash (/usr/share/sing-box/cache.db)");
  o.default = "/tmp/sing-box/cache.db";
  o.rmempty = false;
  o.validate = function (section_id, value) {
    if (!value) return _("Cache file path cannot be empty");
    if (!value.startsWith("/")) return _("Path must be absolute (start with /)");
    if (!value.endsWith("cache.db")) return _("Path must end with cache.db");
    const parts = value.split("/").filter(Boolean);
    if (parts.length < 2)
      return _("Path must contain at least one directory (like /tmp/cache.db)");
    return true;
  };

  o = section.option(
    form.ListValue,
    "log_level",
    _("Log Level"),
    _("Select the log level for sing-box"),
  );
  o.value("trace", "Trace");
  o.value("debug", "Debug");
  o.value("info", "Info");
  o.value("warn", "Warn");
  o.value("error", "Error");
  o.value("fatal", "Fatal");
  o.value("panic", "Panic");
  o.default = "warn";
  o.rmempty = false;

  o = section.option(
    form.Flag,
    "exclude_ntp",
    _("Exclude NTP"),
    _(
      "Exclude NTP protocol traffic from the tunnel to prevent it from being routed through the proxy or VPN",
    ),
  );
  o.default = "0";
  o.rmempty = false;
}


const EntryPoint = {
  createSettingsContent,
};

return baseclass.extend(EntryPoint);
