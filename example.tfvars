### GCP Project Settings
gcp_project_id = "my-first-demo-1234"
location = "northamerica-northeast1-a"

### VPC networking
cidr_range = "10.10.0.0/24"

### Cloud Networking
managed_dns_zone = "demo-zone"

### GKE Infrastructure
cluster_name = "demo"
gke_num_nodes = 3
rp_instance_type = "n2-standard-4"
control_node_role = "broker"
broker_node_role = "not-broker"

### Okta SSO
okta_url = "https://trial-xxxx.okta.com"
okta_clientid = "xxxx"
okta_apitoken = "xxxx"
okta_clientsecret = "xxxx-yyyy-zzzz"