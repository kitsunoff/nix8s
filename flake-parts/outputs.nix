# Generates nixosConfigurations from nix8s clusters
{ lib, config, inputs, ... }:

let
  cfg = config.nix8s;
  nixosModules = (inputs.import-tree.withLib lib).leafs ../modules/nixos;

  # Member-specific attrs (not merged into node config)
  memberAttrs = [ "node" "role" "ip" ];

  # Resolve node reference (string or attrset)
  resolveNode = clusterName: memberName: nodeRef:
    if builtins.isAttrs nodeRef
    then nodeRef
    else
      cfg.nodes.${nodeRef} or
        (throw "nix8s: clusters.${clusterName}.members.${memberName}.node references '${nodeRef}' which doesn't exist in nix8s.nodes");

  # Build final node config: node template + member overrides
  buildNodeConfig = clusterName: memberName: member:
    let
      baseNode = resolveNode clusterName memberName member.node;
      memberOverrides = removeAttrs member memberAttrs;
    in
    lib.recursiveUpdate baseNode memberOverrides;

  # Validate cluster secrets
  validateSecrets = clusterName: cluster:
    if (cluster.secrets.token or null) == null
    then throw "nix8s: clusters.${clusterName}.secrets.token is required"
    else cluster;

  # Generate a single nixosConfiguration
  mkNixosConfig = { clusterName, cluster, memberName, member }:
    let
      # Validate secrets first
      validatedCluster = validateSecrets clusterName cluster;
      nodeConfig = buildNodeConfig clusterName memberName member;
      nodeName = "${clusterName}-${memberName}";

      # Determine if this is the first server
      isFirstServer =
        member.role == "server" &&
        memberName == (cluster.ha.firstServer or
          # If no firstServer specified, find first server alphabetically
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
        # Disko module
        inputs.disko.nixosModules.disko

        # Base system modules (auto-discovered by import-tree)
      ] ++ nixosModules
      # User modules from node template
      ++ (nodeConfig.nixosModules or [ ])
      # Extension modules (from nixosModulesFor)
      ++ (cfg.nixosModulesFor.${nodeName} or [ ]);
    };

  # Generate all nixosConfigurations for all clusters
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
