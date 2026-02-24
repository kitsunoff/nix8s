# k3s server/agent configuration
{ config, lib, pkgs, nix8s, ... }:

let
  cluster = nix8s.cluster;
  member = nix8s.member;
  isFirstServer = nix8s.isFirstServer;

  # Get cluster settings
  k3sConfig = cluster.k3s or { };
  secrets = cluster.secrets;
  cozystackCfg = cluster.cozystack or { };
  cozystackEnabled = cozystackCfg.enable or false;

  # k3s package (can be overridden via cluster.k3s.package)
  k3sPackage = k3sConfig.package or pkgs.k3s;

  # Server URL for joining (first server's IP)
  # After initial join, k3s agent uses built-in loadbalancer on 127.0.0.1:6444
  # which automatically discovers all servers - no VIP needed
  serverMembers = lib.filterAttrs (_: m: m.role == "server") cluster.members;
  sortedServerNames = lib.sort (a: b: a < b) (lib.attrNames serverMembers);
  firstServerName =
    if cluster.firstServer or null != null
    then cluster.firstServer
    else lib.head sortedServerNames;
  firstServer = cluster.members.${firstServerName};
  serverUrl = "https://${firstServer.ip}:6443";

  # Build extra flags
  extraServerFlags = k3sConfig.extraArgs.server or [ ];
  extraAgentFlags = k3sConfig.extraArgs.agent or [ ];

  # Cozystack requires specific k3s configuration
  cozystackFlags = lib.optionals cozystackEnabled [
    "--disable=traefik"
    "--disable=servicelb"
    "--disable=local-storage"
    "--disable=metrics-server"
    "--disable-network-policy"
    "--disable-kube-proxy"
    "--flannel-backend=none"
    "--cluster-domain=${cozystackCfg.clusterDomain or "cozy.local"}"
    "--tls-san=${member.ip}"
    "--kubelet-arg=max-pods=${toString (cozystackCfg.maxPods or 220)}"
  ];

  # Network configuration flags
  networkFlags =
    let
      network = k3sConfig.network or { };
    in
    (lib.optional (network.clusterCidr or null != null)
      "--cluster-cidr=${network.clusterCidr}")
    ++ (lib.optional (network.serviceCidr or null != null)
      "--service-cidr=${network.serviceCidr}")
    ++ (lib.optional (network.clusterDns or null != null)
      "--cluster-dns=${network.clusterDns}");

  # All flags combined
  serverFlags =
    [ "--node-ip=${member.ip}" ]
    ++ networkFlags
    ++ cozystackFlags
    ++ extraServerFlags
    ++ lib.optionals isFirstServer [ "--cluster-init" ];

  agentFlags =
    [ "--node-ip=${member.ip}" ]
    ++ (lib.optionals cozystackEnabled [
      "--kubelet-arg=max-pods=${toString (cozystackCfg.maxPods or 220)}"
    ])
    ++ extraAgentFlags;

in
{
  services.k3s = {
    enable = true;
    package = k3sPackage;

    role = member.role;

    # Token for cluster membership
    token = secrets.token;

    # Server URL (not needed for first server with --cluster-init)
    serverAddr = lib.mkIf (!isFirstServer) serverUrl;

    # Extra flags
    extraFlags = lib.concatStringsSep " " (
      if member.role == "server"
      then serverFlags
      else agentFlags
    );
  };

  # Ensure containerd is configured properly for k3s
  # k3s manages its own containerd, so we just need firewall rules

  # Additional firewall rules for k3s
  networking.firewall = {
    allowedTCPPorts = [
      2379  # etcd client
      2380  # etcd peer
      10250 # kubelet metrics
    ];
    # Allow all traffic between cluster nodes (simplified for now)
    # In production, you'd want to be more restrictive
    trustedInterfaces = [ "cni0" "flannel.1" ];
  };

  # Disable swap (Kubernetes requirement)
  swapDevices = lib.mkForce [ ];

  # Enable IP forwarding
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv6.conf.all.forwarding" = 1;
    "net.bridge.bridge-nf-call-iptables" = 1;
    "net.bridge.bridge-nf-call-ip6tables" = 1;
  };

  # Load required kernel modules
  boot.kernelModules = [
    "br_netfilter"
    "overlay"
  ];
}
