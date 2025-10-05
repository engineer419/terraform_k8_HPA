terraform {
  required_version = ">= 1.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.25"
    }
  }
}

variable "project_id" {
  description = "GCP Project ID"
  type        = string
  default     = "k8-cognitive-universe"
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "GCP zone"
  type        = string
  default     = "us-central1-a"
}

variable "cluster_name" {
  description = "GKE cluster name"
  type        = string
  default     = "my-gke-cluster"
}

variable "monitoring_namespace" {
  description = "Kubernetes namespace for monitoring"
  type        = string
  default     = "monitoring"
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# Data source for cluster authentication
data "google_client_config" "default" {}

# VPC Network
resource "google_compute_network" "vpc" {
  name                    = "${var.cluster_name}-vpc"
  auto_create_subnetworks = false
}

# Subnet for GKE cluster
resource "google_compute_subnetwork" "subnet" {
  name          = "${var.cluster_name}-subnet"
  ip_cidr_range = "10.0.0.0/24"
  region        = var.region
  network       = google_compute_network.vpc.id

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.1.0.0/16"
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.2.0.0/16"
  }
}

# GKE Cluster
resource "google_container_cluster" "primary" {
  name     = var.cluster_name
  location = var.zone

  remove_default_node_pool = true
  initial_node_count       = 1

  network    = google_compute_network.vpc.name
  subnetwork = google_compute_subnetwork.subnet.name

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  deletion_protection = false
}

# Separately managed node pool
resource "google_container_node_pool" "primary_nodes" {
  name       = "${var.cluster_name}-node-pool"
  location   = var.zone
  cluster    = google_container_cluster.primary.name
  node_count = 2

  node_config {
    machine_type = "e2-medium"
    disk_size_gb = 20
    disk_type    = "pd-standard"

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]

    labels = {
      noderefresh = "target"
    }

    metadata = {
      disable-legacy-endpoints = "true"
    }
  }
}

# Kubernetes provider
provider "kubernetes" {
  host                   = "https://${google_container_cluster.primary.endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(google_container_cluster.primary.master_auth[0].cluster_ca_certificate)
}

# Helm provider
provider "helm" {
  kubernetes {
    host                   = "https://${google_container_cluster.primary.endpoint}"
    token                  = data.google_client_config.default.access_token
    cluster_ca_certificate = base64decode(google_container_cluster.primary.master_auth[0].cluster_ca_certificate)
  }
}

# Create monitoring namespace
resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = var.monitoring_namespace
  }

  depends_on = [google_container_node_pool.primary_nodes]
}

# Install Prometheus
resource "helm_release" "prometheus" {
  name       = "prometheus"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = "65.1.1"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  values = [
    <<-EOT
    prometheus:
      prometheusSpec:
        serviceMonitorSelectorNilUsesHelmValues: false
        podMonitorSelectorNilUsesHelmValues: false
        retention: 7d
        resources:
          requests:
            cpu: 200m
            memory: 512Mi
          limits:
            cpu: 500m
            memory: 1Gi
    
    grafana:
      enabled: true
      adminPassword: "admin"
      service:
        type: LoadBalancer
      resources:
        requests:
          cpu: 100m
          memory: 256Mi
        limits:
          cpu: 200m
          memory: 512Mi
    
    alertmanager:
      enabled: false
    EOT
  ]
}

# Install KEDA with Prometheus metrics
resource "helm_release" "keda" {
  name       = "keda"
  repository = "https://kedacore.github.io/charts"
  chart      = "keda"
  version    = "2.14.0"
  namespace  = "kube-system"

  values = [
    <<-EOT
    prometheus:
      metricServer:
        enabled: true
        serviceMonitor:
          enabled: true
      operator:
        enabled: true
        serviceMonitor:
          enabled: true
      webhooks:
        enabled: true
        serviceMonitor:
          enabled: true
    
    resources:
      operator:
        limits:
          cpu: 500m
          memory: 512Mi
        requests:
          cpu: 100m
          memory: 256Mi
      metricServer:
        limits:
          cpu: 500m
          memory: 512Mi
        requests:
          cpu: 100m
          memory: 256Mi
    EOT
  ]

  depends_on = [helm_release.prometheus]
}

# Outputs
output "cluster_name" {
  value = google_container_cluster.primary.name
}

output "cluster_endpoint" {
  value     = google_container_cluster.primary.endpoint
  sensitive = true
}

output "get_credentials_command" {
  value = "gcloud container clusters get-credentials ${google_container_cluster.primary.name} --zone ${var.zone} --project ${var.project_id}"
}

output "vpc_name" {
  value = google_compute_network.vpc.name
}

output "subnet_name" {
  value = google_compute_subnetwork.subnet.name
}

output "grafana_info" {
  value = "kubectl get svc -n ${var.monitoring_namespace} prometheus-grafana -o jsonpath='{.status.loadBalancer.ingress[0].ip}'"
}

output "view_keda_deployments" {
  value = "kubectl get deployments -n kube-system -l app.kubernetes.io/name=keda"
}

output "access_prometheus" {
  value = "kubectl port-forward -n ${var.monitoring_namespace} svc/prometheus-kube-prometheus-prometheus 9090:9090"
}

output "instructions" {
  value = <<-EOT
    Cluster ready with Prometheus + KEDA!
    
    1. Get Grafana IP: kubectl get svc -n monitoring prometheus-grafana
    2. Login: admin/admin
    3. View KEDA metrics: Search for "keda_" in Explore
    4. Check KEDA: kubectl get pods -n kube-system -l app.kubernetes.io/name=keda
  EOT
}