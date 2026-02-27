# main.tf — Provider configurations and shared local values
#
# The kubernetes and helm providers are configured to authenticate against the
# GKE cluster created in gke.tf.  They implicitly depend on that cluster being
# ready because they reference its outputs (endpoint, master_auth).

# =============================================================================
# Google Cloud Provider
# =============================================================================

provider "google" {
  project = var.project_id
  region  = var.region
}

# =============================================================================
# GKE Authentication — supplies a short-lived access token for kubectl/helm
# =============================================================================

# Retrieves an OAuth2 access token for the currently authenticated principal.
# Used by the kubernetes and helm providers so they can authenticate against the
# GKE API server without needing a static long-lived kubeconfig on disk.
data "google_client_config" "default" {}

# =============================================================================
# Kubernetes Provider
# =============================================================================

# Configured to talk directly to the GKE cluster endpoint.  Terraform resolves
# google_container_cluster.main before evaluating any kubernetes_* resources,
# which ensures the cluster exists before we try to create namespaces / secrets.
provider "kubernetes" {
  host  = "https://${google_container_cluster.main.endpoint}"
  token = data.google_client_config.default.access_token

  cluster_ca_certificate = base64decode(
    google_container_cluster.main.master_auth[0].cluster_ca_certificate
  )
}

# =============================================================================
# Helm Provider
# =============================================================================

provider "helm" {
  kubernetes {
    host  = "https://${google_container_cluster.main.endpoint}"
    token = data.google_client_config.default.access_token

    cluster_ca_certificate = base64decode(
      google_container_cluster.main.master_auth[0].cluster_ca_certificate
    )
  }
}

# =============================================================================
# Shared Local Values
# =============================================================================

locals {
  # GKE cluster name and zone derived from environment and region variables
  cluster_name = "mcp-registry-${var.environment}"
  zone         = "${var.region}-b"

  # MCP Registry application ingress hostnames:
  #   staging → staging.registry.modelcontextprotocol.io
  #   prod    → prod.registry.modelcontextprotocol.io
  #             registry.modelcontextprotocol.io   (apex / canonical domain)
  app_hosts = var.environment == "prod" ? [
    "prod.registry.modelcontextprotocol.io",
    "registry.modelcontextprotocol.io",
    ] : [
    "${var.environment}.registry.modelcontextprotocol.io",
  ]

  # Grafana ingress hostname
  grafana_host = "grafana.${var.environment}.registry.modelcontextprotocol.io"

  # ingress-nginx replica count:
  #   staging → 1 (brief downtime during node recycles is acceptable)
  #   prod    → 2 (HA: survives single-node failure; zero-downtime deploys)
  nginx_replica_count = var.environment == "prod" ? 2 : 1

  # Service account that owns the GCS HMAC key used by k8up / restic.
  # This reuses the same service account as the Pulumi deployment to avoid
  # creating an additional identity that must be managed separately.
  backup_service_account_email = "pulumi-svc@${var.project_id}.iam.gserviceaccount.com"

  # Standard labels applied to every resource for cost attribution and filtering
  common_labels = {
    environment = var.environment
    managed_by  = "terraform"
    project     = "mcp-registry"
  }
}
