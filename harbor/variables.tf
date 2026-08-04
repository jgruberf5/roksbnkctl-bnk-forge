variable "region" {
  description = "IBM Cloud region the services VPC and the Harbor VSI live in."
  type        = string
}

variable "resource_group" {
  description = "IBM Cloud resource group name."
  type        = string
  default     = "default"
}

variable "prefix" {
  description = "Prefix for every resource this module names (e.g. acme-svc)."
  type        = string
}

variable "zone" {
  description = "Zone for the subnet and the VSI. Empty = <region>-1."
  type        = string
  default     = ""
}

# ── Network: create the services VPC, or adopt one ───────────────────────────
variable "create_vpc" {
  description = "true = create the services VPC + subnet + public gateway. false = use existing_vpc_id / existing_subnet_id."
  type        = bool
  default     = true
}

variable "existing_vpc_id" {
  description = "Existing services VPC id (when create_vpc = false)."
  type        = string
  default     = ""
}

variable "existing_subnet_id" {
  description = "Existing subnet id (when create_vpc = false)."
  type        = string
  default     = ""
}

variable "subnet_cidr" {
  description = "CIDR for the services subnet when this module creates it."
  type        = string
  default     = "10.241.0.0/24"
}

# The services VPC is the ONLY side with egress in the disconnected topology: Harbor
# pulls from F5's registry and the FLP reaches F5 licensing. The cluster VPC has none.
variable "public_gateway" {
  description = "Attach a public gateway to the services subnet. Harbor needs egress to pull from FAR."
  type        = bool
  default     = true
}

# ── Transit Gateway ──────────────────────────────────────────────────────────
variable "transit_gateway" {
  description = "Name or id of an EXISTING Transit Gateway to attach the services VPC to, so the air-gapped cluster reaches Harbor privately. Empty = no attachment."
  type        = string
  default     = ""
}

# ── The Harbor VSI ───────────────────────────────────────────────────────────
variable "vsi_profile" {
  description = "IBM Cloud instance profile for the Harbor VSI."
  type        = string
  default     = "bx2-4x16"
}

variable "vsi_image" {
  description = "Stock image name for the Harbor VSI."
  type        = string
  default     = "ibm-ubuntu-24-04-4-minimal-amd64-6"
}

variable "ssh_key_name" {
  description = "Name of an existing IBM Cloud VPC SSH key to attach, for operator access."
  type        = string
}

variable "harbor_version" {
  description = "Harbor release to install (the offline installer tag)."
  type        = string
  default     = "v2.11.1"
}

variable "harbor_admin_password" {
  description = "Harbor admin password. Also the credential the mirror blueprint pushes and pulls with."
  type        = string
  sensitive   = true
}

variable "boot_size_gb" {
  description = "Boot volume size. Harbor's offline installer plus a full BNK mirror needs room."
  type        = number
  default     = 250
}

variable "management_allowed_cidrs" {
  description = "Comma-separated CIDRs allowed to reach Harbor's :443 and :22 on the floating IP. Empty = 0.0.0.0/0 (scope it down in production)."
  type        = string
  default     = ""
}

variable "registry_allowed_cidrs" {
  description = "Comma-separated CIDRs allowed to reach Harbor's :443 over the PRIVATE path — the cluster's VPC over the Transit Gateway. Empty = the RFC-1918 ranges."
  type        = string
  default     = ""
}
