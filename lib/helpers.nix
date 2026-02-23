# Helper functions for nix8s
{ lib }:

{
  # Safe attribute access with default value
  # getOr default ["path" "to" "attr"] attrs
  getOr = default: path: attrs:
    lib.attrByPath path default attrs;

  # Filter cluster members by role
  filterMembers = role: members:
    lib.filterAttrs (_: m: m.role == role) members;

  # Get all server members
  getServers = members:
    lib.filterAttrs (_: m: m.role == "server") members;

  # Get all agent members
  getAgents = members:
    lib.filterAttrs (_: m: m.role == "agent") members;

  # Get list of IPs for members matching role
  getMemberIPs = role: members:
    lib.mapAttrsToList (_: m: m.ip)
      (lib.filterAttrs (_: m: m.role == role) members);

  # Get all server IPs
  getServerIPs = members:
    lib.mapAttrsToList (_: m: m.ip)
      (lib.filterAttrs (_: m: m.role == "server") members);

  # Get first server name (alphabetically or from ha.firstServer)
  getFirstServerName = cluster:
    cluster.ha.firstServer or
      (lib.head (lib.sort (a: b: a < b)
        (lib.attrNames (lib.filterAttrs (_: m: m.role == "server") cluster.members))));

  # Check if member is first server
  isFirstServer = cluster: memberName:
    let
      firstServer = cluster.ha.firstServer or
        (lib.head (lib.sort (a: b: a < b)
          (lib.attrNames (lib.filterAttrs (_: m: m.role == "server") cluster.members))));
    in
    memberName == firstServer;

  # Generate full node name from cluster and member
  mkNodeName = clusterName: memberName:
    "${clusterName}-${memberName}";

  # Sort members for provisioning order:
  # 1. First server
  # 2. Other servers (alphabetically)
  # 3. Agents (alphabetically)
  sortMembersForProvisioning = cluster:
    let
      members = cluster.members;
      firstServerName = cluster.ha.firstServer or
        (lib.head (lib.sort (a: b: a < b)
          (lib.attrNames (lib.filterAttrs (_: m: m.role == "server") members))));
      servers = lib.filterAttrs (_: m: m.role == "server") members;
      agents = lib.filterAttrs (_: m: m.role == "agent") members;
      otherServerNames = lib.filter (n: n != firstServerName) (lib.attrNames servers);
      agentNames = lib.sort (a: b: a < b) (lib.attrNames agents);
    in
    [ firstServerName ]
    ++ (lib.sort (a: b: a < b) otherServerNames)
    ++ agentNames;
}
