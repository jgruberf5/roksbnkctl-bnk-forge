# Sequencing constraints for the four variants

## One roksbnkctl-created cluster VPC per Transit Gateway

> **Resolved in roksbnkctl v1.39.0 / v1.40.2.** `cluster.vpc_cidr`
> (`ROKSBNKCTL_CLUSTER_VPC_CIDR`) lets each cluster own its address block, and
> `cluster up` / `tgw connect` now refuse an overlap up front instead of building
> one. `roks-new-cluster-disconnected` requires the input for exactly this
> reason. What follows is why it matters and how it presents when unset — the
> default is still IBM's `auto`, so an unset value reproduces the collision.

roksbnkctl assigns the SAME default address prefixes to every cluster VPC it
creates: `10.241.0.0/18`, `10.241.64.0/18`, `10.241.128.0/18`. Two such VPCs
attached to one Transit Gateway therefore overlap, and the gateway cannot route
to both — traffic is ambiguous and silently blackholed.

It does not present as a routing error. It presents as intermittent image pulls:

    Failed to pull image "10.243.0.4/bnk-mirror/...":
      dial tcp 10.243.0.4:443: connect: connection timed out

Some pulls succeed, some time out, and every security group and network ACL in
the path allows the traffic — which sends you looking at firewalls for an hour.
Variant 2 hit this because `fdisco` (variant 4's cluster) was still attached to
`bnkci-testing` when variant 2's new cluster joined it.

**Rule: give every cluster that shares a gateway a distinct `cluster_vpc_cidr`.**
`10.241.0.0/16` reproduces the current `auto` prefixes byte-for-byte, so the
first cluster can adopt it without changing any addresses; give the second
something else, e.g. `10.242.0.0/16`.

If two overlapping clusters already exist, detaching one is enough — destroying
it is not required. Tearing down the Forge project runs `cluster-registry`'s
`tgw disconnect`, which detaches it.

## Consequences for E2E ordering

* The two DISCONNECTED variants share `bnkci-testing` (they must, to reach the
  mirror). With distinct `cluster_vpc_cidr` values they can now coexist; without
  them they cannot.
* The two CONNECTED variants are unaffected: variant 1 creates its own gateway,
  and variant 3 adopts whichever cluster already exists.
* Variant 3 and variant 4 need a PRE-EXISTING cluster. Reuse the cluster the
  preceding variant built, removing BNK with `roksbnkctl bnk down` from a host
  workspace — NOT by destroying the Forge module, which cascades into the
  cluster module and destroys the cluster with it.

## Transit Gateway quota

The account ceiling is 10 and 9 are in use by other work. Only variant 1 creates
a gateway, and it returns it on teardown, so the sequence never needs an 11th.
