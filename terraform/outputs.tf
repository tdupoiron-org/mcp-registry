# outputs.tf — Output values (alphabetical order)
#
# Outputs are surfaced in the Terraform CLI after apply and in the HCP Terraform
# workspace UI.  Sensitive outputs are marked accordingly; they are redacted in
# plan output but stored encrypted in HCP Terraform state.

output "app_hosts" {
  description = "Ingress hostnames for the MCP Registry application."
  value       = local.app_hosts
}

output "backup_bucket_name" {
  description = "Name of the GCS bucket used for k8up / restic backups."
  value       = google_storage_bucket.backups.name
}

output "backup_bucket_url" {
  description = "GCS URL (gs://<name>) of the backup bucket."
  value       = google_storage_bucket.backups.url
}

output "cluster_endpoint" {
  description = "HTTPS endpoint of the GKE cluster API server."
  value       = "https://${google_container_cluster.main.endpoint}"
  sensitive   = true
}

output "cluster_name" {
  description = "Name of the GKE cluster."
  value       = google_container_cluster.main.name
}

output "get_credentials_command" {
  description = "gcloud command to configure kubectl for the GKE cluster."
  value       = "gcloud container clusters get-credentials ${google_container_cluster.main.name} --zone ${local.zone} --project ${var.project_id}"
}

output "grafana_url" {
  description = "HTTPS URL for the Grafana dashboard."
  value       = "https://${local.grafana_host}"
}

output "zone" {
  description = "GCP zone in which the GKE cluster is deployed."
  value       = local.zone
}
