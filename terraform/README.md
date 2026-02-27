# MCP Registry — Terraform Infrastructure

Terraform configurations for deploying the [MCP Registry](https://github.com/modelcontextprotocol/registry) application on Google Kubernetes Engine (GKE).

This Terraform module is a port of the existing [Pulumi deployment](../deploy/) and manages the same infrastructure components.

---

## Architecture Overview

```
GCP Project
├── GKE Cluster (us-central1-b, e2-standard-2 × 2 nodes)
│   ├── cert-manager          — TLS certificate provisioning (Let's Encrypt)
│   ├── ingress-nginx         — NGINX Ingress Controller (L4 LoadBalancer)
│   ├── cloudnative-pg        — PostgreSQL operator
│   │   ├── registry-pg       — App database (50 Gi)
│   │   └── grafana-pg        — Grafana metadata database (10 Gi)
│   ├── mcp-registry          — Application (2 replicas)
│   ├── k8up                  — Backup operator (restic → GCS)
│   └── monitoring/
│       ├── VictoriaMetrics   — Metrics storage (14-day retention)
│       ├── VMAgent           — Metrics scraper
│       ├── VictoriaLogs      — Log storage (15-day retention, 20 Gi)
│       ├── OpenTelemetry     — DaemonSet log/metric collector
│       └── Grafana           — Dashboards (Google OAuth SSO)
└── GCS Bucket                — k8up/restic backup target (60-day lifecycle)
```

### Ingress Hostnames

| Environment | MCP Registry | Grafana |
|-------------|-------------|---------|
| staging | `staging.registry.modelcontextprotocol.io` | `grafana.staging.registry.modelcontextprotocol.io` |
| prod | `prod.registry.modelcontextprotocol.io` `registry.modelcontextprotocol.io` | `grafana.prod.registry.modelcontextprotocol.io` |

---

## File Structure

| File | Purpose |
|------|---------|
| `versions.tf` | Terraform version constraints, required providers, HCP Terraform backend |
| `main.tf` | Provider configurations (Google, Kubernetes, Helm), shared locals |
| `variables.tf` | Input variable definitions |
| `gke.tf` | GKE cluster and managed node pool |
| `storage.tf` | GCS backup bucket, IAM binding, HMAC key |
| `kubernetes.tf` | All Kubernetes namespaces, Helm releases, and manifest resources |
| `outputs.tf` | Output values |
| `terraform.tfvars.example` | Example variable values (no sensitive data) |

---

## Prerequisites

1. **Terraform** ≥ 1.9.0 — [Install](https://developer.hashicorp.com/terraform/install)
2. **gcloud CLI** — authenticated with a principal that has the following IAM roles on the target project:
   - `roles/container.admin`
   - `roles/storage.admin`
   - `roles/iam.serviceAccountTokenCreator`
3. **GCP project** with the following APIs enabled:
   - `container.googleapis.com` (GKE)
   - `storage.googleapis.com` (GCS)
4. **Service account** `pulumi-svc@<project>.iam.gserviceaccount.com` — must exist in the project (reused for backup HMAC key)
5. **HCP Terraform account** (optional but recommended) — update `versions.tf` with your organization name

---

## Quick Start

### 1. Clone and enter the terraform directory

```bash
cd terraform/
```

### 2. Configure the HCP Terraform backend

Edit `versions.tf` and replace the placeholder values:

```hcl
cloud {
  organization = "your-org-name"   # ← replace
  workspaces {
    name = "mcp-registry-staging"  # ← replace (one workspace per environment)
  }
}
```

Alternatively, remove the `cloud {}` block entirely and use a local or GCS backend.

### 3. Copy and populate the variable file

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` with your non-sensitive values, then set sensitive variables via environment variables:

```bash
export TF_VAR_github_client_secret="..."
export TF_VAR_jwt_private_key="$(cat /path/to/private.pem)"
export TF_VAR_google_oauth_client_secret="..."
```

### 4. Initialise Terraform

```bash
terraform init
```

### 5. Two-stage apply (new cluster only)

On a **brand-new cluster**, CRD-backed resources (ClusterIssuer, CNPG Cluster, k8up Schedule) cannot be planned until their operator's CRDs are registered in the cluster.  Use a targeted first apply to install the operators:

```bash
# Stage 1 — install CRD operators
terraform apply \
  -target=helm_release.cert_manager \
  -target=helm_release.cloudnative_pg \
  -target=helm_release.k8up

# Stage 2 — apply everything else
terraform apply
```

On subsequent applies a single `terraform apply` is sufficient.

### 6. Configure kubectl

After apply, run the command printed in the `get_credentials_command` output:

```bash
terraform output -raw get_credentials_command | bash
```

---

## Variables

| Name | Description | Default | Sensitive |
|------|-------------|---------|-----------|
| `project_id` | GCP project ID | — | No |
| `environment` | `staging` or `prod` | — | No |
| `region` | GCP region | `us-central1` | No |
| `github_client_id` | GitHub OAuth App Client ID | — | No |
| `github_client_secret` | GitHub OAuth App Client Secret | — | **Yes** |
| `jwt_private_key` | RSA private key (PEM) for JWT signing | — | **Yes** |
| `google_oauth_client_secret` | Google OAuth client secret for Grafana | — | **Yes** |
| `k8up_repo_password` | Restic repo encryption password (use `openssl rand -base64 32`) | — | **Yes** |
| `image_tag` | Docker image tag for the registry app | `main` | No |

---

## Outputs

| Name | Description |
|------|-------------|
| `cluster_name` | GKE cluster name |
| `cluster_endpoint` | GKE API server URL *(sensitive)* |
| `zone` | GCP zone |
| `app_hosts` | MCP Registry ingress hostnames |
| `grafana_url` | Grafana dashboard URL |
| `backup_bucket_name` | GCS backup bucket name |
| `backup_bucket_url` | GCS backup bucket URL |
| `get_credentials_command` | `gcloud` command to configure `kubectl` |

---

## Environment-Specific Notes

### Staging

```hcl
project_id  = "mcp-registry-staging"
environment = "staging"
image_tag   = "main"   # tracks latest build
```

- 1 ingress-nginx replica
- Image tag `main` follows the latest push to the `main` branch

### Production

```hcl
project_id  = "mcp-registry-prod"
environment = "prod"
image_tag   = "1.4.1"  # pin to an explicit release
```

- 2 ingress-nginx replicas (HA)
- Image tag **must** be pinned to a specific release; `main` is not appropriate for production

---

## Security Considerations

### Secrets in Terraform state

Sensitive variables (`github_client_secret`, `jwt_private_key`, `google_oauth_client_secret`) are stored in Terraform state.  Protect the state file by:

- Using the **HCP Terraform** backend (state is encrypted at rest and in transit)
- Or using a **GCS backend with CMEK** encryption

Never use a local state file for production workloads.

### Database lifecycle protection

The `registry-pg` CNPG Cluster resource has `lifecycle { prevent_destroy = true }` set.  To intentionally delete it (e.g. to rebuild from scratch), first update the lifecycle block and re-apply, then destroy.

### GKE deletion protection

`deletion_protection = false` is set by default to allow `terraform destroy` in development.  For production, change this to `true` in `gke.tf`.

---

## Backup and Restore

Backups are taken daily at 04:46 UTC by k8up using restic and stored in GCS.  The k8up Schedule prunes snapshots older than 28 days; GCS lifecycle deletes any residual objects at 60 days.

To list available snapshots:

```bash
# Port-forward to a pod with the backup credentials and run:
restic -r s3:https://storage.googleapis.com/mcp-registry-<env>-backups snapshots \
  --password-file /path/to/password
```

---

## Destroying Infrastructure

```bash
# Remove application resources first, then infrastructure
terraform destroy
```

> **Warning:** `terraform destroy` will attempt to delete the `registry-pg` CNPG Cluster.
> The `prevent_destroy` lifecycle rule will block this — intentional data-loss protection.
> To proceed: remove the `prevent_destroy = true` block from `kubernetes.tf` and re-apply before destroying.

---

## Provider Versions

| Provider | Version |
|----------|---------|
| `hashicorp/google` | `~> 6.0` |
| `hashicorp/kubernetes` | `~> 2.0` |
| `hashicorp/helm` | `~> 2.0` |
