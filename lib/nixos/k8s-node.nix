# NixOS module for Kubernetes nodes
# Automatically added to nodeConfigurations by k8s-joiner
{ config, lib, pkgs, ... }:

let
  k8s = pkgs.kubernetes;
in {
  boot.kernelModules = [ "overlay" "br_netfilter" ];

  boot.kernel.sysctl = {
    "net.bridge.bridge-nf-call-iptables" = 1;
    "net.bridge.bridge-nf-call-ip6tables" = 1;
    "net.ipv4.ip_forward" = 1;
  };

  swapDevices = lib.mkForce [];

  virtualisation.containerd = {
    enable = true;
    settings = {
      version = 2;
      plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc = {
        runtime_type = "io.containerd.runc.v2";
        options.SystemdCgroup = true;
      };
    };
  };

  environment.systemPackages = [
    k8s
    pkgs.cri-tools
    pkgs.jq
    pkgs.curl
    pkgs.cni-plugins
  ];

  systemd.services.kubelet = {
    description = "Kubernetes Kubelet";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" "containerd.service" ];
    requires = [ "containerd.service" ];

    path = [
      k8s
      pkgs.iptables
      pkgs.iproute2
      pkgs.cni-plugins
      pkgs.containerd
    ];

    serviceConfig = {
      ExecStart = "${k8s}/bin/kubelet --config=/var/lib/kubelet/config.yaml --kubeconfig=/etc/kubernetes/kubelet.conf --bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --container-runtime-endpoint=unix:///run/containerd/containerd.sock";
      Restart = "always";
      RestartSec = 10;
    };
  };

  environment.etc."cni/net.d/.keep".text = "";
  networking.firewall.enable = false;

  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "prohibit-password";
  };

  system.stateVersion = "24.05";
}
