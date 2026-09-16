# Scope of the current work

Write and validate local files in `k8s-gitops` and `infrastructure`. Repository
definitions and OpenTofu output references supply the configuration inputs.
Live AWS identity, workspace inventory, scraper inventory, and EKS details are
not prerequisites for this implementation. No AWS commands, live plans, applies,
pushes, merges, or Argo refreshes/syncs are authorized for this work.

The original task IDs are retained below. All eight local implementation tasks
are complete; six future rollout tasks remain unchecked and explicitly deferred.

## 2. Implement the metrics collector in k8s-gitops

- [x] 2.1 [Agent] Add the monitoring Argo application outside the infra bootstrap group and a wrapper chart with pinned standalone Alloy/kube-state-metrics dependencies. Support reusing an existing exporter through configuration; configure single-replica Deployments with Recreate updates for newly installed components and no clustering, autoscaling, or operator. Bump chart versions as required.
- [x] 2.2 [Agent] Add scoped collector workload IAM and Kubernetes read access using existing patterns. Write the OpenTofu handoff that resolves the AMP destination from infrastructure's existing outputs and includes it in generated cluster values, with no manually configured ARNs or IDs. Configure authenticated TLS, validate missing inputs, and keep static AWS keys and Grafana administrative credentials out of the cluster. Leave publication and live verification for rollout.
- [x] 2.3 [Agent] Configure kube-state-metrics, kubelet/cAdvisor, and collector-health scraping with a 60-second interval, explicit metric allowlist, and cluster/source labels. Avoid duplicate targets and application endpoints; exclude logs, traces, node-exporter, and application instrumentation.
- [x] 2.4 [Agent] Set collector/exporter resource requests and limits, scheduling, and a size-limited ephemeral write-ahead log (WAL) with finite retention. Document update/outage data gaps and pod-replacement loss; provision no persistent storage.

## 3. Add one dashboard in infrastructure

- [x] 3.1 [Agent] Add one Kubernetes overview builder/registry entry and OpenTofu dashboard resource with a stable identifier, direct Prometheus queries, and cluster/namespace/pod filtering. Cover the agreed v1 signals and explicit missing/stale data; add no recording rules, alerts, or notification routes.
- [x] 3.2 [Agent] Run lockfile-based dependency installation, type checking, dashboard generation, and local OpenTofu validation without accessing live state or AWS. Preserve existing data-source references and shared consumers; leave CI and shared workspace lifecycle unchanged. Defer the live plan and deployed-plugin compatibility checks to rollout.

## 4. Validate and document the local implementation

- [x] 4.1 [Agent] Render and validate the chart/collector configuration and review both repository changes for the v1 boundary: no code-dot-org edits or application overrides, deferred components, or application startup dependency. Confirm normal monitoring removal preserves shared stores.
- [x] 4.5 [Agent] Document the expected dashboard URL, owners, future deployment commands, metric inputs, rough cost scenarios, single-collector/no-alerting limitations, and rollback procedure. Record logs/events, alerting, reliability improvements, and CI as separate follow-ups. Label all live checks as deferred rather than prerequisites for writing files.

## Deferred rollout work — outside the current task

These tasks require a separately authorized rollout. They are not requests for
the user to gather data now and do not block completion of the local files.

- [ ] 1.1 [Deferred] Verify Amazon Managed Grafana (AMG) query/provisioning access and deployed-plugin compatibility with the existing Amazon Managed Service for Prometheus (AMP) data source. Review the live infrastructure and cluster-config plans, preserving existing consumers.
- [ ] 1.2 [Deferred] Check existing collectors/exporters, workload IAM, and authenticated kubelet/cAdvisor access across expected nodes. Select exporter reuse or installation and refine the rough cost scenarios with actual inventory.
- [ ] 1.3 [Deferred] Resolve any access gaps and agree an incremental spending limit before enabling ingestion.
- [ ] 4.2 [Deferred] Apply reviewed plans, publish generated values, and deploy monitoring through Git/ArgoCD. After an authorized push, refresh the affected Application and sync if it has not reached the intended revision.
- [ ] 4.3 [Deferred] Verify dashboard coverage against Kubernetes inventory, including frontend nodes; check container CPU/memory, workload availability/restarts, filters, freshness across several scrape intervals, and existing dashboard compatibility.
- [ ] 4.4 [Deferred] Exercise one controlled collector restart/update and verify collection resumes. Record any gap, collector resource use, initial series/sample volume, and projected incremental cost with assumptions; reduce scope or disable collection if it exceeds the agreed budget.

## Implementation checkpoint (2026-09-16)

8/8 local implementation tasks complete. The full lifecycle checklist is 8/14;
the remaining six tasks are deferred rollout work, not implementation blockers.
See [validation.md](validation.md) for local evidence and deferred live checks.
