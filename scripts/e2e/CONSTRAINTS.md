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
* Variant 3 and variant 4 need a PRE-EXISTING cluster **with no BNK on it**.
  Handing them the preceding variant's cluster does not work — see below. Build
  one with `make-bare-cluster.sh` instead.

## Variants 3 and 4 need a BNK-FREE cluster, and `run-all.sh` never made one

`run-all.sh` runs v3 straight after v1 (and v4 after v2), on the cluster that
variant just built — a cluster that already has BNK installed. That cannot work,
and it is why neither variant had ever been run to completion.

> **Improved in roksbnkctl v1.42.0 (#53), but not removed.** `bnk up` now refuses
> **before planning** when the cluster is serving an install this workspace's state
> does not own, naming the cluster and the namespace. That turns the 13-minute
> opaque failure below into a fast, clear one. It is deliberately *not* a recovery:
> a full `bnk adopt` was left out of that release, so v3 and v4 still need a cluster
> with **no BNK on it**. Build one with `make-bare-cluster.sh`.

The adopting project gets its own deployment-scoped `/work`, so its terraform
state is **empty**. Before v1.42.0 `bnk up` therefore planned a full install — 64
resources — onto a cluster where all of it already existed, ran for ~13 minutes and
exited 1. Confirmed on both variants, 2026-08-08:

    v3: module 150 apply_failed   (deployment 313, 804s, exit 1, resources_to_add=64)
    v4: module 153 apply_failed   error: step 'bnk-up' failed (exit 1, after 3 attempts)

**And BNK cannot be removed from the cluster afterwards.** Destroying the
`bnk-install` module cascades into `cluster-create` and destroys the cluster with
it — the cascade is real, just not immediate. Measured: module 145 went
`destroying` → `destroyed`, and only then did module 144 go `destroying`, with
the cluster moving to `state=deleting`. Watching only the first module for a
minute makes it look like nothing cascaded.

`roksbnkctl bnk down` from a host workspace is not an escape hatch either. The
Forge container module owns roksbnkctl's state inside its `/work` volume, so a
workspace on the operator host has never seen the install: `bnk status` reports
`bnk: not deployed`, and `bnk down` is documented to exit 0 "nothing to do" when
there is no trial state. It is a silent no-op.

So the precondition has to be a cluster that never had BNK installed — the one the
demo script already states in its own prereqs: "an EXISTING ROKS cluster with BNK
not installed".

### Forge cannot build one — use the CLI

`make-bare-cluster.sh` deploys a NEW-cluster blueprint and dispatches only
`cluster-create`. **That is not sufficient, and the script now says so.** Forge's
dependency graph dispatches `bnk-install` the moment `cluster-create` finishes —
even with the module explicitly `enabled:false` — and neither `cancel` nor
deleting the project stops the container once it is running
(BNK Forge issues #527 and #462). Measured 2026-08-08: project 99's `bnk-install`
started by itself at 14:47 and collided with the v3 run's own `bnk-install` on the
**same cluster**, which invalidated that test entirely.

The script therefore asserts after `cluster-create` that no downstream module ran,
and fails loudly rather than handing over a contaminated cluster:

    ✗ module 166 is 'applying' — it was dispatched despite being disabled; the cluster is NOT bare

**Build the cluster outside Forge instead.** It is both reliable and more faithful:
a real customer's existing cluster was never in Forge either.

    export ROKSBNKCTL_PREFIX=f5e2e6 ROKSBNKCTL_CLUSTER_NAME=f5e2e6
    export ROKSBNKCTL_CLUSTER_CREATE=true ROKSBNKCTL_CLUSTER_PUBLIC_GATEWAY=true
    export ROKSBNKCTL_CLUSTER_VPC_CIDR=10.248.0.0/16
    export ROKSBNKCTL_TRANSIT_GATEWAY_NAME="$TRANSIT_GATEWAY"
    roksbnkctl -w uc3src init --override-from-env --non-interactive
    roksbnkctl -w uc3src cluster up --auto        # no bnk phase is ever run

Set `ROKSBNKCTL_CLUSTER_PUBLIC_GATEWAY=false` for the disconnected variant.
Adopting an existing gateway rather than creating one also avoids spending a
Transit Gateway from the account's quota of 10.

## Hand the cluster over by releasing its Forge REGISTRATION, not by `bnk down`

Two things that look like the handover step, and are not:

**`roksbnkctl bnk down` from a host workspace does nothing.** The Forge container
module owns roksbnkctl's state inside its deployment-scoped `/work` volume, so a
workspace on the operator host has never seen the install. `bnk status` there
reports `bnk: not deployed`, and `bnk down` is documented to exit 0 "nothing to
do" when there is no trial state. It is a silent no-op, not a teardown.

> **Fixed in roksbnkctl v1.42.0 (#54).** `bnkforge register` now updates in place
> and preserves the cluster id, and **refuses** a cluster held by another project,
> naming the owner, instead of silently moving it or failing with a bare exit 1.
> `--force` performs a real move. Automatic registration inside `cluster up` /
> `bnk up` never forces. The release step below is still the right thing to do —
> the difference is that skipping it now produces a clear refusal rather than the
> opaque failure recorded here.

**Leaving BNK installed is fine; leaving the REGISTRATION is not.** What actually
blocks the next variant is that the cluster is still registered to the previous
variant's Forge project. Before v1.42.0, `roksbnkctl bnkforge register` DELETEd the
cluster and re-POSTed it, so registering the same cluster into a second project
collided and the step failed:

    module 149: apply_failed
    error: step 'bnkforge-register' failed (exit 1)

`cluster-registry` fails there, and with it the whole variant. This is why
variant 3 had a blueprint that had never once been run to completion —
`run-all.sh` runs v3 directly after v1, on v1's cluster, with v1's project still
holding the registration.

**Before running v3 or v4 against the preceding variant's cluster**, release it:

    curl -sk -X DELETE "$FORGE_URL/api/k8s/clusters/<id>" -H "Authorization: Bearer $TOKEN"
    # find <id> with: GET /api/k8s/clusters   (note: /api/clusters is a 404)

Verified on 2026-08-08: module 149 went `apply_failed` → `applied` on re-apply
with no other change.

Note this does NOT apply to a real customer deployment, where an existing cluster
was never registered to another project. It is a constraint of reusing one
cluster across variants.

## The e2e harness does not resume

`e2e_deploy` always creates a new project — unlike the demo script's `deploy()`,
which adopts `$STATE/<tag>.project` and re-applies the first incomplete module.
So re-running a variant after a mid-run failure leaves the failed project behind
and builds a second one. Drive the existing project's modules directly, or delete
the orphan first.

## Transit Gateway quota

The account ceiling is 10 and 9 are in use by other work. Only variant 1 creates
a gateway, and it returns it on teardown, so the sequence never needs an 11th.

## The reachability gate races Transit Gateway route propagation

A Transit Gateway attachment is asynchronous: IBM programs the routes some time
after the connection reports `attached`. `bnk up`'s preflight probe runs on the
registry-trust DaemonSet, and on a fresh attachment it can run before the routes
exist. Measured on variant 4, 2026-08-08:

    TGW connection created      14:49:20
    DaemonSet created + probed  14:50:33   <-- 73s later, both targets FAILED
    bnk up gives up             15:01:54
    same node, re-probed        ~15:22     <-- both tcp=ok

Nothing changed but elapsed time. A sibling cluster on the same gateway passed
simply by landing on the other side of route programming.

> **Fixed in roksbnkctl v1.42.0 (#57).** Each target is now retried until its
> budget is spent, and the DaemonSet is rolled on every run so a stale verdict can
> never be re-read. A failure now reports how hard it tried
> (`still failing after 19 attempts over 180s`), which is what distinguishes a race
> from a real break.

**Raise the budget whenever the gateway is attached in the same run as the
install** — which is exactly `roks-new-cluster-disconnected`, where
`cluster-create` attaches and `bnk-install` probes minutes later. That blueprint
ships raised defaults:

| Input | Env var | Blueprint default | Tool default |
|---|---|---|---|
| `reachability_retry_seconds` | `ROKSBNKCTL_REACHABILITY_RETRY_SECONDS` | **600** | 180 |
| `reachability_timeout_seconds` | `ROKSBNKCTL_REACHABILITY_TIMEOUT_SECONDS` | **900** | 480 |

`roks-disconnected` leaves both blank — an adopted cluster is normally already on
the gateway. Raise them there too if `cluster register` has to attach the VPC.
`0` is a real answer, not "unset": it means one shot, for a static environment
where a failure is never a race.

Before v1.42.0 the only recovery was to restart the DaemonSet by hand and re-apply:

    kubectl -n roksbnkctl-registry-trust rollout restart ds/registry-ca-installer
