## Variables!
variable "gcp_project_id" {
    description = "GCP project id."
    type        = string
}

variable "location" {
    description = "GCP region or zone to deploy into."
    type        = string
}

variable "cidr_range" {
    default     = "10.10.0.0/24"
    description = "The ipv4 cidr for use in the GKE subnet."
    type        = string
}

variable "managed_dns_zone" {
    description = "Google Cloud DNS managed zone for use with Console."
    type        = string
}

variable "cluster_name" {
    default     = "rp-tf"
    description = "Name for the Redpanda cluster and used for prefixing resources."
    type        = string
}

variable "gke_num_nodes" {
    default     = 3
    description = "Numbers of GKE nodes for the node pool (per location)"
    type        = number
}

variable "rp_instance_type" {
    default     = "n2-standard-4"
    description = "GCE Instance Type to use for Redpanda GKE nodepool."
    type        = string
}

variable "control_node_role" {
    default     = "not-broker"
    description = "Value for the 'role' node label applied to the control plane cluster"
    type        = string
}

variable "broker_node_role" {
    default     = "broker"
    description = "Value for the 'role' node label to apply to the Redpanda node pool members"
    type        = string
}

variable "okta_url" {
    description = "URL for the Okta account. Example: https://<your account>.okta.com"
    type        = string
}

variable "okta_clientid" {
    description = "Okta Client ID."
    type        = string
}

variable "okta_apitoken" {
    description = "Okta API Token for resolving group memberships."
    sensitive   = true
    type        = string
}

variable "okta_clientsecret" {
    description = "Okta Client secret."
    sensitive   = true
    type        = string
}
