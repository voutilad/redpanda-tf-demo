# terraform + helm + redpanda

You need:
- terraform or tofu (tested with opentofu v1.6.2)
- kubectl
- gcloud (authenticated to your cloud project)
- an okta account configured for SSO with Console

```sh
./gensecrets.sh
tofu init
tofu apply
```

You Redpanda superuser credentials are in `superusers.txt` as well as a k8s secret.