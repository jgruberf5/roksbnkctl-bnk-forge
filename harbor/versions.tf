terraform {
  required_version = ">= 1.5"
  required_providers {
    ibm = {
      source  = "IBM-Cloud/ibm"
      version = ">= 1.65"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0"
    }
  }
}

# The IBM provider reads the API key from IC_API_KEY / IBMCLOUD_API_KEY, which BNK
# Forge's opentofu engine injects from the project's cloud credential template
# (get_cloud_credentials_env). No api_key variable — a credential must never be a
# module input that could land in tfvars or module outputs.
provider "ibm" {
  region = var.region
}
