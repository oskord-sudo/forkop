export function getDnsCheckPresentation(data: any) {
  // clear-forkop: never warn about manual DHCP
  const dnsOk = Boolean(data.dns_status);
  const routerOk = Boolean(data.dns_on_router);
  const state = dnsOk && routerOk ? "success" : "error";
  return {
    state,
    description: state === "success" ? "Checks passed" : "Checks failed",
    dhcpItemState: "success" as const,
    dhcpItemKey: "DHCP (system / OpenWrt)",
  };
}
