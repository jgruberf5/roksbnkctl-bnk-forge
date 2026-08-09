#!/usr/bin/env bash
# Remove f5e2e5 — a cluster with no Forge project and no roksbnkctl workspace.
#
# It exists because Forge dispatched `bnk-install` on a module that was explicitly
# disabled, and neither `cancel` nor deleting the project stopped the container
# (bnk-forge #527 / #462). The project was removed while the install was still
# running, so nothing in Forge represents this infrastructure any more and neither
# `destroy-all` nor `roksbnkctl down` can reach it. It has to go by hand.
#
# Order: cluster, then the gateway attachment, then the gateway, then the VPC's
# public gateways, subnets and finally the VPC itself.
set -uo pipefail
say() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
NAME=f5e2e5

say "== deleting cluster $NAME"
if timeout 120 ibmcloud ks cluster get --cluster "$NAME" >/dev/null 2>&1; then
  timeout 180 ibmcloud ks cluster rm --cluster "$NAME" --force-delete-storage -f 2>&1 | tail -2
  for i in $(seq 1 90); do
    timeout 60 ibmcloud ks cluster get --cluster "$NAME" >/dev/null 2>&1 || { say "   cluster gone"; break; }
    sleep 20
  done
else
  say "   cluster already absent"
fi

GW=$(timeout 60 ibmcloud tg gateways --output json 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin); r=d if isinstance(d,list) else d.get('transit_gateways',[])
print(next((g['id'] for g in r if g.get('name')=='$NAME-tgw'),''))")
if [[ -n "$GW" ]]; then
  say "== detaching + deleting gateway $NAME-tgw ($GW)"
  for CID in $(timeout 60 ibmcloud tg connections "$GW" --output json 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin); r=d if isinstance(d,list) else d.get('connections',[])
print(' '.join(c['id'] for c in r))"); do
    timeout 120 ibmcloud tg connection-delete "$GW" "$CID" --force 2>&1 | tail -1
  done
  for i in $(seq 1 30); do
    n=$(timeout 60 ibmcloud tg connections "$GW" --output json 2>/dev/null | python3 -c "
import sys,json;d=json.load(sys.stdin);r=d if isinstance(d,list) else d.get('connections',[]);print(len(r))")
    [[ "$n" == "0" ]] && break; sleep 10
  done
  timeout 120 ibmcloud tg gateway-delete "$GW" --force 2>&1 | tail -1
else
  say "== gateway $NAME-tgw already absent"
fi

VID=$(timeout 60 ibmcloud is vpcs --output json 2>/dev/null | python3 -c "
import sys,json;print(next((v['id'] for v in json.load(sys.stdin) if v['name']=='$NAME-cluster-vpc'),''))")
if [[ -n "$VID" ]]; then
  say "== deleting VPC $NAME-cluster-vpc ($VID)"
  # Subnets must go before their public gateways, and both before the VPC. Doing
  # the gateways first fails silently while they are still attached to a subnet,
  # which is how an earlier cleanup left three of them behind and the VPC delete
  # then failed with vpc_in_use.
  for S in $(timeout 60 ibmcloud is subnets --output json 2>/dev/null | python3 -c "
import sys,json;print(' '.join(s['id'] for s in json.load(sys.stdin) if (s.get('vpc') or {}).get('id')=='$VID'))"); do
    say "   subnet $S"; timeout 120 ibmcloud is subnet-delete "$S" --force 2>&1 | grep -E "OK|FAILED" | head -1
  done
  for i in $(seq 1 60); do
    n=$(timeout 60 ibmcloud is subnets --output json 2>/dev/null | python3 -c "
import sys,json;print(sum(1 for s in json.load(sys.stdin) if (s.get('vpc') or {}).get('id')=='$VID'))")
    [[ "$n" == "0" ]] && break; sleep 10
  done
  for G in $(timeout 60 ibmcloud is public-gateways --output json 2>/dev/null | python3 -c "
import sys,json;print(' '.join(g['id'] for g in json.load(sys.stdin) if (g.get('vpc') or {}).get('id')=='$VID'))"); do
    say "   public gateway $G"; timeout 120 ibmcloud is public-gateway-delete "$G" --force 2>&1 | grep -E "OK|FAILED" | head -1
  done
  sleep 10
  say "   vpc"; timeout 180 ibmcloud is vpc-delete "$VID" --force 2>&1 | grep -E "OK|FAILED|Error message" | head -2
else
  say "== VPC $NAME-cluster-vpc already absent"
fi
say "DONE"
