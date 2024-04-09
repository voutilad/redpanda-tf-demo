# terraform + GKE + helm + redpanda + okta

An enterprise-focused, one-shot demonstration to deploy a Redpanda cluster that:

- uses Okta for SSO with Redpanda Console
- enables Tiered Storage in GCP
- runs in a dedicated GKE node pool
- uses k8s service accounts and GKE Workload Identity Federation to auth to GCS
- deploys the NVME storage class
- wires up a GKE ingress with Google managed TLS certificate and appropriate dns `A` record for public access

You need:
- terraform or opentofu (tested with opentofu v1.6.2)
- kubectl
- gcloud (authenticated to your cloud project)
- an Okta account configured for SSO with Console (see below)
- a GCP Cloud DNS managed zone for publicly exposing Console
- a Redpanda enterprise license

Currently assumes:
- single-AZ cluster for demo $ savings
- uses a k8s namespace of `redpanda`

## Deploy this thing
1. Copy `example.tfvars` to `terraform.tfvars` and edit as needed.
2. Save your license key to `redpanda.license` in the project directory.
3. Run the following:
    ```sh
    ./gensecrets.sh
    tofu init
    tofu apply
    ```
4. Go make and drink a coffee. ☕️
5. Once things are up, authenticate your local `kubectl` using `gcloud`:
    ```sh
    gcloud container clusters get-credentials [your-cluster-name] --location [your-cluster-location] 
    ```
6. *ahem* [bounce](https://github.com/redpanda-data/helm-charts/issues/1173) the statefulset:
    ```sh
    kubectl rollout restart statefulset/redpanda -n redpanda
    ```

> Note: your Redpanda superuser credentials are in `superusers.txt` as well as a k8s secret if you need to use `rpk`.

After 10-15 minutes you should be able to access your cluster via:

  `https://console.<your-domain>`

## Okta Config

This part needs to be documented a bit...TBD. Currently this demo uses two roles: `admin` and `viewer`.