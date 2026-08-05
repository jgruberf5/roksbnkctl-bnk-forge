# These outputs are the handoff to the rest of the disconnected chain: the mirror
# blueprint pushes to registry_host, the BNK install pulls from it, and the FLP
# blueprint lands its appliance in vpc_id.

output "registry_host" {
  description = "Harbor's PRIVATE IP — the address the cluster's nodes and the runner use over the Transit Gateway. This, not the floating IP, is what goes in the mirror/install forms."
  value       = ibm_is_subnet_reserved_ip.harbor.address
}

output "registry_url" {
  description = "Harbor's browser URL on the operator floating IP."
  value       = "https://${ibm_is_floating_ip.harbor.address}/"
}

output "floating_ip" {
  description = "Operator floating IP attached to the Harbor VSI."
  value       = ibm_is_floating_ip.harbor.address
}

output "vpc_id" {
  description = "Services VPC id — feed this to the FLP-VSI blueprint so the licensing appliance lands in the same VPC."
  value       = local.vpc_id
}

output "subnet_id" {
  description = "Services subnet id."
  value       = local.subnet_id
}

output "instance_id" {
  description = "Harbor VSI instance id."
  value       = ibm_is_instance.harbor.id
}

output "ssh_target" {
  description = "SSH target for fetching the CA (base64 at /opt/harbor/harbor-ca.b64) or inspecting the install."
  value       = "ubuntu@${ibm_is_floating_ip.harbor.address}"
}

output "transit_gateway_connection" {
  description = "The Transit Gateway connection created for the services VPC, when one was requested."
  value       = var.transit_gateway != "" ? ibm_tg_connection.services[0].name : ""
}

# ── trust material ───────────────────────────────────────────────────────────
# These are what make an automatic mirror possible. The far-mirror module declares
# them `source: module` against this one, so Forge wires them in directly and the
# operator never handles the CA. Before the certificate was terraform-owned neither
# could exist: the CA was minted on the VSI and only reachable over SSH.
output "registry_ca_b64" {
  description = "Base64-encoded PEM of Harbor's self-signed CA (roksbnkctl's registry.generic_ca_b64 / ROKSBNKCTL_GENERIC_CA_B64)."
  value       = base64encode(tls_self_signed_cert.harbor.cert_pem)
}

# Deliberately no registry_ca_sha256 output. The pin exists to authenticate a CA
# CAPTURED off the wire when the CA itself is not configured (workspace.go: "it
# authenticates a CA captured from the host when GenericCAB64 is not set"). Wiring
# the CA above makes it redundant. terraform also has no x509 DER function, and the
# pin is the SHA-256 of the DER, not of the PEM text — sha256(cert_pem) would look
# plausible, match nothing, and fail closed at replicate time.
