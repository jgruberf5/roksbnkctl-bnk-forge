locals {
  zone = var.zone != "" ? var.zone : "${var.region}-1"
  name = var.prefix

  # Comma-separated form inputs -> lists, empties dropped so a trailing comma never
  # renders a bogus "" CIDR into a security-group rule.
  mgmt_cidrs = length(compact(split(",", replace(var.management_allowed_cidrs, " ", "")))) > 0 ? compact(split(",", replace(var.management_allowed_cidrs, " ", ""))) : ["0.0.0.0/0"]
  reg_cidrs  = length(compact(split(",", replace(var.registry_allowed_cidrs, " ", "")))) > 0 ? compact(split(",", replace(var.registry_allowed_cidrs, " ", ""))) : ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
}

data "ibm_resource_group" "rg" {
  name = var.resource_group
}

data "ibm_is_ssh_key" "operator" {
  name = var.ssh_key_name
}

data "ibm_is_image" "vsi" {
  name = var.vsi_image
}

# ── Services VPC (created, or adopted) ───────────────────────────────────────
# MANUAL address prefixes, not "auto". Auto assigns IBM's per-zone defaults
# (us-east: 10.241.0.0/18, 10.241.64.0/18, 10.241.128.0/18), which constrains
# subnet_cidr to those ranges — and, more importantly, makes the VPC advertise
# the whole /18 over a Transit Gateway. A roksbnkctl cluster VPC uses those same
# defaults, so two auto-prefixed VPCs on one gateway collide no matter how the
# subnets inside them are carved up. Declaring exactly one prefix means this VPC
# advertises only what it actually uses.
resource "ibm_is_vpc" "services" {
  count                     = var.create_vpc ? 1 : 0
  name                      = "${local.name}-services-vpc"
  resource_group            = data.ibm_resource_group.rg.id
  address_prefix_management = "manual"
}

resource "ibm_is_vpc_address_prefix" "services" {
  count = var.create_vpc ? 1 : 0
  name  = "${local.name}-services-prefix"
  vpc   = ibm_is_vpc.services[0].id
  zone  = local.zone
  cidr  = var.subnet_cidr
}

# Harbor is the only component that needs egress — it pulls the BNK supply chain
# from F5's registry. The cluster side stays private.
resource "ibm_is_public_gateway" "services" {
  count          = var.create_vpc && var.public_gateway ? 1 : 0
  name           = "${local.name}-services-pgw"
  vpc            = ibm_is_vpc.services[0].id
  zone           = local.zone
  resource_group = data.ibm_resource_group.rg.id
}

resource "ibm_is_subnet" "services" {
  count           = var.create_vpc ? 1 : 0
  depends_on      = [ibm_is_vpc_address_prefix.services]
  name            = "${local.name}-services-subnet"
  vpc             = ibm_is_vpc.services[0].id
  zone            = local.zone
  ipv4_cidr_block = var.subnet_cidr
  resource_group  = data.ibm_resource_group.rg.id
  public_gateway  = var.public_gateway ? ibm_is_public_gateway.services[0].id : null
}

locals {
  vpc_id    = var.create_vpc ? ibm_is_vpc.services[0].id : var.existing_vpc_id
  subnet_id = var.create_vpc ? ibm_is_subnet.services[0].id : var.existing_subnet_id
}

# ── Transit Gateway attachment ───────────────────────────────────────────────
# The air-gapped cluster reaches Harbor over an EXISTING gateway. Resolving by name
# OR id keeps the blueprint form forgiving; an ambiguous name is a user error the
# lookup surfaces rather than silently picking one.
data "ibm_tg_gateways" "all" {
  count = var.transit_gateway != "" ? 1 : 0
}

locals {
  tgw_matches = var.transit_gateway == "" ? [] : [
    for g in data.ibm_tg_gateways.all[0].transit_gateways :
    g.id if g.name == var.transit_gateway || g.id == var.transit_gateway
  ]
  tgw_id = length(local.tgw_matches) > 0 ? local.tgw_matches[0] : ""
}

resource "ibm_tg_connection" "services" {
  count        = var.transit_gateway != "" ? 1 : 0
  gateway      = local.tgw_id
  network_type = "vpc"
  name         = "${local.name}-services"
  network_id   = var.create_vpc ? ibm_is_vpc.services[0].crn : data.ibm_is_vpc.adopted[0].crn
}

data "ibm_is_vpc" "adopted" {
  count      = var.create_vpc ? 0 : 1
  identifier = var.existing_vpc_id
}

# ── Security group ───────────────────────────────────────────────────────────
resource "ibm_is_security_group" "harbor" {
  name           = "${local.name}-harbor-sg"
  vpc            = local.vpc_id
  resource_group = data.ibm_resource_group.rg.id
}

resource "ibm_is_security_group_rule" "egress" {
  group     = ibm_is_security_group.harbor.id
  direction = "outbound"
  remote    = "0.0.0.0/0"
}

# :443 from the operator's side (the floating IP path — Harbor's UI and the
# operator's pushes).
resource "ibm_is_security_group_rule" "https_mgmt" {
  count     = length(local.mgmt_cidrs)
  group     = ibm_is_security_group.harbor.id
  direction = "inbound"
  remote    = local.mgmt_cidrs[count.index]
  protocol  = "tcp"
  port_min  = 443
  port_max  = 443
}

# :443 from the private side — the cluster's workers pulling images over the TGW.
resource "ibm_is_security_group_rule" "https_private" {
  count     = length(local.reg_cidrs)
  group     = ibm_is_security_group.harbor.id
  direction = "inbound"
  remote    = local.reg_cidrs[count.index]
  protocol  = "tcp"
  port_min  = 443
  port_max  = 443
}

resource "ibm_is_security_group_rule" "ssh" {
  count     = length(local.mgmt_cidrs)
  group     = ibm_is_security_group.harbor.id
  direction = "inbound"
  remote    = local.mgmt_cidrs[count.index]
  protocol  = "tcp"
  port_min  = 22
  port_max  = 22
}

# ── Floating IP, reserved BEFORE the VSI ─────────────────────────────────────
# cloud-init bakes the floating IP into Harbor's TLS SAN, so the address must exist
# before the instance is created. Reserving by zone (rather than by target) is what
# breaks the dependency cycle: a target-bound floating IP would depend on the
# instance that depends on the address.
resource "ibm_is_floating_ip" "harbor" {
  name           = "${local.name}-harbor-fip"
  zone           = local.zone
  resource_group = data.ibm_resource_group.rg.id
}

resource "ibm_is_instance" "harbor" {
  name           = "${local.name}-harbor"
  vpc            = local.vpc_id
  zone           = local.zone
  profile        = var.vsi_profile
  image          = data.ibm_is_image.vsi.id
  keys           = [data.ibm_is_ssh_key.operator.id]
  resource_group = data.ibm_resource_group.rg.id

  primary_network_interface {
    subnet          = local.subnet_id
    security_groups = [ibm_is_security_group.harbor.id]
  }

  boot_volume {
    size = var.boot_size_gb
  }

  user_data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    harbor_fip            = ibm_is_floating_ip.harbor.address
    harbor_version        = var.harbor_version
    harbor_admin_password = var.harbor_admin_password
  })
}

resource "ibm_is_instance_network_interface_floating_ip" "harbor" {
  instance          = ibm_is_instance.harbor.id
  network_interface = ibm_is_instance.harbor.primary_network_interface[0].id
  floating_ip       = ibm_is_floating_ip.harbor.id
}
