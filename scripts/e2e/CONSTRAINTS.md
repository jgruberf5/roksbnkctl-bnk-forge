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
Variant 2 hit this twice: first because `fdisco` (variant 4's cluster) was still
attached to `bnkci-testing`, and later — after per-cluster CIDRs were added to
fix exactly that — because the CIDR chosen to fix it collided with a VPC nobody
had thought to check.

**Rule: every cluster's `cluster_vpc_cidr` must be distinct from EVERY OTHER VPC
on the gateway — including VPCs nobody on this project created.** Comparing the
clusters only against each other is not enough, and that mistake cost a full
63-minute install: variant 2 was given `10.242.0.0/16`, which collides exactly
with `app-eu-gb-1`, the VPC the BNK Forge host itself runs in.

IBM carves a `/16` into three `/18`s, one per zone, so `10.242.0.0/16` becomes
`10.242.0.0/18` + `10.242.64.0/18` + `10.242.128.0/18` — byte-for-byte what
`app-eu-gb-1` already advertises. Zones do not disambiguate: eu-gb-1 and
us-east-1 claiming the same prefix is still a collision.

Ranges already taken on `bnkci-testing`:

| Range | Owner |
|---|---|
| `10.242.0.0/16` (all three /18s) | `app-eu-gb-1` — the BNK Forge host's VPC |
| `10.243.0.0/24`, `10.243.1.0/24` | `bnk-svc-vpc` — Harbor and the FLP |
| `10.241.0.0/16` | what IBM's `auto` hands out — assume any un-pinned VPC has it |

`10.241.0.0/16` reproduces the `auto` prefixes byte-for-byte, so the first
cluster can adopt it without changing any addresses. Give the second something
clear of the table above, e.g. `10.245.0.0/16`.

**Check before you deploy**, rather than diagnosing it afterwards:

    ibmcloud tg connections <gateway-id>          # every VPC on the gateway
    ibmcloud is vpc-address-prefixes <vpc-id>     # what each one advertises

The symptom is not a clean failure. Pulls succeed and time out at random on
*every* node — a probe from one host measured 21 OK / 9 timed out against the
same address in one run — so it reads as a flaky network or an overloaded
registry rather than a routing conflict.

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
