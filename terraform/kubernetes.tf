# kubernetes.tf — All Kubernetes namespaces, Helm releases, and manifest resources
#
# Deployment order (enforced via explicit depends_on chains):
#
#   1. Namespaces
#   2. cert-manager Helm chart  →  letsencrypt-prod ClusterIssuer
#   3. ingress-nginx Helm chart
#   4. cloudnative-pg Helm chart  →  registry-pg Cluster (default ns)
#   5. mcp-registry Secret / Deployment / Service / Ingress
#   6. k8up Helm chart  →  backup credentials Secret  →  k8up Schedule
#   7. Monitoring: VictoriaMetrics, VMAgent, VictoriaLogs, OTel Collector,
#                  grafana-pg Cluster, Grafana Helm, Grafana Ingress
#
# ⚠️  CRD bootstrap note
# Resources backed by CRDs (ClusterIssuer, CNPG Cluster, k8up Schedule) require
# their operator's CRDs to already be registered in the cluster before Terraform
# can plan them.  On a brand-new cluster use a targeted first apply:
#
#   terraform apply \
#     -target=helm_release.cert_manager \
#     -target=helm_release.cloudnative_pg \
#     -target=helm_release.k8up
#
# Then run a full `terraform apply` to create the dependent CRD-backed resources.

# =============================================================================
# Namespaces
# =============================================================================

resource "kubernetes_namespace" "cert_manager" {
  metadata {
    name   = "cert-manager"
    labels = local.common_labels
  }
}

resource "kubernetes_namespace" "ingress_nginx" {
  metadata {
    name   = "ingress-nginx"
    labels = local.common_labels
  }
}

resource "kubernetes_namespace" "cnpg_system" {
  metadata {
    name   = "cnpg-system"
    labels = local.common_labels
  }
}

resource "kubernetes_namespace" "monitoring" {
  metadata {
    name   = "monitoring"
    labels = local.common_labels
  }
}

# =============================================================================
# cert-manager — TLS certificate provisioning
# Chart : cert-manager v1.18.2   https://charts.jetstack.io
# =============================================================================

resource "helm_release" "cert_manager" {
  name       = "cert-manager"
  repository = "https://charts.jetstack.io"
  chart      = "cert-manager"
  version    = "v1.18.2"
  namespace  = kubernetes_namespace.cert_manager.metadata[0].name

  wait    = true
  timeout = 600

  values = [
    yamlencode({
      installCRDs = true

      ingressShim = {
        defaultIssuerName = "letsencrypt-prod"
        defaultIssuerKind = "ClusterIssuer"
      }
    })
  ]
}

# ClusterIssuer: letsencrypt-prod
# Uses ACME HTTP-01 challenge via the nginx ingress class so that cert-manager
# can fulfil certificate requests for all Ingress resources in the cluster.
resource "kubernetes_manifest" "cluster_issuer_letsencrypt" {
  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"

    metadata = {
      name = "letsencrypt-prod"
    }

    spec = {
      acme = {
        server = "https://acme-v02.api.letsencrypt.org/directory"
        email  = "admin@modelcontextprotocol.io"

        privateKeySecretRef = {
          name = "letsencrypt-prod-key"
        }

        solvers = [
          {
            http01 = {
              ingress = {
                ingressClassName = "nginx"
              }
            }
          }
        ]
      }
    }
  }

  # CRDs are installed by the Helm chart; wait for it to be ready first.
  depends_on = [helm_release.cert_manager]
}

# =============================================================================
# ingress-nginx — NGINX Ingress Controller
# Chart : ingress-nginx v4.13.0   https://kubernetes.github.io/ingress-nginx
# =============================================================================

resource "helm_release" "ingress_nginx" {
  name       = "ingress-nginx"
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  version    = "4.13.0"
  namespace  = kubernetes_namespace.ingress_nginx.metadata[0].name

  wait    = true
  timeout = 600

  values = [
    yamlencode({
      controller = {
        # Replica count: 1 for staging (brief downtime acceptable),
        #                2 for prod (HA; survives single-node failure)
        replicaCount = local.nginx_replica_count

        service = {
          # L4 LoadBalancer with Local traffic policy preserves real client IPs
          # via the TCP connection source rather than X-Forwarded-For headers.
          type                  = "LoadBalancer"
          externalTrafficPolicy = "Local"
          annotations           = {}
        }

        config = {
          # Workaround for cert-manager HTTP-01 challenge path validation issue:
          # https://github.com/kubernetes/ingress-nginx/issues/11176
          strict-validate-path-type = "false"

          # GCP L4 Passthrough NLB does not add X-Forwarded-For; disable
          # header forwarding so the real client IP is used from the TCP source.
          use-forwarded-headers = "false"

          # Return 429 Too Many Requests for rate-limited traffic instead of 503.
          limit-req-status-code = "429"
        }
      }
    })
  ]
}

# =============================================================================
# CloudNative PG operator — PostgreSQL cluster management
# Chart : cloudnative-pg v0.26.0   https://cloudnative-pg.github.io/charts
# =============================================================================

resource "helm_release" "cloudnative_pg" {
  name       = "cloudnative-pg"
  repository = "https://cloudnative-pg.github.io/charts"
  chart      = "cloudnative-pg"
  version    = "v0.26.0"
  namespace  = kubernetes_namespace.cnpg_system.metadata[0].name

  wait    = true
  timeout = 600

  values = [
    yamlencode({
      webhooks = {
        replicaCount = 1
      }
    })
  ]
}

# PostgreSQL cluster for the registry application
#
# CNPG generates a Kubernetes Secret named "<cluster>-app" containing the
# connection URI, username, password, and dbname for the application user.
# The mcp-registry deployment references the "uri" key from that secret.
#
# ⚠️  This resource uses prevent_destroy to protect production data.
#     To intentionally delete the cluster, first change the lifecycle block.
resource "kubernetes_manifest" "registry_pg" {
  manifest = {
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "Cluster"

    metadata = {
      name      = "registry-pg"
      namespace = "default"
      labels = merge(local.common_labels, {
        app = "registry-pg"
      })
    }

    spec = {
      instances = 1
      # Disable PodDisruptionBudget: a single-instance cluster cannot tolerate
      # any voluntary disruptions, so a PDB would block node drains.
      enablePDB = false

      storage = {
        size = "50Gi"
      }
    }
  }

  # Operator CRDs must exist before Terraform can plan this resource.
  depends_on = [helm_release.cloudnative_pg]

  lifecycle {
    prevent_destroy = true
  }
}

# =============================================================================
# MCP Registry Application
# =============================================================================

# Secret: sensitive runtime configuration values
# ⚠️  Terraform stores state in plaintext; use an encrypted remote backend
#     (HCP Terraform or GCS with CMEK) to protect these values at rest.
resource "kubernetes_secret" "mcp_registry_secrets" {
  metadata {
    name      = "mcp-registry-secrets"
    namespace = "default"

    labels = merge(local.common_labels, {
      app = "mcp-registry"
    })
  }

  type = "Opaque"

  data = {
    GITHUB_CLIENT_SECRET = var.github_client_secret
    JWT_PRIVATE_KEY      = var.jwt_private_key
  }
}

# Deployment: 2 replicas with a RollingUpdate strategy that never reduces
# capacity below the desired count (maxUnavailable=0, maxSurge=1).
resource "kubernetes_deployment" "mcp_registry" {
  metadata {
    name      = "mcp-registry"
    namespace = "default"

    labels = merge(local.common_labels, {
      app = "mcp-registry"
    })
  }

  spec {
    replicas = 2

    strategy {
      type = "RollingUpdate"

      rolling_update {
        # Never reduce running pods below the desired count during a rollout.
        max_unavailable = "0"
        # Spin up one extra pod before terminating an old one.
        max_surge = "1"
      }
    }

    selector {
      match_labels = {
        app = "mcp-registry"
      }
    }

    template {
      metadata {
        labels = {
          app = "mcp-registry"
        }
      }

      spec {
        container {
          name  = "mcp-registry"
          image = "ghcr.io/modelcontextprotocol/registry:${var.image_tag}"

          # Always pull so that a tag re-push (e.g. 'main') is picked up on restart.
          image_pull_policy = "Always"

          port {
            name           = "http"
            container_port = 8080
          }

          # ---- Database -------------------------------------------------------
          # CNPG creates a secret "<cluster>-app" with a ready-to-use connection
          # URI. This avoids hard-coding the host / credentials here.
          env {
            name = "MCP_REGISTRY_DATABASE_URL"

            value_from {
              secret_key_ref {
                name = "registry-pg-app"
                key  = "uri"
              }
            }
          }

          # ---- GitHub OAuth ---------------------------------------------------
          env {
            name  = "MCP_REGISTRY_GITHUB_CLIENT_ID"
            value = var.github_client_id
          }

          env {
            name = "MCP_REGISTRY_GITHUB_CLIENT_SECRET"

            value_from {
              secret_key_ref {
                name = kubernetes_secret.mcp_registry_secrets.metadata[0].name
                key  = "GITHUB_CLIENT_SECRET"
              }
            }
          }

          # ---- JWT signing key ------------------------------------------------
          env {
            name = "MCP_REGISTRY_JWT_PRIVATE_KEY"

            value_from {
              secret_key_ref {
                name = kubernetes_secret.mcp_registry_secrets.metadata[0].name
                key  = "JWT_PRIVATE_KEY"
              }
            }
          }

          # ---- Google Cloud Identity OIDC (admin access) ----------------------
          env {
            name  = "MCP_REGISTRY_OIDC_ENABLED"
            value = "true"
          }

          env {
            name  = "MCP_REGISTRY_OIDC_ISSUER"
            value = "https://accounts.google.com"
          }

          env {
            # Restricted to the modelcontextprotocol.io hosted domain via extra_claims below
            name  = "MCP_REGISTRY_OIDC_CLIENT_ID"
            value = "32555940559.apps.googleusercontent.com"
          }

          env {
            # Restricts OIDC login to users whose Google Workspace domain is
            # modelcontextprotocol.io (hd = hosted domain claim).
            name  = "MCP_REGISTRY_OIDC_EXTRA_CLAIMS"
            value = jsonencode([{ hd = "modelcontextprotocol.io" }])
          }

          env {
            name  = "MCP_REGISTRY_OIDC_EDIT_PERMISSIONS"
            value = "*"
          }

          env {
            name  = "MCP_REGISTRY_OIDC_PUBLISH_PERMISSIONS"
            value = "*"
          }

          # ---- Health probes --------------------------------------------------
          liveness_probe {
            http_get {
              path = "/v0/health"
              port = 8080
            }

            initial_delay_seconds = 30
            timeout_seconds       = 5
          }

          readiness_probe {
            http_get {
              path = "/v0/health"
              port = 8080
            }

            initial_delay_seconds = 5
            timeout_seconds       = 3
          }

          # ---- Resource budget ------------------------------------------------
          resources {
            requests = {
              memory = "128Mi"
              cpu    = "100m"
            }

            limits = {
              memory = "256Mi"
            }
          }
        }
      }
    }
  }

  depends_on = [kubernetes_manifest.registry_pg]
}

# Service: ClusterIP — traffic arrives exclusively from ingress-nginx
resource "kubernetes_service" "mcp_registry" {
  metadata {
    name      = "mcp-registry"
    namespace = "default"

    labels = merge(local.common_labels, {
      app = "mcp-registry"
    })
  }

  spec {
    selector = {
      app = "mcp-registry"
    }

    type = "ClusterIP"

    port {
      name        = "http"
      port        = 80
      target_port = 8080
    }
  }
}

# Ingress: TLS via cert-manager, rate limiting via ingress-nginx annotations
# Hosts:
#   staging → staging.registry.modelcontextprotocol.io
#   prod    → prod.registry.modelcontextprotocol.io
#             registry.modelcontextprotocol.io
resource "kubernetes_ingress_v1" "mcp_registry" {
  metadata {
    name      = "mcp-registry"
    namespace = "default"

    labels = merge(local.common_labels, {
      app = "mcp-registry"
    })

    annotations = {
      "cert-manager.io/cluster-issuer" = "letsencrypt-prod"
      "kubernetes.io/ingress.class"    = "nginx"

      # Rate limiting: 180 requests/minute per client IP, burst up to 3× (540).
      # The 429 status code is configured globally on the nginx ConfigMap.
      "nginx.ingress.kubernetes.io/limit-rpm"              = "180"
      "nginx.ingress.kubernetes.io/limit-burst-multiplier" = "3"
    }
  }

  spec {
    tls {
      hosts       = local.app_hosts
      secret_name = "mcp-registry-${var.environment}-tls"
    }

    # Generate one Ingress rule per hostname (dynamic block handles both
    # the single-host staging case and the two-host prod case).
    dynamic "rule" {
      for_each = local.app_hosts

      content {
        host = rule.value

        http {
          path {
            path      = "/"
            path_type = "Prefix"

            backend {
              service {
                name = kubernetes_service.mcp_registry.metadata[0].name

                port {
                  number = 80
                }
              }
            }
          }
        }
      }
    }
  }

  depends_on = [
    helm_release.ingress_nginx,
    kubernetes_manifest.cluster_issuer_letsencrypt,
  ]
}

# =============================================================================
# K8up — Kubernetes Backup Operator
# Chart : k8up v4.8.4   https://k8up-io.github.io/k8up
# =============================================================================

# Kubernetes Secret: S3-compatible credentials derived from the GCS HMAC key.
# k8up passes these to restic as AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY,
# which restic translates into GCS HMAC authentication.
resource "kubernetes_secret" "k8up_backup_credentials" {
  metadata {
    name      = "k8up-backup-credentials"
    namespace = "default"

    labels = merge(local.common_labels, {
      "k8up.io/backup" = "true"
    })
  }

  type = "Opaque"

  data = {
    AWS_ACCESS_KEY_ID     = google_storage_hmac_key.backups.access_id
    AWS_SECRET_ACCESS_KEY = google_storage_hmac_key.backups.secret
  }
}

# Kubernetes Secret: restic repository encryption password.
# GCS provides at-rest encryption, so this password is a restic formality
# rather than the primary data protection mechanism.
resource "kubernetes_secret" "k8up_repo_password" {
  metadata {
    name      = "k8up-repo-password"
    namespace = "default"

    labels = merge(local.common_labels, {
      "k8up.io/backup" = "true"
    })
  }

  type = "Opaque"

  data = {
    password = "password"
  }
}

resource "helm_release" "k8up" {
  name       = "k8up"
  repository = "https://k8up-io.github.io/k8up"
  chart      = "k8up"
  version    = "4.8.4"

  # k8up runs cluster-wide; no dedicated namespace needed.
  wait    = true
  timeout = 600

  values = [
    yamlencode({
      k8up = {
        backupCommandAnnotation = "k8up.io/backup-command"
        fileExtensionAnnotation = "k8up.io/file-extension"
      }
    })
  ]
}

# k8up Schedule: daily backup at 04:46 UTC + prune at 05:46 UTC.
# Retention: 28 daily snapshots (4 weeks).  GCS lifecycle deletes at 60 days
# as a safety net for any objects that slip through restic pruning.
resource "kubernetes_manifest" "k8up_schedule" {
  manifest = {
    apiVersion = "k8up.io/v1"
    kind       = "Schedule"

    metadata = {
      name      = "backup-schedule"
      namespace = "default"
      labels    = local.common_labels
    }

    spec = {
      backend = {
        repoPasswordSecretRef = {
          name = kubernetes_secret.k8up_repo_password.metadata[0].name
          key  = "password"
        }

        s3 = {
          endpoint = "https://storage.googleapis.com"
          bucket   = google_storage_bucket.backups.name

          accessKeyIDSecretRef = {
            name = kubernetes_secret.k8up_backup_credentials.metadata[0].name
            key  = "AWS_ACCESS_KEY_ID"
          }

          secretAccessKeySecretRef = {
            name = kubernetes_secret.k8up_backup_credentials.metadata[0].name
            key  = "AWS_SECRET_ACCESS_KEY"
          }
        }
      }

      backup = {
        schedule = "46 4 * * *"

        # Run the backup sidecar as root so it can read all pod volume mounts.
        podSecurityContext = {
          runAsUser = 0
        }

        successfulJobsHistoryLimit = 3
        failedJobsHistoryLimit     = 3
      }

      prune = {
        schedule = "46 5 * * *"

        retention = {
          keepDaily = 28
        }

        successfulJobsHistoryLimit = 1
        failedJobsHistoryLimit     = 1
      }
    }
  }

  depends_on = [
    helm_release.k8up,
    kubernetes_secret.k8up_backup_credentials,
    kubernetes_secret.k8up_repo_password,
  ]
}

# =============================================================================
# Monitoring Stack
# =============================================================================

# ---- VictoriaMetrics Single -------------------------------------------------
# Chart : victoria-metrics-single v0.24.4
#         https://victoriametrics.github.io/helm-charts/
# 14-day metrics retention; lightweight for a single-cluster deployment.
resource "helm_release" "victoria_metrics" {
  name       = "victoria-metrics"
  repository = "https://victoriametrics.github.io/helm-charts/"
  chart      = "victoria-metrics-single"
  version    = "0.24.4"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  wait    = true
  timeout = 600

  values = [
    yamlencode({
      server = {
        retentionPeriod = "14d"

        resources = {
          requests = {
            memory = "128Mi"
            cpu    = "50m"
          }

          limits = {
            memory = "256Mi"
          }
        }
      }
    })
  ]
}

# ---- VMAgent ----------------------------------------------------------------
# Chart : victoria-metrics-agent v0.25.3
#         https://victoriametrics.github.io/helm-charts/
# Scrapes mcp-registry pods every 60 s and remote-writes to VictoriaMetrics.
resource "helm_release" "victoria_metrics_agent" {
  name       = "victoria-metrics-agent"
  repository = "https://victoriametrics.github.io/helm-charts/"
  chart      = "victoria-metrics-agent"
  version    = "0.25.3"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  wait    = true
  timeout = 600

  values = [
    yamlencode({
      remoteWrite = [
        {
          url = "http://victoria-metrics-victoria-metrics-single-server:8428/api/v1/write"
        }
      ]

      config = {
        global = {
          scrape_interval = "60s"
        }

        scrape_configs = [
          {
            job_name = "mcp-registry"

            kubernetes_sd_configs = [
              {
                role = "pod"

                namespaces = {
                  names = ["default"]
                }
              }
            ]

            relabel_configs = [
              {
                source_labels = ["__meta_kubernetes_pod_label_app"]
                regex         = "mcp-registry.*"
                action        = "keep"
              }
            ]
          }
        ]
      }

      resources = {
        requests = {
          memory = "64Mi"
          cpu    = "25m"
        }

        limits = {
          memory = "128Mi"
        }
      }
    })
  ]

  depends_on = [helm_release.victoria_metrics]
}

# ---- VictoriaLogs Single ----------------------------------------------------
# Chart : victoria-logs-single v0.11.8
#         https://victoriametrics.github.io/helm-charts/
# 15-day log retention; 20 Gi persistent volume for log storage.
resource "helm_release" "victoria_logs" {
  name       = "victoria-logs"
  repository = "https://victoriametrics.github.io/helm-charts/"
  chart      = "victoria-logs-single"
  version    = "0.11.8"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  wait    = true
  timeout = 600

  values = [
    yamlencode({
      server = {
        retentionPeriod = "15d"

        resources = {
          requests = {
            memory = "256Mi"
            cpu    = "100m"
          }

          limits = {
            memory = "2Gi"
            cpu    = "1000m"
          }
        }

        persistence = {
          enabled = true
          size    = "20Gi"
        }
      }
    })
  ]
}

# ---- OpenTelemetry Collector DaemonSet --------------------------------------
# Chart : opentelemetry-collector v0.133.0
#         https://open-telemetry.github.io/opentelemetry-helm-charts
#
# Runs on every node to collect:
#   - Container logs (filelog receiver → VictoriaLogs)
#   - kubelet stats / node metrics (kubeletstats receiver → VictoriaMetrics)
#   - Kubernetes events (k8s_events receiver → VictoriaLogs)
resource "helm_release" "opentelemetry_collector" {
  name       = "opentelemetry-collector"
  repository = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart      = "opentelemetry-collector"
  version    = "0.133.0"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  wait    = true
  timeout = 600

  values = [
    yamlencode({
      mode = "daemonset"

      image = {
        repository = "otel/opentelemetry-collector-contrib"
        tag        = "0.133.0"
      }

      # Host networking lets the collector reach the kubelet stats endpoint on
      # the node's primary IP without a separate NodePort Service.
      hostNetwork = true
      dnsPolicy   = "ClusterFirstWithHostNet"

      clusterRole = {
        create = true

        rules = [
          {
            apiGroups = [""]
            resources = [
              "pods", "pods/log", "nodes",
              "nodes/stats", "nodes/proxy",
              "namespaces", "events",
            ]
            verbs = ["get", "list", "watch"]
          },
          {
            apiGroups = ["apps"]
            resources = ["replicasets", "deployments", "daemonsets"]
            verbs     = ["get", "list", "watch"]
          },
          {
            nonResourceURLs = ["/stats/*", "/metrics"]
            verbs           = ["get"]
          }
        ]
      }

      config = {
        receivers = {
          # Tail container logs for mcp-registry pods from the node filesystem.
          filelog = {
            include           = ["/var/log/pods/default_mcp-registry*/*/*.log"]
            exclude           = ["/var/log/pods/*/*-collector-*/*.log"]
            start_at          = "end"
            include_file_path = true
            include_file_name = false

            operators = [
              {
                type = "regex_parser"
                id   = "extract_metadata_from_filepath"
                # Parse pod UID and container restart count from the log file path
                regex      = "^.*\\/[^_]+_[^_]+_(?P<uid>[a-f0-9\\-]{36})\\/[^\\._]+\\/(?P<restart_count>\\d+)\\.log"
                parse_from = "attributes[\"log.file.path\"]"

                cache = {
                  size = 128
                }
              },
              {
                type = "move"
                from = "attributes.restart_count"
                to   = "resource[\"k8s.container.restart_count\"]"
              },
              {
                type = "move"
                from = "attributes.uid"
                to   = "resource[\"k8s.pod.uid\"]"
              }
            ]
          }

          # Collect kubelet node and pod resource metrics via the Stats Summary API.
          kubeletstats = {
            collection_interval  = "60s"
            auth_type            = "serviceAccount"
            endpoint             = "https://$${env:KUBERNETES_NODE_NAME}:10250"
            insecure_skip_verify = true
          }

          # Collect Kubernetes API events (limited to the default namespace).
          k8s_events = {
            auth_type  = "serviceAccount"
            namespaces = ["default"]
          }
        }

        processors = {
          batch = {}

          # Drop metrics from namespaces other than 'default' to reduce cardinality.
          "filter/kubeletstats_filter" = {
            metrics = {
              datapoint = ["resource.attributes[\"k8s.namespace.name\"] != \"default\""]
            }
          }

          # Enrich telemetry with Kubernetes metadata (pod name, deployment, etc.)
          k8sattributes = {
            auth_type   = "serviceAccount"
            passthrough = false

            filter = {
              node_from_env_var = "KUBERNETES_NODE_NAME"
            }

            extract = {
              metadata = [
                "k8s.pod.name",
                "k8s.pod.uid",
                "k8s.deployment.name",
                "k8s.namespace.name",
                "k8s.node.name",
                "container.image.name",
                "container.image.tag",
              ]
            }

            pod_association = [
              { sources = [{ from = "resource_attribute", name = "k8s.pod.ip" }] },
              { sources = [{ from = "resource_attribute", name = "k8s.pod.uid" }] },
              { sources = [{ from = "connection" }] },
            ]
          }
        }

        exporters = {
          "otlphttp/victorialogs" = {
            logs_endpoint = "http://victoria-logs-victoria-logs-single-server:9428/insert/opentelemetry/v1/logs"

            headers = {
              VL-Msg-Field     = "body"
              VL-Time-Field    = "timestamp"
              VL-Stream-Fields = "k8s.namespace.name,k8s.pod.name,k8s.container.name,log.iostream"
            }

            timeout = "10s"

            retry_on_failure = {
              enabled          = true
              initial_interval = "5s"
              max_interval     = "30s"
              max_elapsed_time = "300s"
            }

            sending_queue = {
              enabled       = true
              num_consumers = 10
              queue_size    = 50
            }
          }

          "otlphttp/victoriametrics" = {
            metrics_endpoint = "http://victoria-metrics-victoria-metrics-single-server:8428/opentelemetry/v1/metrics"
            timeout          = "10s"

            retry_on_failure = {
              enabled          = true
              initial_interval = "5s"
              max_interval     = "30s"
              max_elapsed_time = "300s"
            }
          }
        }

        service = {
          pipelines = {
            logs = {
              receivers  = ["filelog", "k8s_events"]
              processors = ["k8sattributes", "batch"]
              exporters  = ["otlphttp/victorialogs"]
            }

            metrics = {
              receivers  = ["kubeletstats"]
              processors = ["k8sattributes", "filter/kubeletstats_filter", "batch"]
              exporters  = ["otlphttp/victoriametrics"]
            }
          }
        }
      }

      # Mount host paths so the filelog receiver can tail container log files
      # and the kubeletstats receiver can read /proc and /sys metrics.
      extraVolumes = [
        { name = "varlogpods", hostPath = { path = "/var/log/pods" } },
        { name = "varlibdockercontainers", hostPath = { path = "/var/lib/docker/containers" } },
        { name = "proc", hostPath = { path = "/proc" } },
        { name = "sys", hostPath = { path = "/sys" } },
      ]

      extraVolumeMounts = [
        { name = "varlogpods", mountPath = "/var/log/pods", readOnly = true },
        { name = "varlibdockercontainers", mountPath = "/var/lib/docker/containers", readOnly = true },
        { name = "proc", mountPath = "/host/proc", readOnly = true },
        { name = "sys", mountPath = "/host/sys", readOnly = true },
      ]

      # Inject the node name so the kubeletstats endpoint is resolved correctly.
      extraEnvs = [
        {
          name = "KUBERNETES_NODE_NAME"
          valueFrom = {
            fieldRef = {
              fieldPath = "spec.nodeName"
            }
          }
        }
      ]

      resources = {
        requests = {
          memory = "200Mi"
          cpu    = "100m"
        }

        limits = {
          memory = "400Mi"
          cpu    = "200m"
        }
      }

      # Allow the DaemonSet to run on control-plane nodes if present.
      tolerations = [
        {
          key      = "node-role.kubernetes.io/master"
          operator = "Exists"
          effect   = "NoSchedule"
        },
        {
          key      = "node-role.kubernetes.io/control-plane"
          operator = "Exists"
          effect   = "NoSchedule"
        }
      ]
    })
  ]

  depends_on = [
    helm_release.victoria_metrics,
    helm_release.victoria_logs,
  ]
}

# ---- Grafana PostgreSQL Cluster ---------------------------------------------
# Provides a persistent, managed PostgreSQL backend for Grafana's metadata
# (dashboards, users, annotations, playlists, etc.).
resource "kubernetes_manifest" "grafana_pg" {
  manifest = {
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "Cluster"

    metadata = {
      name      = "grafana-pg"
      namespace = kubernetes_namespace.monitoring.metadata[0].name

      labels = merge(local.common_labels, {
        app = "grafana-pg"
      })
    }

    spec = {
      instances = 1
      enablePDB = false

      storage = {
        size = "10Gi"
      }
    }
  }

  depends_on = [helm_release.cloudnative_pg]
}

# ---- Grafana secrets --------------------------------------------------------
resource "kubernetes_secret" "grafana_secrets" {
  metadata {
    name      = "grafana-secrets"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels    = local.common_labels
  }

  type = "Opaque"

  data = {
    GF_AUTH_GOOGLE_CLIENT_SECRET = var.google_oauth_client_secret
  }
}

# ---- Grafana datasources ConfigMap ------------------------------------------
# Provisioned as a file-based datasource so Grafana picks it up automatically
# on startup without requiring manual UI configuration.
resource "kubernetes_config_map" "grafana_datasources" {
  metadata {
    name      = "grafana-datasources"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels    = local.common_labels
  }

  data = {
    "datasources.yaml" = yamlencode({
      apiVersion = 1

      datasources = [
        {
          name      = "VictoriaMetrics"
          type      = "prometheus"
          url       = "http://victoria-metrics-victoria-metrics-single-server:8428"
          access    = "proxy"
          isDefault = true
        },
        {
          name   = "VictoriaLogs"
          type   = "victoriametrics-logs-datasource"
          url    = "http://victoria-logs-victoria-logs-single-server:9428"
          access = "proxy"

          jsonData = {
            maxLines = 1000
          }
        }
      ]
    })
  }
}

# ---- Grafana Helm release ---------------------------------------------------
# Chart : grafana v9.4.4   https://grafana.github.io/helm-charts
#
# Configured with:
#   - Google OAuth SSO (restricted to modelcontextprotocol.io domain)
#   - Disabled local login form and basic auth
#   - PostgreSQL backend (grafana-pg CNPG cluster)
#   - VictoriaMetrics + VictoriaLogs datasources via ConfigMap provisioning
resource "helm_release" "grafana" {
  name       = "grafana"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "grafana"
  version    = "9.4.4"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  wait    = true
  timeout = 600

  values = [
    yamlencode({
      plugins = ["victoriametrics-logs-datasource"]

      # Mount the datasources ConfigMap into the provisioning directory.
      extraConfigmapMounts = [
        {
          name      = "grafana-datasources"
          mountPath = "/etc/grafana/provisioning/datasources"
          configMap = kubernetes_config_map.grafana_datasources.metadata[0].name
          readOnly  = true
        }
      ]

      "grafana.ini" = {
        server = {
          root_url = "https://${local.grafana_host}"
        }

        auth = {
          disable_login_form = true
        }

        "auth.basic" = {
          enabled = false
        }

        security = {
          disable_initial_admin_creation = true
        }

        users = {
          # All authenticated users are automatically assigned the Admin role;
          # access is restricted at the OAuth layer to the hosted domain.
          auto_assign_org_role = "Admin"
        }

        "auth.google" = {
          enabled         = true
          client_id       = "606636202366-tpjm7d5vpp4lp9helg5ld2vrcafnrgh7.apps.googleusercontent.com"
          hosted_domain   = "modelcontextprotocol.io"
          allowed_domains = "modelcontextprotocol.io"
          # Do not sync the Grafana org role from the Google token on every login.
          skip_org_role_sync = true
        }

        database = {
          type = "postgres"
          # CNPG exposes a read-write Service named "<cluster>-rw".
          host = "grafana-pg-rw:5432"
        }
      }

      # Inject database credentials from the CNPG-generated secret.
      # CNPG creates "<cluster>-app" with keys: username, password, dbname.
      envValueFrom = {
        GF_AUTH_GOOGLE_CLIENT_SECRET = {
          secretKeyRef = {
            name = kubernetes_secret.grafana_secrets.metadata[0].name
            key  = "GF_AUTH_GOOGLE_CLIENT_SECRET"
          }
        }

        GF_DATABASE_USER = {
          secretKeyRef = {
            name = "grafana-pg-app"
            key  = "username"
          }
        }

        GF_DATABASE_PASSWORD = {
          secretKeyRef = {
            name = "grafana-pg-app"
            key  = "password"
          }
        }

        GF_DATABASE_NAME = {
          secretKeyRef = {
            name = "grafana-pg-app"
            key  = "dbname"
          }
        }
      }

      resources = {
        requests = {
          memory = "128Mi"
          cpu    = "50m"
        }

        limits = {
          memory = "256Mi"
        }
      }
    })
  ]

  depends_on = [
    kubernetes_manifest.grafana_pg,
    kubernetes_secret.grafana_secrets,
    kubernetes_config_map.grafana_datasources,
  ]
}

# ---- Grafana Ingress --------------------------------------------------------
resource "kubernetes_ingress_v1" "grafana" {
  metadata {
    name      = "grafana-ingress"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels    = local.common_labels

    annotations = {
      "cert-manager.io/cluster-issuer" = "letsencrypt-prod"
      "kubernetes.io/ingress.class"    = "nginx"
    }
  }

  spec {
    tls {
      hosts       = [local.grafana_host]
      secret_name = "grafana-tls"
    }

    rule {
      host = local.grafana_host

      http {
        path {
          path      = "/"
          path_type = "Prefix"

          backend {
            service {
              name = "grafana"

              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }

  depends_on = [
    helm_release.ingress_nginx,
    kubernetes_manifest.cluster_issuer_letsencrypt,
    helm_release.grafana,
  ]
}
