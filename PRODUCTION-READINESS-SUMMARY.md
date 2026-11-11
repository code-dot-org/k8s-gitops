# Production readiness: executive summary

One-page view of [PRODUCTION-READINESS.md](PRODUCTION-READINESS.md) (the full
review) and [PRODUCTION-READINESS-TASKS.md](PRODUCTION-READINESS-TASKS.md)
(the work list).

## Bottom line

The new Kubernetes cluster (`codeai-k8s`) is a solid pre-production platform,
but it is not yet ready to carry production work. The first workload is
deliberately small and low risk: background job workers that process only the
lowest-priority queue. Even so, nine checks and eleven fixes need to land
before the first production job runs. Most of the gaps are about being able to
see and recover from failure, not about the cluster falling over.

## What is launching

Code.org's web app runs background jobs (emails, AI lesson summaries, data
cleanup) on a single legacy server. We plan to move the lowest-priority slice
of that work, currently two job types, onto the cluster. Nothing user-facing
moves. If the cluster workers stop, those jobs queue up or are picked up by
the legacy server, depending on a decision below.

## Where we stand

| Area                 | Status          | In one line                                                                                                                              |
| -------------------- | --------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| Deployment pipeline  | Good            | Automated, auditable deploys with a manual gate before production.                                                                       |
| Secrets handling     | Good, one gap   | Per-environment isolation is right; production's database secrets are wired to the wrong legacy name.                                    |
| Worker configuration | Gaps            | Jobs can be killed mid-run on routine restarts; error reporting is switched off; the worker has no cloud identity.                       |
| Monitoring           | Gaps            | Dashboards exist. There are zero alerts for this cluster, and no log collection.                                                         |
| Cluster security     | Gaps            | Audit logging is off; the control plane is reachable from any network; all environments share one network boundary with production data. |
| Scaling              | Fine for launch | Fixed worker count is enough. Smarter queue-based scaling is a later improvement.                                                        |
| Disaster recovery    | Acceptable      | The cluster is rebuilt from code but the runbook is stale and nothing protects it from accidental deletion.                              |

## Must happen before launch

1. **Let jobs finish on shutdown.** Today a routine deploy or node replacement
   can kill a job after 30 seconds and lock it for four hours. Fix: a longer
   shutdown window in the deployment config.
2. **Turn error reporting back on.** A leftover development setting blanks
   the Honeybadger and Sentry keys in every environment, so failures would be
   invisible.
3. **Give the worker a cloud identity.** Without one it cannot publish
   metrics, read feature flags, or reach storage.
4. **Point production at the right database secrets.** The legacy stack is
   named differently from the environment, and the automation does not
   account for it.
5. **One alert that proves work is flowing.** A test job every few minutes,
   with a page if none complete, routed to a channel someone reads.
6. **Turn on audit logging** for the cluster control plane.
7. **Agree a version rule.** Database schema changes still come from the
   legacy deploy, so the cluster must never run code newer than legacy
   production.
8. **Nine live checks** to confirm assumptions made from reading code
   (which secrets exist, whether the metrics service is installed, image
   architecture, and so on).

## Decisions we need from you

- **Soft launch or hard cutover?** Should the legacy server keep processing
  low-priority jobs alongside the cluster (safer, but hides cluster failures),
  or hand them over entirely?
- **Who owns it.** Which team receives the alerts, and what is the service
  target for low-priority work (proposal: 95 percent of jobs start within
  four hours).
- **Access tightening.** Today every engineer has full administrative access
  to the cluster and can deploy or delete production from the deployment UI.
  Narrowing this to the infrastructure group is recommended and is a policy
  change, not just a technical one.
- **Cost acceptance.** Audit logs, log retention, and a dedicated production
  node pool are small recurring costs that were deferred while the cluster was
  experimental.

## After launch

- **First weeks (41 items):** full alert coverage and log collection, network
  isolation between environments, a dedicated production node pool,
  automated checks on this repository, and runbooks.
- **Later (17 items):** queue-based autoscaling, image signing and admission
  policies, cost tagging, and tighter coupling of application code and
  deployment config in the release pipeline.

## Shape of the work

The pre-launch work touches three repositories (this one, the main
application, and the observability repo) and needs reviewers in each. The
largest items are the worker's cloud identity and the production secrets
wiring; the rest are small, well-understood changes. The team should size it,
but nothing here is research; every item has a known fix and a named file.
