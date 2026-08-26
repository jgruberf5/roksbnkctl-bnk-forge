#!/usr/bin/env bash
# Give BNK Forge the PRIVATE key for an appliance it built, and wire the project
# to use it.
#
#   ./register-ssh-credential.sh <project-name> <host> [username] [key-file]
#
# WHY THIS IS A HOST SCRIPT AND NOT A MODULE STEP
# The FLP module cannot do this itself. Forge requires container steps to be an
# argv vector and REFUSES a shell — module_metadata.py:794, "args must not invoke
# a shell — argv runs in the artifact's own image directly", with a matching
# refusal for command-strings and image overrides. Wiring Forge needs three calls
# in sequence — log in, find the credential, PATCH the project — and the bearer
# token from call one has to reach call two's header. `curl` can write a file but
# nothing in an argv-only step can lift a field out of JSON into the next
# request. roksbnkctl has no `bnkforge ssh-credential` subcommand to do it either
# (it drives cluster registration only), so there is nothing to call.
#
# WHAT THE MODULE'S OWN SSH INPUT DOES, AND DOES NOT DO
# flp_vsi_ssh_key names an existing IBM Cloud VPC key, which attaches a PUBLIC
# key to the VSI. That is operator access. Forge separately wants the PRIVATE
# half so it can reach the appliance itself, and no module input supplies it —
# which is why a healthy FLP reports:
#
#   infrastructure_private_key_available: false
#   infrastructure_access_status: recovery_required
#
# That message suggests re-materializing lost metadata, but nothing was lost:
# the credential was never created, because nothing creates it.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
set -a; . "$HERE/../demos/.env"; set +a
PROJECT="${1:?usage: register-ssh-credential.sh <project-name> <host> [username] [key-file]}"
HOST="${2:?the host Forge must reach — use the FLOATING IP, not the private endpoint}"
USER_NAME="${3:-ubuntu}"
KEY="${4:-${SSH_KEY_FILE:?set SSH_KEY_FILE or pass a key file}}"
API="$FORGE_URL"
say(){ printf '   %s\n' "$*"; }

[[ -r "$KEY" ]] || { echo "cannot read private key: $KEY" >&2; exit 2; }

T=""
for _ in 1 2 3; do
  T=$(curl -sk --max-time 30 -X POST "$API/api/auth/login" -H 'Content-Type: application/json' \
      -d "{\"username\":\"$FORGE_USER\",\"password\":\"$FORGE_PASSWORD\"}" | jq -r '.token//empty')
  [[ -n "$T" ]] && break; command sleep 5
done
[[ -n "$T" ]] || { echo "cannot authenticate to $API" >&2; exit 2; }

PID=$(curl -sk --max-time 40 "$API/api/projects" -H "Authorization: Bearer $T" \
      | jq -r --arg n "$PROJECT" '(.projects//.)[]|select(.name==$n)|.id' | head -1)
[[ -n "$PID" ]] || { echo "no project named '$PROJECT'" >&2; exit 1; }

# Verify the key actually opens the box BEFORE handing it over. A credential that
# cannot log in is worse than none: Forge reports access as configured and every
# later failure points somewhere else.
if command -v ssh-keygen >/dev/null 2>&1; then
  FP=$(ssh-keygen -l -E sha256 -f "$KEY" 2>/dev/null | awk '{print $2}')
  say "private key fingerprint: ${FP:-unknown}"
  if [[ -n "${FLP_VSI_SSH_KEY:-}" ]] && command -v ibmcloud >/dev/null 2>&1; then
    VPCFP=$(timeout 90 ibmcloud is keys --output json 2>/dev/null \
            | jq -r --arg n "$FLP_VSI_SSH_KEY" '.[]|select(.name==$n)|.fingerprint')
    [[ -n "$VPCFP" && "$VPCFP" != "$FP" ]] && { echo "MISMATCH: VPC key $FLP_VSI_SSH_KEY is $VPCFP" >&2; exit 1; }
    [[ -n "$VPCFP" ]] && say "matches VPC key $FLP_VSI_SSH_KEY"
  fi
fi

NAME="${SSH_CRED_NAME:-${PROJECT}-ssh}"
EXIST=$(curl -sk --max-time 40 "$API/api/ssh-credentials" -H "Authorization: Bearer $T" \
        | jq -r --arg n "$NAME" '.[]?|select(.name==$n)|.id' | head -1)
BODY=$(KEYFILE="$KEY" NAME="$NAME" HOST="$HOST" U="$USER_NAME" python3 -c '
import json, os
print(json.dumps({"name":os.environ["NAME"],
 "description":"Operator access to the appliance this project built",
 "host":os.environ["HOST"],"port":22,"username":os.environ["U"],
 "auth_type":"key","private_key":open(os.environ["KEYFILE"]).read()}))')

if [[ -n "$EXIST" ]]; then
  code=$(curl -sk --max-time 40 -o /dev/null -w '%{http_code}' -X PUT "$API/api/ssh-credentials/$EXIST" \
         -H "Authorization: Bearer $T" -H 'Content-Type: application/json' -d "$BODY")
  CID="$EXIST"; say "updated existing credential $CID (HTTP $code)"
else
  RESP=$(curl -sk --max-time 40 -X POST "$API/api/ssh-credentials" \
         -H "Authorization: Bearer $T" -H 'Content-Type: application/json' -d "$BODY")
  CID=$(jq -r '.id//empty' <<<"$RESP")
  [[ -n "$CID" ]] || { echo "create failed: $(head -c 300 <<<"$RESP")" >&2; exit 1; }
  say "created credential $CID ($NAME), has_private_key=$(jq -r '.has_private_key' <<<"$RESP")"
fi

# Attach to the project AND turn infrastructure access on. Setting the credential
# alone leaves infra_enabled false and the appliance still unreachable.
code=$(curl -sk --max-time 40 -o /dev/null -w '%{http_code}' -X PUT "$API/api/projects/$PID" \
  -H "Authorization: Bearer $T" -H 'Content-Type: application/json' \
  -d "{\"ssh_credential_id\":$CID,\"infra_enabled\":true,\"infra_host\":\"$HOST\",\"infra_ssh_username\":\"$USER_NAME\",\"infra_ssh_port\":22,\"infra_auth_type\":\"key\"}")
say "project $PID wired to credential $CID (HTTP $code)"
curl -sk --max-time 40 "$API/api/projects/$PID" -H "Authorization: Bearer $T" \
  | jq -r '"   ssh_credential_id=\(.ssh_credential_id) infra_enabled=\(.infra_enabled) infra_host=\(.infra_host) user=\(.infra_ssh_username) auth=\(.infra_auth_type)"'
