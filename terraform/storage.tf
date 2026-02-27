# storage.tf — GCS backup bucket, IAM binding, and HMAC key
#
# Creates an S3-compatible backup target for k8up / restic:
#   - Standard multi-region bucket with 60-day lifecycle deletion
#   - Versioning enabled for accidental-deletion protection
#   - objectAdmin IAM binding for the Terraform/Pulumi service account
#   - HMAC key providing S3-compatible credentials for restic

# =============================================================================
# GCS Backup Bucket
# =============================================================================

resource "google_storage_bucket" "backups" {
  name          = "mcp-registry-${var.environment}-backups"
  location      = "US"
  storage_class = "STANDARD"
  project       = var.project_id

  # Safety-net deletion rule: restic/k8up prunes snapshots at 28 days;
  # GCS removes any residual objects at 60 days.
  lifecycle_rule {
    action {
      type = "Delete"
    }

    condition {
      age = 60
    }
  }

  # Uniform access control: disables per-object ACLs and centralises
  # permission management through IAM policies on the bucket.
  uniform_bucket_level_access = true

  versioning {
    enabled = true
  }

  labels = merge(local.common_labels, {
    purpose = "k8up-backups"
  })
}

# =============================================================================
# IAM — Grant the service account object-admin access to the bucket
# =============================================================================

# Reuses the existing Terraform/Pulumi service account to avoid creating an
# additional identity.  The service account must already exist in the project.
resource "google_storage_bucket_iam_member" "backups_object_admin" {
  bucket = google_storage_bucket.backups.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${local.backup_service_account_email}"
}

# =============================================================================
# HMAC Key — S3-compatible credentials for k8up / restic
# =============================================================================

# GCS HMAC keys expose an S3-compatible interface, allowing restic (used by
# k8up) to treat GCS as an S3 backend without any code changes.
resource "google_storage_hmac_key" "backups" {
  service_account_email = local.backup_service_account_email
  project               = var.project_id

  # Ensure the IAM binding is in place before creating the HMAC key, so the
  # service account has bucket access immediately on first use.
  depends_on = [google_storage_bucket_iam_member.backups_object_admin]
}
