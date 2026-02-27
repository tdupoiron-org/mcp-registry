# gke.tf — GKE cluster and managed node pool
#
# Creates a zonal GKE cluster (us-central1-b by default) with:
#   - Default node pool removed immediately after cluster creation
#   - HTTP load balancing disabled (ingress-nginx handles all LB traffic)
#   - A separately managed node pool for full lifecycle control

# =============================================================================
# GKE Cluster
# =============================================================================

resource "google_container_cluster" "main" {
  name        = local.cluster_name
  location    = local.zone
  project     = var.project_id
  description = "MCP Registry ${var.environment} GKE Cluster"

  # Terraform creates the cluster with a single temporary node, then immediately
  # deletes the default node pool.  All workloads run on the managed pool below.
  remove_default_node_pool = true
  initial_node_count       = 1

  addons_config {
    # Disable GCP HTTP load balancing: ingress-nginx is the sole ingress
    # controller and manages its own L4 LoadBalancer Service.
    http_load_balancing {
      disabled = true
    }
  }

  # Set to true in production to protect the cluster from accidental deletion.
  # Can be toggled here without recreating the cluster.
  deletion_protection = false

  # GKE uses resource_labels (not labels) for its label API field.
  resource_labels = local.common_labels

  lifecycle {
    # After initial creation, changes to initial_node_count are irrelevant;
    # the actual node count is controlled by the node pool below.
    ignore_changes = [initial_node_count]
  }
}

# =============================================================================
# Managed Node Pool
# =============================================================================

resource "google_container_node_pool" "main" {
  name     = "${local.cluster_name}-nodepool"
  cluster  = google_container_cluster.main.name
  location = local.zone
  project  = var.project_id

  # Fixed node count: 2 nodes give us redundancy without over-provisioning.
  # Add an autoscaling block here if dynamic scaling is needed in future.
  node_count = 2

  node_config {
    machine_type = "e2-standard-2"
    disk_size_gb = 20
    disk_type    = "pd-standard"

    # Minimal OAuth scope: cloud-platform grants all GCP API access,
    # with IAM policies providing the fine-grained permission boundary.
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]

    labels = local.common_labels

    metadata = {
      # Disable legacy GCE metadata endpoints to reduce attack surface
      disable-legacy-endpoints = "true"
    }
  }

  management {
    # Auto-repair replaces unhealthy nodes automatically
    auto_repair = true
    # Auto-upgrade keeps nodes on the latest GKE patch within the release channel
    auto_upgrade = true
  }
}
