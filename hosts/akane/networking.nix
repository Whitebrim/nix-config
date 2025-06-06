{
  config,
  lib,
  pkgs,
  ...
}:
let
  isIpv4 = lib.hasInfix ".";
  isIpv6 = lib.hasInfix ":";

  ispInterface = "vl-isp";
  wglanInterface = "vl-wglan";
  isplanInterface = "vl-isplan";

  ispVlanId = 1;
  wglanVlanId = 2;
  isplanVlanId = 3;

  bridgeInterface = "br0";
  wireguardInterface = "wg0";

  # An additional table for our routes, except that it the default route uses
  # WireGuard interface instead of direct ISP connection.
  #
  # Note that WireGuard host must be running MSS fix since the kernel does not
  # take non-main routing tables into account for nftables’s `set rt mtu`.
  # See https://github.com/openwrt/openwrt/issues/12112
  #
  # In addition to that, we can’t use IncomingInterface= for PBR because reverse
  # path filter implementation in NixOS firewall uses prerouting hook. See also
  # https://web.git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?h=be8be04e5ddb9842d4ff2c1e4eaeec6ca801c573
  wireguardRouteTable = "wireguard";
  wireguardRouteTableNumber = 1000;

  withTable = routeTable: routeConfig: routeConfig // { Table = routeTable; };
  spliceTables =
    routeConfigs: routeTables:
    routeConfigs
    ++ lib.mapCartesianProduct (x: withTable x.routeTable x.routeConfig) {
      routeTable = routeTables;
      routeConfig = routeConfigs;
    };

  wireguardEndpoint = "falcon.tie.rip:51820";
  wireguardConfiguration = [
    {
      cidr = "2a01:4f8:222:fee0::1/60";
      address = "2a01:4f8:222:fee0::1";
      network = "2a01:4f8:222:fee0::/60";
    }
    {
      cidr = "172.28.0.1/14";
      address = "172.28.0.1";
      network = "172.28.0.0/14";
    }
  ];

  wglanConfiguration = [
    {
      cidr = "2a01:4f8:222:feed::1/64";
      address = "2a01:4f8:222:feed::1";
      network = "2a01:4f8:222:feed::/64";
    }
    {
      cidr = "172.31.0.1/16";
      address = "172.31.0.1";
      network = "172.31.0.0/16";
    }
  ];

  wglanConfigurationIpv6 = lib.filter (x: isIpv6 x.address) wglanConfiguration;

  wglanConfigurationAddresses = map (x: x.address) wglanConfiguration;
  wglanConfigurationAddressesIpv4 = lib.filter isIpv4 wglanConfigurationAddresses;
  wglanConfigurationAddressesIpv6 = lib.filter isIpv6 wglanConfigurationAddresses;

  isplanConfiguration = [
    {
      cidr = "fd5c:581e:b102:beef::1/64";
      address = "fd5c:581e:b102:beef::1";
      network = "fd5c:581e:b102:beef::/64";
    }
    {
      cidr = "10.10.10.10/16";
      address = "10.10.10.10";
      network = "10.10.0.0/16";
    }
  ];

  isplanConfigurationIpv6 = lib.filter (x: isIpv6 x.address) isplanConfiguration;

  isplanConfigurationAddresses = map (x: x.address) isplanConfiguration;
  isplanConfigurationAddressesIpv4 = lib.filter isIpv4 isplanConfigurationAddresses;
  isplanConfigurationAddressesIpv6 = lib.filter isIpv6 isplanConfigurationAddresses;

  isplanConfigurationNetworks = map (x: x.network) isplanConfiguration;
  isplanConfigurationNetworksIpv4 = lib.filter isIpv4 isplanConfigurationNetworks;

  # Netfilter queue number for nfqws DPI bypass.
  zapretQnum = 200;
  zapretFwmark = 1073741824; # 0x40000000

  # TODO: do not allow external interfaces to poke around with private networks.
  # See also https://en.wikipedia.org/wiki/Private_network
  # and https://en.wikipedia.org/wiki/Martian_packet
  #privateNetworks = [
  #  "fc00::/7"
  #  "10.0.0.0/8"
  #  "172.16.0.0/12"
  #  "192.168.0.0/16"
  #];

  # Networks that voluntarily block our traffic, usually based on GeoIP
  # databases, have to be routed through VPN.
  ipblockNetworks = lib.concatMap (x: x.networks) (lib.importJSON ../../zapret/ipblock.json);
  ipblockNetworksIpv4 = lib.filter isIpv4 ipblockNetworks;
  ipblockNetworksIpv6 = lib.filter isIpv6 ipblockNetworks;
in
{
  boot.kernel.sysctl = {
    # Allow nfqws to detect censorship for auto hostlist.
    # https://github.com/bol-van/zapret?tab=readme-ov-file#nftables-для-nfqws
    "net.netfilter.nf_conntrack_tcp_be_liberal" = true;
  };

  networking.firewall = {
    checkReversePath = "strict";
    logReversePathDrops = true;
    # Suppress rpfilter drop logs for IGMP traffic (i.e. IPTV) from ISP.
    # See also https://zveronline.ru/archives/1120
    #extraReversePathFilterRules = ''
    #  iifname ${ispInterface} ip protocol igmp drop
    #'';
  };

  networking.firewall.interfaces =
    lib.genAttrs
      [
        wglanInterface
        isplanInterface
      ]
      (_: {
        allowedUDPPorts = [
          # DHCPv4
          67
          # DNS
          53
          # Multicast DNS
          5353
        ];
        allowedTCPPorts = [
          # DNS
          53
        ];
      });

  networking.mssfix.enable = true;

  services.nfqws =
    let
      zapretDesyncTTL = 5;
      zapretDesyncRepeats = 5;
      zapretFakeTLS = pkgs.copyPathToStore ../../zapret/tls_clienthello_vk_com.bin;
      zapretFakeQUIC = pkgs.copyPathToStore ../../zapret/quic_initial_vk_com.bin;
      # Avoids auto hostlist pollution with subdomains.
      zapretHostlistFiles = map pkgs.copyPathToStore [
        ../../zapret/rutracker-domains.txt
        ../../zapret/discord-domains.txt
        ../../zapret/youtube-domains.txt
        ../../zapret/twitter-domains.txt
      ];
      zapretHostlistDomains = lib.concatStringsSep "," [
        "cloudflare-ech.com"
      ];
      zapretHostlistExcludeDomains = lib.concatStringsSep "," [
        "dns.quad9.net"
      ];
      # TODO: hm, it should be possible to detect Discord voice protocol.
      zapretDiscordIpset = pkgs.copyPathToStore ../../zapret/discord-ipset.txt;
    in
    {
      enable = true;
      instances."" = {
        settings = {
          qnum = zapretQnum;
        };
        profiles = {
          "50-https".settings = {
            filter-l7 = "http,tls,quic";
            hostlist = zapretHostlistFiles;
            hostlist-domains = zapretHostlistDomains;
            hostlist-exclude-domains = zapretHostlistExcludeDomains;
            hostlist-auto = "hosts.txt";
            hostlist-auto-fail-threshold = 1;
            dpi-desync = "fake,fakedsplit";
            dpi-desync-fake-tls = zapretFakeTLS;
            dpi-desync-fake-quic = zapretFakeQUIC;
            dpi-desync-ttl = zapretDesyncTTL;
            dpi-desync-repeats = zapretDesyncRepeats;
            dpi-desync-fwmark = zapretFwmark;
          };
          "70-discord-voice".settings = {
            filter-udp = "50000-50100";
            ipset = zapretDiscordIpset;
            dpi-desync = "fake";
            dpi-desync-any-protocol = true;
            dpi-desync-cutoff = "d3";
            dpi-desync-ttl = zapretDesyncTTL;
            dpi-desync-repeats = zapretDesyncRepeats;
            dpi-desync-fwmark = zapretFwmark;
          };
        };
      };
    };

  # https://github.com/bol-van/zapret?tab=readme-ov-file#nftables-для-nfqws
  # https://www.netfilter.org/projects/nftables/manpage.html
  networking.nftables.tables.zapret = {
    family = "inet";
    content = ''
      define iface = ${ispInterface}
      define qnum = ${toString zapretQnum}
      define fwmark = ${toString zapretFwmark}

      set services {
        type inet_proto . inet_service
        flags interval
        elements = {
          tcp . 80,
          tcp . 443,
          udp . 443,
          udp . 50000-50100,
        }
      }

      chain postrouting {
        type filter hook postrouting priority mangle; policy accept;
        oifname $iface \
          meta mark & $fwmark == 0 \
          meta l4proto . th dport @services \
          ct original packets 1-6 \
          queue flags bypass to $qnum
      }

      chain prerouting {
        type filter hook prerouting priority filter; policy accept;
        iifname $iface \
          meta mark & $fwmark == 0 \
          meta l4proto . th sport @services \
          ct reply packets 1-3 \
          queue flags bypass to $qnum
      }
    '';
  };

  networking.nftables.tables.ipblock-nat = {
    family = "inet";
    content = ''
      define local = ${isplanInterface}
      define tunnel = ${wireguardInterface}

      # nftables currently does not have a type that represents a union of
      # `ipv{6,4}_addr`. See https://unix.stackexchange.com/a/647640
      set networks6 {
        type ipv6_addr
        flags interval
        auto-merge
        elements = { ${lib.concatStringsSep ", " ipblockNetworksIpv6} }
      }

      set networks4 {
        type ipv4_addr
        flags interval
        auto-merge
        elements = { ${lib.concatStringsSep ", " ipblockNetworksIpv4} }
      }

      chain postrouting_ipv6 {
        ip6 daddr @networks6 masquerade
      }

      chain postrouting_ipv4 {
        ip daddr @networks4 masquerade
      }

      chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        iifname $local oifname $tunnel \
          meta protocol vmap {
            ip : jump postrouting_ipv4,
            ip6 : jump postrouting_ipv6,
          }
      }
    '';
  };

  networking.nat = {
    enable = true;
    externalInterface = ispInterface;
    internalIPs = isplanConfigurationNetworksIpv4;
  };

  systemd.network.config = {
    networkConfig = {
      IPv4Forwarding = true;
      IPv6Forwarding = true;
    };
    routeTables = {
      ${wireguardRouteTable} = wireguardRouteTableNumber;
    };
  };

  systemd.network.netdevs."10-bridge" = {
    netdevConfig = {
      Name = bridgeInterface;
      Kind = "bridge";
    };
    bridgeConfig = {
      DefaultPVID = "none";
      VLANFiltering = true;
    };
  };

  systemd.network.netdevs."10-isplan" = {
    netdevConfig = {
      Name = isplanInterface;
      Kind = "vlan";
    };
    vlanConfig = {
      Id = isplanVlanId;
    };
  };

  systemd.network.netdevs."10-wglan" = {
    netdevConfig = {
      Name = wglanInterface;
      Kind = "vlan";
    };
    vlanConfig = {
      Id = wglanVlanId;
    };
  };

  systemd.network.netdevs."10-isp" = {
    netdevConfig = {
      Name = ispInterface;
      Kind = "vlan";
    };
    vlanConfig = {
      Id = ispVlanId;
    };
  };

  systemd.network.netdevs."10-wg" = {
    netdevConfig = {
      Name = wireguardInterface;
      Kind = "wireguard";
    };
    wireguardConfig = {
      PrivateKeyFile = config.sops.secrets."wireguard/pk.txt".path;
      H1 = 224412;
      H2 = 52344123;
      H3 = 6713390;
      H4 = 2537922;
    };
    wireguardPeers = [
      {
        AdvancedSecurity = true;
        AllowedIPs = [
          "::/0"
          "0.0.0.0/0"
        ];
        RouteTable = wireguardRouteTable;
        PublicKey = "8LgfPosHOG0SpUGqIlYesskq00Y6wihLtgZFUkutdE0=";
        Endpoint = wireguardEndpoint;
        PresharedKeyFile = config.sops.secrets."wireguard/psk.txt".path;
        PersistentKeepalive = 30;
      }
    ];
  };

  systemd.network.networks."10-bridge" = {
    matchConfig = {
      Name = bridgeInterface;
    };
    networkConfig = {
      VLAN = [
        ispInterface
        wglanInterface
        isplanInterface
      ];
      ConfigureWithoutCarrier = true;
      # https://github.com/systemd/systemd/issues/575#issuecomment-163810166
      LinkLocalAddressing = false;
    };
    bridgeVLANs = [
      { VLAN = ispVlanId; }
      { VLAN = wglanVlanId; }
      { VLAN = isplanVlanId; }
    ];
    linkConfig = {
      RequiredForOnline = "no-carrier:carrier";
    };
  };

  systemd.network.networks."10-bridge-lan" = {
    matchConfig = {
      Name = [
        "enp3s0"
        "enp4s0"
        "enp5s0"
        "enp6s0"
        "enp7s0"
        "enp8s0"
        "enp9s0"
      ];
    };
    networkConfig = {
      Bridge = bridgeInterface;
      ConfigureWithoutCarrier = true;
    };
    bridgeVLANs = [
      { VLAN = ispVlanId; }
      { VLAN = wglanVlanId; }
      {
        PVID = isplanVlanId;
        EgressUntagged = isplanVlanId;
      }
    ];
    linkConfig = {
      RequiredForOnline = "no-carrier:enslaved";
    };
  };

  systemd.network.networks."10-bridge-isp" = {
    matchConfig = {
      Name = [ "enp2s0" ];
    };
    networkConfig = {
      Bridge = bridgeInterface;
      ConfigureWithoutCarrier = true;
    };
    bridgeVLANs = [
      {
        PVID = ispVlanId;
        EgressUntagged = ispVlanId;
      }
    ];
    linkConfig = {
      RequiredForOnline = "no-carrier:enslaved";
    };
  };

  systemd.network.networks."10-wglan" = {
    matchConfig = {
      Name = wglanInterface;
    };
    networkConfig = {
      ConfigureWithoutCarrier = true;
      IPv6PrivacyExtensions = true;
      IPv6AcceptRA = false;
      IPv6SendRA = true;
      DHCPServer = true;
      MulticastDNS = true;
      LLMNR = true;
    };
    dhcpServerConfig = {
      DNS = wglanConfigurationAddressesIpv4;
    };
    ipv6SendRAConfig = {
      RetransmitSec = 1800; # 30 minutes
      DNS = wglanConfigurationAddressesIpv6;
    };
    addresses =
      let
        makeAddress =
          { cidr, ... }:
          {
            Address = cidr;
            AddPrefixRoute = false;
          };
      in
      map makeAddress wglanConfiguration;
    routes =
      let
        makeRoute =
          { network, address, ... }:
          {
            Destination = network;
            PreferredSource = address;
          };
      in
      spliceTables (map makeRoute wglanConfiguration) [ wireguardRouteTable ];
    ipv6Prefixes =
      let
        makeIPv6Prefix =
          { network, ... }:
          {
            Prefix = network;
          };
      in
      map makeIPv6Prefix wglanConfigurationIpv6;
    routingPolicyRules =
      let
        makeRoutingPolicyRule =
          { network, ... }:
          {
            From = network;
            Table = wireguardRouteTable;
          };
      in
      map makeRoutingPolicyRule wglanConfiguration;
    linkConfig = {
      RequiredForOnline = "no-carrier:routable";
    };
  };

  systemd.network.networks."10-isplan" = {
    matchConfig = {
      Name = isplanInterface;
    };
    networkConfig = {
      ConfigureWithoutCarrier = true;
      IPv6PrivacyExtensions = true;
      IPv6AcceptRA = false;
      IPv6SendRA = true;
      DHCPServer = true;
      DHCPPrefixDelegation = true;
      MulticastDNS = true;
      LLMNR = true;
    };
    dhcpServerConfig = {
      DNS = isplanConfigurationAddressesIpv4;
    };
    ipv6SendRAConfig = {
      RetransmitSec = 1800; # 30 minutes
      DNS = isplanConfigurationAddressesIpv6;
    };
    dhcpPrefixDelegationConfig = {
      UplinkInterface = ispInterface;
    };
    addresses =
      let
        makeAddress =
          { cidr, ... }:
          {
            Address = cidr;
            AddPrefixRoute = false;
          };
      in
      map makeAddress isplanConfiguration;
    routes =
      let
        makeRoute =
          { network, address, ... }:
          {
            Destination = network;
            PreferredSource = address;
          };
      in
      spliceTables (map makeRoute isplanConfiguration) [ wireguardRouteTable ];
    ipv6Prefixes =
      let
        makeIPv6Prefix =
          { network, ... }:
          {
            Prefix = network;
          };
      in
      map makeIPv6Prefix isplanConfigurationIpv6;
    linkConfig = {
      RequiredForOnline = "no-carrier:routable";
    };
  };

  systemd.network.networks."10-isp" = {
    matchConfig = {
      Name = ispInterface;
    };
    networkConfig = {
      DHCP = true;
      IPv6AcceptRA = true;
      IPv6PrivacyExtensions = true;
      MulticastDNS = false;
      LLMNR = false;
      DNSOverTLS = true;
      # DNSSEC implementation seems to be broken.
      # E.g. https://github.com/systemd/systemd/issues/34896
      DNSSEC = false;
      DNS = [
        "2620:fe::fe#dns.quad9.net"
        "2620:fe::9#dns.quad9.net"
        "9.9.9.9#dns.quad9.net"
        "149.112.112.112#dns.quad9.net"
      ];
    };
    ipv6AcceptRAConfig = {
      UseDNS = false;
      UseDomains = false;
    };
    dhcpV6Config = {
      UseDelegatedPrefix = true;
      # TODO: added in systemd version 257.
      #UnassignedSubnetPolicy = "none";

      # Note: for prefix delegations that are allocated dynamically if released.
      # Addresses can be safely released though. TODO: add prefixes/addresses
      # option to systemd?
      SendRelease = false;

      UseDNS = false;
      UseDomains = false;
      UseNTP = false;
    };
    dhcpV4Config = {
      UseDNS = false;
      UseDomains = false;
      UseNTP = false;
      UseSIP = false;
    };
    linkConfig = {
      RequiredForOnline = "routable";
    };
  };

  systemd.network.networks."10-wg" = {
    matchConfig = {
      Name = wireguardInterface;
    };
    addresses =
      let
        makeAddress =
          { cidr, ... }:
          {
            Address = cidr;
            AddPrefixRoute = false;
          };
      in
      map makeAddress wireguardConfiguration;
    routes =
      let
        makeRoute =
          { network, address, ... }:
          {
            Destination = network;
            PreferredSource = address;
          };
      in
      map makeRoute wireguardConfiguration
      ++ map (network: {
        Destination = network;
      }) ipblockNetworks;
    linkConfig = {
      RequiredForOnline = "carrier:routable";
    };
  };

  services.resolved = {
    extraConfig =
      lib.concatLines (
        map (address: "DNSStubListenerExtra=" + address) (
          wglanConfigurationAddresses ++ isplanConfigurationAddresses
        )
      )
      + ''
        StaleRetentionSec=1d
      '';
  };

  systemd.services.systemd-networkd = {
    serviceConfig = {
      SupplementaryGroups = [ config.users.groups.keys.name ];
      # Uncomment to enable verbose logging for systemd-networkd.
      #Environment = [ "SYSTEMD_LOG_LEVEL=debug" ];
    };
  };

  sops.secrets = {
    "wireguard/pk.txt" = {
      mode = "0440";
      group = config.users.groups.systemd-network.name;
      reloadUnits = [ config.systemd.services.systemd-networkd.name ];
      sopsFile = ../../secrets/wireguard-pk-akane.sops.yaml;
    };
    "wireguard/psk.txt" = {
      mode = "0440";
      group = config.users.groups.systemd-network.name;
      reloadUnits = [ config.systemd.services.systemd-networkd.name ];
      sopsFile = ../../secrets/wireguard-psk.sops.yaml;
    };
  };
}
