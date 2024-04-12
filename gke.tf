terraform {
  required_providers {
    kubectl = {
        source = "gavinbunney/kubectl"
        version = "1.14.0"
    }
  }
}

###############################################################################################

provider "google" {
    project = var.gcp_project_id
    region  = var.location
}

data "google_project" "project" {
}

## Service Account
resource "google_service_account" "redpanda-gcp-sa" {
    account_id = "${var.cluster_name}-gcp-sa"
    display_name = "Redpanda Service Account created by Terraform"
}

## Networking -- create VPC, subnets, and a static IP for Console
resource "google_compute_network" "vpc" {
    name                    = "${var.cluster_name}-vpc"
    auto_create_subnetworks = "false"
}

resource "google_compute_subnetwork" "subnet" {
    name            = "${var.cluster_name}-subnet"
    region          = join("-", slice(split("-", var.location), 0, 2))
    network         = google_compute_network.vpc.name
    ip_cidr_range   = var.cidr_range
}

resource "google_compute_global_address" "console-ip" {
    name = "${var.cluster_name}-console-ip"
    description = "public ipv4 for Redpanda Console"
}

# Need some tomfoolery to look up the actual dns name for the zone.
data "external" "dns-zone-name" {
    program = [
        "gcloud", "dns", "managed-zones", "describe", 
        var.managed_dns_zone, 
        "--format=json(dnsName)" ]
}

resource "google_dns_record_set" "console-dns-a" {
    name            = "console.${data.external.dns-zone-name.result.dnsName}"
    managed_zone    = var.managed_dns_zone
    type            = "A"
    ttl             = 300

    rrdatas = [
        google_compute_global_address.console-ip.address
    ]
}

## Object Storage -- create GCS bucket. We make the IAM binding later after GKE is available.
resource "google_storage_bucket" "tiered-storage" {
    name        = "${var.cluster_name}-ts"
    location    = join("-", slice(split("-", var.location), 0, 2))

    public_access_prevention    = "enforced"
    uniform_bucket_level_access = true
    force_destroy               = true
}

## Kubernetes -- create GKE cluster and node pools
data "google_container_engine_versions" "gke_version" {
    location        = var.location
    version_prefix  = "1.27."
}

resource "google_container_cluster" "redpanda_gke" {
    name     = var.cluster_name
    location = var.location

    initial_node_count = 3

    network     = google_compute_network.vpc.name
    subnetwork  = google_compute_subnetwork.subnet.name

    workload_identity_config {
        workload_pool = "${data.google_project.project.project_id}.svc.id.goog"
    }

    node_config {
        machine_type    = "e2-medium"
        service_account = google_service_account.redpanda-gcp-sa.email
        oauth_scopes    = [
            "https://www.googleapis.com/auth/logging.write",
            "https://www.googleapis.com/auth/monitoring",
            "https://www.googleapis.com/auth/monitoring.write"
        ]

        labels = {
            role = var.control_node_role
        }
    }

    deletion_protection = false
}

resource "google_container_node_pool" "redpanda_nodes" {
    name        = "${var.cluster_name}-redpanda"
    location    = var.location
    cluster     = google_container_cluster.redpanda_gke.name

    version     = data.google_container_engine_versions.gke_version.release_channel_latest_version["STABLE"]
    node_count  = var.gke_num_nodes

    node_config {
        service_account = google_service_account.redpanda-gcp-sa.email

        labels = {
            role = var.broker_node_role
        }

        machine_type = var.rp_instance_type

        # Provision with 2 Local SSD that we will arrange in a software RAID-0 pattern via LVM.
        local_nvme_ssd_block_config {
            local_ssd_count = 2
        }

        metadata = {
            disable-legacy-endpoints = "true"
        }

        oauth_scopes = [
            # Need additional scope for GCS writes.
            "https://www.googleapis.com/auth/devstorage.read_write",
            "https://www.googleapis.com/auth/logging.write",
            "https://www.googleapis.com/auth/monitoring",
            "https://www.googleapis.com/auth/monitoring.write"
        ]

        workload_metadata_config {
            mode = "GKE_METADATA"
        }
    }
}

data "google_client_config" "default" {
    depends_on = [ google_container_cluster.redpanda_gke ]
}

data "google_container_cluster" "redpanda_gke" {
    depends_on  = [ google_container_cluster.redpanda_gke ]
    name        = var.cluster_name
}

## Kubernetes Node Tuning -- implementing storage classes and tuning hosts
provider "kubernetes" {
    host                    = "https://${google_container_cluster.redpanda_gke.endpoint}"
    cluster_ca_certificate  = base64decode(data.google_container_cluster.redpanda_gke.master_auth[0].cluster_ca_certificate)
    token                   = data.google_client_config.default.access_token
}
provider "helm" {
  kubernetes {
    host                    = "https://${google_container_cluster.redpanda_gke.endpoint}"
    cluster_ca_certificate  = base64decode(data.google_container_cluster.redpanda_gke.master_auth[0].cluster_ca_certificate)
    token                   = data.google_client_config.default.access_token
  }
}
provider "kubectl" {
    host                    = "https://${google_container_cluster.redpanda_gke.endpoint}"
    cluster_ca_certificate  = base64decode(data.google_container_cluster.redpanda_gke.master_auth[0].cluster_ca_certificate)
    token                   = data.google_client_config.default.access_token
}

## Install and configure our StorageClass so Redpanda goes brrrrrr.
resource "helm_release" "csi-driver-lvm" {
    name        = "csi-driver-lvm"
    repository  = "https://helm.metal-stack.io"
    chart       = "csi-driver-lvm"
    version     = "0.6.0"

    set {
        name = "lvm.devicePattern"
        value = "/dev/nvme[0-9]n[0-9]"
    }

    namespace           = "csi-driver-lvm"
    create_namespace    = true
}

resource "kubernetes_storage_class" "redpanda-nvme" {
    metadata {
        name = "csi-driver-lvm-striped-xfs"
    }
    storage_provisioner     = "lvm.csi.metal-stack.io"
    reclaim_policy          = "Delete"
    volume_binding_mode     = "WaitForFirstConsumer"
    allow_volume_expansion  = true
    parameters              = {
        type   = "striped"
        fsType = "xfs"
    }

    depends_on = [ helm_release.csi-driver-lvm ]
}

## TODO: tune k8s nodes? do that prior?

## Additional Services -- install things like Cert-Manager, etc. used by Redpanda
resource "helm_release" "cert_manager" {
    name        = "cert-manager"
    repository  = "https://charts.jetstack.io"
    chart       = "cert-manager"
    version     = "1.14.4"

    set {
        name    = "installCRDs"
        value   = "true"
    }

    # Should probably use Anti-Affinity, but for simplicity let's target the 
    # non-Broker pool directly for now.
    set {
        name    = "nodeSelector.role"
        value   = var.control_node_role
    }

    namespace           = "cert-manager"
    create_namespace    = true
}

###########################################################
## Prepare to install Redpanda
###########################################################

resource "kubernetes_namespace" "redpanda-ns" {
    metadata {
        name = "redpanda"
    }
}

resource "kubernetes_service_account" "redpanda-sa" {
    metadata {
        name        = "redpanda-sa"
        namespace   = "redpanda"
    }
}

# Needed for Debug bundles.
resource "kubernetes_cluster_role_binding" "redpanda-sa-binding" {
    metadata {
        name = "redpanda-binding"
    }

    role_ref {
        api_group   = "rbac.authorization.k8s.io"
        kind        = "ClusterRole"
        name        = "view"
    }

    subject {
        kind        = "ServiceAccount"
        name        = kubernetes_service_account.redpanda-sa.metadata[0].name
        namespace   = "redpanda"
    }
}

resource "google_project_iam_custom_role" "redpanda-ts-role" {
    role_id     = "redpanda.ts.admin"
    title       = "Redpanda Tiered Storage Admin"
    description = "Role used by Redpanda Brokers to Tiered Storage management."

    permissions = [
        "storage.buckets.get",
        "storage.buckets.list",
        "storage.buckets.enableObjectRetention",
        "storage.objects.create",
        "storage.objects.delete",
        "storage.objects.get",
        "storage.objects.list",
        "storage.objects.setRetention",
        "storage.buckets.update"
    ]
}

resource "google_project_iam_binding" "binding" {
    project = data.google_project.project.project_id
    role    = "projects/${data.google_project.project.project_id}/roles/${google_project_iam_custom_role.redpanda-ts-role.role_id}"
    members = [
        "principal://iam.googleapis.com/projects/${data.google_project.project.number}/locations/global/workloadIdentityPools/${data.google_project.project.project_id}.svc.id.goog/subject/ns/${kubernetes_namespace.redpanda-ns.metadata[0].name}/sa/${kubernetes_service_account.redpanda-sa.metadata[0].name}"
    ]
}

resource "google_storage_bucket_iam_binding" "grant-storage-access" {
    bucket  = google_storage_bucket.tiered-storage.name
    role    = "roles/storage.objectAdmin"
    members = [
        "principal://iam.googleapis.com/projects/${data.google_project.project.number}/locations/global/workloadIdentityPools/${data.google_project.project.project_id}.svc.id.goog/subject/ns/${kubernetes_namespace.redpanda-ns.metadata[0].name}/sa/${kubernetes_service_account.redpanda-sa.metadata[0].name}"
    ]
}


## Kubernetes Secrets -- initialize any secrets used by brokers or Console
# Generate an admin user/password secret
resource "kubernetes_secret" "redpanda-superuser" {
    metadata {
        name        = "redpanda-superusers"
        namespace   = kubernetes_namespace.redpanda-ns.metadata[0].name
    }

    data = {
        "superusers.txt" = "${file("${path.module}/superusers.txt")}"
    }
}

# Prepare a Redpanda Enterprise license for use by the brokers and Console
resource "kubernetes_secret" "redpanda-license" {
    metadata {
        name        = "redpanda-license"
        namespace   = kubernetes_namespace.redpanda-ns.metadata[0].name
    }

    data = {
        "redpanda.license" = "${file("${path.module}/redpanda.license")}"
    }
}

# Generate a JWT Secret for Console
resource "random_password" "jwt" {
    length  = 64
    special = true
}
resource "kubernetes_secret" "jwt-secret" {
    metadata {
        name        = "redpanda-console-jwt-secret"
        namespace   = kubernetes_namespace.redpanda-ns.metadata[0].name
    }

    # name the entries in a format suitable for Console's Deployment envFrom 
    data = {
        # LOGIN_ENABLED = "true"
        LOGIN_JWTSECRET = base64encode(random_password.jwt.result)
    }
}

# Configure SSO integration with Okta
resource "kubernetes_secret" "okta-secrets" {
    metadata {
        name        = "okta-secrets"
        namespace   = kubernetes_namespace.redpanda-ns.metadata[0].name
    }

    # name the entries in a format suitable for Console's Deployment envFrom 
    data = {
        LOGIN_OKTA_DIRECTORY_APITOKEN   = var.okta_apitoken
        LOGIN_OKTA_CLIENTSECRET         = var.okta_clientsecret

        # these aren't secret, but keep together with other Okta data
        LOGIN_OKTA_ENABLED  = "true"
        LOGIN_OKTA_CLIENTID = var.okta_clientid
        LOGIN_OKTA_URL      = var.okta_url
    }
}

# Set up Ingress requirements. We need an "SSL Policy", FrontendConfig, and ManagedCertificate.
resource "google_compute_ssl_policy" "console-ssl-policy" {
    name    = "redpanda-console-ssl-policy"
    profile = "COMPATIBLE"
    min_tls_version = "TLS_1_2"  # If your client only supports TLS v1.1, here's a nickel.
}

resource "kubectl_manifest" "ingress-frontend-config" {
    yaml_body = <<-EOF
apiVersion: networking.gke.io/v1beta1
kind: FrontendConfig
metadata:
  name: ingress-security-config
  namespace: "${kubernetes_namespace.redpanda-ns.metadata[0].name}"
spec:
  sslPolicy: "${google_compute_ssl_policy.console-ssl-policy.name}"
  redirectToHttps:
    enabled: true
EOF
    depends_on = [ google_compute_ssl_policy.console-ssl-policy ]
}

resource "kubectl_manifest" "console-managed-cert" {
    yaml_body = <<-EOF
apiVersion: networking.gke.io/v1
kind: ManagedCertificate
metadata:
  name: console-managed-cert
  namespace: "${kubernetes_namespace.redpanda-ns.metadata[0].name}"
spec:
  domains:
    - "${trimsuffix(google_dns_record_set.console-dns-a.name, ".")}"
EOF
}

###########################################################
## Deploy Redpanda via Helm
###########################################################
resource "helm_release" "redpanda" {
    name        = "redpanda"
    repository  = "https://charts.redpanda.com"
    chart       = "redpanda"
    version     = "5.7.37"
    namespace   = kubernetes_namespace.redpanda-ns.metadata[0].name

    values = [ "${file("redpanda.yaml")}" ]

    # Brokers deploy to nodes marked labeled with the broker role.
    set {
        name    = "nodeSelector.role"
        value   = var.broker_node_role
    }

    # Console deploys to nodes marked labeled with the control role.
    set {
        name    = "console.nodeSelector.role"
        value   = var.control_node_role
    }

    set {
        name    = "serviceAccount.name"
        value   = kubernetes_service_account.redpanda-sa.metadata[0].name
    }

    # Hook up the secrets.
    set {
        name    = "auth.sasl.secretRef"
        value   = kubernetes_secret.redpanda-superuser.metadata[0].name
    }
    set {
        name    = "console.extraEnvFrom[0].secretRef.name"
        value   = kubernetes_secret.jwt-secret.metadata[0].name
    }
    set {
        name    = "console.extraEnvFrom[1].secretRef.name"
        value   = kubernetes_secret.okta-secrets.metadata[0].name
    }

    # Hook up Okta role mappings
    set {
        name = "console.console.roleBindings[0].subjects[0].name"
        value = var.okta_admin_groupid
    }
    set {
        name = "console.console.roleBindings[1].subjects[0].name"
        value = var.okta_viewer_groupid
    }
    
    # Configure the Ingress for Console
    set {
        name    = "console.ingress.annotations.kubernetes\\.io/ingress\\.global-static-ip-name"
        value   = google_compute_global_address.console-ip.name
    }
    set {
        name    = "console.ingress.hosts[0].host"
        value   = trimsuffix(google_dns_record_set.console-dns-a.name, ".")
    }

    # Configure Tiered Storage
    set {
        name    = "storage.tiered.config.cloud_storage_region"
        value   = lower(join("-", slice(split("-", google_storage_bucket.tiered-storage.location), 0, 2)))
    }
    set {
        name    = "storage.tiered.config.cloud_storage_bucket"
        value   = google_storage_bucket.tiered-storage.name
    }

    depends_on = [ helm_release.cert_manager ]
}

### Google Managed Prometheus
# GKE 1.27 has the exporters already available for us. Just need a CR.

