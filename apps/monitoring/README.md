# Kubernetes monitoring

This chart collects Kubernetes infrastructure metrics and sends them to an
existing **Amazon Managed Service for Prometheus (AMP)** workspace.

## Components

- **Grafana Alloy** scrapes kubelet, cAdvisor, kube-state-metrics, and its own
  health metrics every 60 seconds. Metric and label allowlists limit what is sent
  to AMP.
- **kube-state-metrics** optionally exposes node, pod, and workload state. An
  existing exporter can be used instead.
- **Access configuration** provides Kubernetes read permissions and a dedicated
  IAM role managed through Crossplane, scoped to writing metrics to the selected
  AMP workspace.

Collected metrics cover node readiness, workload replicas, pod status and
restarts, container CPU and memory usage, and collector health.

## Configuration

Collection and the bundled exporter are enabled in [values.yaml](values.yaml).
AMP connection settings and cluster identity come from the generated cluster
values loaded by [application.yaml](application.yaml).

See [chart/values.yaml](chart/values.yaml) for collector and exporter defaults,
including resource limits and the address of an existing kube-state-metrics
exporter.
