# Generates nixosConfigurations from nix8s clusters
{ lib, config, inputs, ... }:

let
  cfg = config.nix8s;
  nix8sModulesPath = ../modules/nixos;

  memberAttrs = [ "node" "role" "ip" ];

  resolveNode = clusterName: memberName: nodeRef:
    if builtins.isAttrs nodeRef
    then nodeRef
    else
      cfg.nodes.${nodeRef} or
        (throw "nix8s: clusters.${clusterName}.members.${memberName}.node references '${nodeRef}' which doesn't exist in nix8s.nodes");

  buildNodeConfig = clusterName: memberName: member:
    let
      baseNode = resolveNode clusterName memberName member.node;
      memberOverrides = removeAttrs member memberAttrs;
    in
    lib.recursiveUpdate baseNode memberOverrides;

  validateSecrets = clusterName: cluster:
    if (cluster.secrets.token or null) == null
    then throw "nix8s: clusters.${clusterName}.secrets.token is required"
    else cluster;

  mkNixosConfig = { clusterName, cluster, memberName, member }:
    let
      validatedCluster = validateSecrets clusterName cluster;
      nodeConfig = buildNodeConfig clusterName memberName member;
      nodeName = "${clusterName}-${memberName}";

      isFirstServer =
        member.role == "server" &&
        memberName == (cluster.ha.firstServer or
          (lib.head (lib.sort (a: b: a < b)
            (lib.attrNames (lib.filterAttrs (_: m: m.role == "server") cluster.members)))));
    in
    lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = {
        inherit inputs;
        nix8s = {
          cluster = validatedCluster;
          inherit member nodeConfig;
          inherit clusterName memberName isFirstServer;
        };
      };
      modules = [
        inputs.disko.nixosModules.disko
        (nix8sModulesPath + "/base.nix")
        (nix8sModulesPath + "/k3s.nix")
      ] ++ (nodeConfig.nixosModules or [ ])
      ++ (cfg.nixosModulesFor.${nodeName} or [ ]);
    };

  allConfigs = lib.concatMapAttrs
    (clusterName: cluster:
      lib.mapAttrs'
        (memberName: member:
          lib.nameValuePair
            "${clusterName}-${memberName}"
            (mkNixosConfig { inherit clusterName cluster memberName member; })
        )
        cluster.members
    )
    cfg.clusters;

in
{
  config.flake.nixosConfigurations = allConfigs;
}
