# VHI EKS Architecture Review — Consolidated Report

**Prepared by**: heniab@ - Technical Account Manager
**Date**: 6 May 2026  
**Clusters Reviewed**:

| Cluster | Account | Region | Scope |
|---------|---------|--------|-------|
| vhi-ss-ocp-dev-eu-west-1-eks-001 | 971505802043 | eu-west-1 | Full (infrastructure + workload) |
| vhi-ss-ocp-prod-eu-west-1-eks-001 | 918931972413 | eu-west-1 | Infrastructure only (API-level) |

---

## Executive Summary

This review assessed both EKS clusters across six pillars: Networking, Security, Scalability, Reliability, Cost Optimisation, and Karpenter/Auto Mode configuration. Both clusters run EKS Auto Mode on Kubernetes 1.33 with Bottlerocket nodes.

**Key Strengths:**
- EKS Auto Mode with logical NodePool separation (application, infrastructure, data, sensitive workloads)
- Private-only API server endpoint (both clusters)
- Per-AZ NAT Gateways and Network Firewall in production
- All control plane logging enabled
- Bottlerocket OS with 21-day automatic node rotation

**Priority Findings:**

| # | Finding | Impact | Effort |
|---|---------|--------|--------|
| 1 | Security groups overly permissive (10.0.0.0/8 ALL inbound) | Security risk — both clusters | Low |
| 2 | Missing VPC endpoints (ECR, STS, Logs, EC2, ELB) | Unnecessary NAT costs + latency | Low |
| 3 | HPA broken for all Kong API Gateways (dev) | Cannot scale under load | Low |
| 4 | ECR image pull failures — 514 events over 44h (dev) | Pods stuck, deployments blocked | Medium |
| 5 | OPA Gatekeeper crashed 44h+ — zero policy enforcement (dev) | Compliance gap | Medium |
| 6 | All NodePools locked to amd64/on-demand/m5a | ~20% cost premium, no Graviton path | Medium |
| 7 | 10x CPU overcommitment vs actual usage (dev) | Wasted spend, scheduling fragility | Medium |
| 8 | No Pod Disruption Budgets on critical infrastructure (dev) | Risk during node maintenance | Low |
| 9 | Single NAT Gateway in dev (cross-AZ charges + SPOF) | $165–355/month avoidable cost | Low |
| 10 | Subnet IP exhaustion risk in prod eu-west-1c (38 IPs) | Pod scheduling failures at scale | Medium |

---

## 1. Networking

### 1.1 Security Groups

Both clusters share the same Terraform-generated security group pattern with an overly permissive inbound rule.

**Current State (both clusters):**

| Protocol | Port Range | Source | Description |
|----------|-----------|--------|-------------|
| ALL | — | Self-referencing | EFA traffic |
| ALL | — | 10.0.0.0/8 | "Temp - All Private traffic" |
| TCP | 443–8443 | Target group binding SG | Load balancer health checks |

**Recommendation — Minimal EKS Security Group Configuration:**

Cluster SG (Inbound):

| Protocol | Port Range | Source | Purpose |
|----------|-----------|--------|---------|
| ALL | — | Cluster SG (self) | Control plane ↔ control plane |
| TCP | 443 | Nodes SG | Nodes → API server |

Nodes SG (Inbound):

| Protocol | Port Range | Source | Purpose |
|----------|-----------|--------|---------|
| ALL | — | Nodes SG (self) | Node-to-node (pod traffic, DNS) |
| TCP | 1025–65535 | Cluster SG | Control plane → nodes (webhooks, exec) |
| TCP | 443 | Cluster SG | Control plane → nodes (kubelet API) |

**Actions:**
- Remove `10.0.0.0/8 ALL` inbound — replace with specific Nodes SG reference
- Remove stale SG references (dev: `sg-0fbfaf8cf33ba6639` no longer exists)
- Keep `0.0.0.0/0` ALL egress (pods need internet via NAT)
- Keep target group binding rule for load balancer health checks

### 1.2 NAT Gateways

| Aspect | Dev | Prod |
|--------|-----|------|
| NAT Gateways | 1 (eu-west-1a only) | 3 (per-AZ) ✅ |
| Cross-AZ cost | $547–888/month | Eliminated |
| Resilience | Single point of failure | AZ-independent |

**Dev cluster cross-AZ data transfer (Cost Explorer):**

| Month | Volume | Cost |
|-------|--------|------|
| Feb 2026 | ~99 TB | $888 |
| Mar 2026 | ~85 TB | $768 |
| Apr 2026 | ~58 TB | $547 |

**Recommendation:** Deploy per-AZ NAT Gateways in dev (~$86/month additional cost, $165–355/month savings). Prod already has this correctly configured.

**Note:** AWS released Regional NAT Gateways (~6 months ago) which simplify this further — a single regional NAT Gateway replaces the need for per-AZ deployment. This reduces Terraform complexity and eliminates per-AZ troubleshooting. Consider adopting regional NAT when refreshing firewall infrastructure.

### 1.3 VPC Endpoints

Both clusters are missing interface endpoints for high-frequency AWS API calls:

| Service | Dev | Prod | Impact |
|---------|-----|------|--------|
| S3 (Gateway) | ✅ | ✅ | Free |
| DynamoDB (Gateway) | ✅ | ✅ | Free |
| ECR API | ❌ | ❌ | Image pull API calls via NAT |
| ECR Docker | ❌ | ❌ | Image layer downloads via NAT |
| STS | ❌ | ❌ | Token refresh via NAT |
| CloudWatch Logs | ❌ | ❌ | Log shipping via NAT |
| EC2 | ❌ | ❌ | Instance metadata API via NAT |
| ELB | ❌ | ❌ | Load balancer API via NAT |
| execute-api | ✅ | ❌ | API Gateway calls (inconsistency) |

**Recommendation:** Add ECR, STS, and Logs endpoints as priority (highest traffic volume). Estimated savings: $50–200/month per cluster for clusters of this size.

### 1.4 Load Balancers — Instance Target Type

All 4 NLBs in dev use **instance** target type (default):

| Issue                             | Impact                                     |
| --------------------------------- | ------------------------------------------ |
| Extra network hop via NodePort    | +1–2ms latency per request                 |
| Source IP lost (SNAT at NodePort) | Cannot implement IP-based access control   |
| Cross-AZ traffic from kube-proxy  | Additional data transfer charges           |

**Recommendation:** Migrate to **IP target type** (`service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip`). Routes directly to pod IP — lower latency, preserves source IP, eliminates extra hop.

### 1.5 Network Policies

Dev cluster has 176 network policies — all **ingress only**:
- ✅ Ingress restricted to same-namespace + ingress controllers
- ❌ No egress policies anywhere
- ❌ 20+ namespaces have zero network policies

**Risk:** A compromised pod can reach any external endpoint, other namespaces, and the AWS metadata service.

**Recommendation:** Add default-deny egress per namespace, then allow DNS (port 53 to kube-dns) and specific application egress.

### 1.6 Subnet IP Availability

| Cluster | Subnet | AZ | Available IPs | Risk |
|---------|--------|-----|---------------|------|
| Prod | subnet-078252c623f32afc4 | eu-west-1c | 38 | ⚠️ Low — may hit exhaustion during scale events |
| Dev | All subnets | All AZs | OK | No immediate risk |

**Update from review discussion:** The team has already implemented separate subnets for pods and nodes (configured via NodeClass subnet selectors with different tags). This significantly mitigates IP exhaustion risk since the bulk of IP consumption comes from pods, which now use dedicated larger subnets.

**Remaining recommendation:** Consider separating control plane subnets from node subnets as an additional safeguard. The control plane requires ~16 IPs during upgrades (rolling update creates new instances before terminating old ones). If node subnets exhaust during a horizontal scaling event, this could impact a concurrent control plane operation.

Monitor VPC CNI `awscni` metrics for IP warmpool. Consider secondary CIDR or larger subnets for prod eu-west-1c.

---

## 2. Security

### 2.1 IAM Roles

Both clusters have well-structured IAM with proper tag-based conditions. One finding common to both:

**Redundant custom policy:** Both clusters have a Terraform-generated custom policy that duplicates permissions already provided by AWS-managed EKS Auto Mode policies (AmazonEKSComputePolicy, AmazonEKSNetworkingPolicy, etc.).

| Cluster | Custom Policy                                             | Recommendation                                                                                           |
| ------- | --------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| Dev     | `vhi-ss-ocp-dev-cluster-role-20250619104051095900000001`  | Remove entirely (fully redundant)                                                                        |
| Prod    | `vhi-ss-ocp-prod-cluster-role-20250903093524852000000002` | Remove Compute/Storage/Networking/LB statements. **Keep Shield statements** if Shield Advanced is active |

**Prod-specific:** KMS encryption policy correctly scoped to key `36f4f000-883d-4992-9940-f877c2e35fbf`.

### 2.2 Workload Identity (Dev)

| Component                            | Status                            |
| ------------------------------------ | --------------------------------- |
| IRSA bindings                        | Only 3 (EFS CSI + OTel collector) |
| Application workloads with IAM roles | 0                                 |

**Risk:** Application pods use the node instance role — blast radius of a compromised pod extends to full node permissions.

**Recommendation:** Adopt EKS Pod Identity for application workloads. Start with services that access AWS APIs (S3, SQS, Secrets Manager).

### 2.3 OPA Gatekeeper (Dev)

| Instance | Status | Impact |
|----------|--------|--------|
| opa-gatekeeper (prod-labelled) | ❌ CrashLoopBackOff 44h+ | Zero enforcement |
| opa-gatekeeper-dev | ✅ Running | Audit only (all constraints set to `warn`) |

All 29 policy constraints are in `warn` mode — 2,896 violations detected but none blocked:

| Constraint | Violations |
|-----------|-----------|
| Privilege escalation allowed | 1,166 |
| SA token auto-mounted | 824 |
| Missing resource requests | 455 |
| Missing CPU/memory limits | 398 |
| Unapproved image repos | 46 |
| `:latest` tag used | 7 |

**Recommendation:** Fix the crashed Gatekeeper instance. Develop a phased enforcement plan — start with `deny` on highest-risk constraints (privilege escalation, unapproved repos) in non-production namespaces first.

---

## 3. Scalability (Dev)

### 3.1 HPA Status

| HPA | Status | Root Cause |
|-----|--------|-----------|
| Kong External Enterprise | ❌ Broken | No CPU request on container |
| Kong External Manager | ❌ Broken | No CPU request on container |
| Kong Internal Enterprise | ❌ Broken | No CPU request on container |
| Kong Internal Manager | ❌ Broken | No CPU request on container |
| istiod | ✅ Working | CPU at 27%, scaling 3↔5 |

**Impact:** All API traffic flows through Kong gateways that cannot auto-scale. A traffic spike will saturate pods.

**Fix:** Add CPU/memory requests to Kong containers. Example:
```yaml
resources:
  requests:
    cpu: 500m
    memory: 512Mi
  limits:
    cpu: 2000m
    memory: 2Gi
```

### 3.2 Istiod HPA Thrashing

Istiod scales up and down every 15–20 minutes — classic HPA thrashing. With 628 sidecars, each scale event triggers xDS config pushes to all proxies.

**Root cause:** CPU/memory-based HPA thresholds often do not reflect actual application load. CPU spikes can be caused by garbage collection, background tasks, or burst processing — none of which indicate the application needs more replicas.

**Recommendation — two changes:**

1. **Use external metrics instead of CPU/memory.** Choose metrics that reflect actual load for each application type:
   - API gateways (Kong): requests per second, active connections
   - Service mesh (istiod): connected proxies, xDS push queue depth
   - Event consumers (dd-consumer): queue depth, consumer lag
   - Web APIs: HTTP request rate, concurrent connections

2. **Add stabilisation window** to prevent rapid scale-down:
```yaml
behavior:
  scaleDown:
    stabilizationWindowSeconds: 300
    policies:
    - type: Pods
      value: 1
      periodSeconds: 60
```

The combination of meaningful metrics + stabilisation window eliminates thrashing while maintaining responsive scale-up.

### 3.3 Resource Requests and Limits — Set Equal Values

As a best practice in EKS Auto Mode, resource requests and limits should be set to **equal values**. This ensures:

1. **Guaranteed QoS class** — pods with equal requests and limits are the last to be evicted by the OOM killer
2. **No overcommitment risk** — if a pod requests 1Gi memory but has a 2Gi limit, the scheduler places it on a node with 1.5Gi free. If memory usage grows beyond 1.5Gi, the pod (or neighbours) get OOM-killed
3. **Predictable scheduling** — Karpenter uses requests to determine node sizing. Mismatched values lead to nodes that appear to have capacity but don't

**Current state:** Most pods have requests ≠ limits, with limits often 2–10x higher than requests. This creates a 10x CPU overcommitment across the fleet.

**Recommendation:** Set requests = limits for all workloads. Use actual usage data (p95 over 7 days from Datadog) to determine the correct value. Where Helm charts are used, consider exposing a single resource value that applies to both request and limit — this prevents developers from setting mismatched values.

### 3.4 Resource Overcommitment

| Metric | Value |
|--------|-------|
| Total Allocatable (28 nodes) | 220 vCPU / 900 Gi |
| Total Requests | 200 vCPU (91%) / 450 Gi (50%) |
| Total Actual Usage | 22 vCPU (10%) / 420 Gi (47%) |
| Request Efficiency (Actual/Requests) | 11% CPU / 93% Memory |

CPU requests are 10x higher than actual usage. Memory is well-sized.

**Recommendation:** Right-size CPU requests based on actual usage (p95 over 7 days). Consider deploying VPA in recommendation mode to generate sizing data.

### 3.4 BestEffort Pods (Zero Requests)

55 pods have zero CPU and memory requests — invisible to the scheduler and first to be evicted:

| Category | Count | Risk |
|----------|-------|------|
| Kong API Gateway pods | 8 | Critical — all traffic flows through these |
| EFS CSI Node DaemonSet | 28 | Critical — storage mounts fail if evicted |
| Schema Registry | 8 | High — data pipeline validation |
| Argo Rollouts | 11 | Low — deployment tooling |

**Recommendation:** Add resource requests to all Kong and EFS CSI pods immediately. Use actual usage metrics as baseline.

---

## 4. Reliability (Dev)

### 4.1 ECR Image Pull Failures

514 `FailedToRetrieveImagePullSecret` events over 44 hours. Root cause: static ECR auth token (`ecr-docker-secret`) expired and is not being rotated.

**Fix:** Migrate to IRSA/Pod Identity for ECR authentication — eliminates token expiry entirely.

### 4.2 CrashLoopBackOff Pods

54 pods in CrashLoopBackOff. Key patterns:

| Service | Restarts | Environments Affected |
|---------|---------|----------------------|
| eligibilities-service | 640+ | dev, test4 (systemic) |
| payments-controls-service | 755 | training |
| OPA Gatekeeper (prod instance) | 382–523 | All 3 pods |
| okta myvhi-login-capi | 526 | training |

**Recommendation:** Prioritise `eligibilities-service` (systemic across environments) and OPA Gatekeeper (security impact).

### 4.3 Pod Disruption Budgets

Only 4 PDBs protecting 864 pods. Critical multi-replica deployments without PDBs:

| Deployment | Replicas | Risk |
|-----------|---------|------|
| nginx-ingress-external | 3 | External traffic entry point |
| nginx-ingress-internal | 4 | Internal traffic entry point |
| Kong gateways (×4) | 2 each | API gateway |
| EFS CSI controller | 2 | Storage operations |

**Recommendation:** Add PDBs with `minAvailable: 1` (or `maxUnavailable: 1` for larger deployments) to all infrastructure components.

### 4.4 Health Probes

| Probe Type | Coverage |
|-----------|---------|
| Readiness | 88% ✅ |
| Liveness | 56% ⚠️ |
| Startup | <1% ❌ |

35 deployments have zero probes. Additionally, `dd-consumer-*` handlers use aggressive `periodSeconds=3` on liveness — likely causing unnecessary restarts (528+ restarts observed).

**Recommendation:** Add startup probes for slow-starting applications. Relax liveness probe timing to `periodSeconds: 10` with appropriate failure thresholds.

---

## 5. Cost Optimisation

### 5.1 Estimated Annual Savings Opportunity

| Opportunity | Estimated Annual Savings | Effort |
|-------------|------------------------|--------|
| Graviton migration (arm64 NodePools) | $30,000–45,000 | Medium |
| Spot instances for dev/test workloads | $20,000–30,000 | Medium |
| Per-AZ NAT Gateways (dev) | $2,000–4,000 | Low |
| VPC endpoints (ECR, STS, Logs) | $1,200–4,800 | Low |
| Right-sizing CPU requests | $10,000–15,000 | Medium |
| IP target type (eliminate cross-AZ LB hops) | $1,000–2,000 | Low |
| **Total estimated** | **$64,000–101,000** | |

### 5.2 NodePool Configuration — Locked to Expensive Options

| Constraint | Current | Recommended |
|-----------|---------|-------------|
| Architecture | amd64 only | Add arm64 (Graviton ~20% cheaper) |
| Capacity Type | on-demand only | Add spot for dev/test pools |
| Instance Generation | m5a (gen 5) | Require gen 6+ (m6a/m7a/r6a) |
| Encryption in Transit | Not supported (m5a) | Supported on gen 6+ |

### 5.3 Idle/Broken Pods

91 pods in non-functional states consuming node capacity:
- 54 CrashLoopBackOff — consuming restart cycles
- 38 ImagePullBackOff — holding resource requests
- OPA Gatekeeper audit pod using 1363m CPU while crashing

---

## 6. Karpenter / EKS Auto Mode

### 6.1 NodePool Architecture

| Pool | Nodes (Dev) | Purpose | Disruption Policy |
|------|-------------|---------|-------------------|
| vhi-general-purpose-pool | 13 | Application workloads | WhenEmptyOrUnderutilized |
| vhi-infra-pool | 11 | Platform infra (Kong, Istio, OPA) | WhenEmptyOrUnderutilized |
| vhi-dd-pool | 4 | Data domain workloads | WhenEmptyOrUnderutilized |
| vhi-no-restart-for-maintainance | 0 | Disruption-sensitive workloads | WhenEmpty |

All pools share identical instance requirements: categories `["m","r"]`, sizes `["2","4","8","16"]`, amd64-only, on-demand-only, NodeClass `basic` (Bottlerocket).

### 6.2 What's Working Well

- Logical pool separation by workload function
- Consolidation enabled for cost efficiency
- Sensible resource limits (total cap: 2500 CPU, 2500 Gi)
- Multi-AZ distribution across eu-west-1a/b/c
- 21-day max node lifetime ensures patching
- `WhenEmpty` policy protects sensitive workloads from involuntary disruption

### 6.3 Recommendations

1. **Add arm64 to instance requirements** — enables Graviton selection (~20% savings)
2. **Add spot capacity type** for general-purpose and dd pools (not infra)
3. **Require instance generation ≥ 6** — enables encryption-in-transit, better price/performance
4. **Add disruption budgets with time windows** — limit business-hours disruption to 10% of nodes
5. **Add Pod Disruption Budgets** on infrastructure workloads before relying on NodePool budgets

---

## 7. Dev vs Prod Comparison

| Aspect | Dev | Prod |
|--------|-----|------|
| Kubernetes Version | 1.33 | 1.33 ✅ |
| EKS Auto Mode | ✅ | ✅ |
| Endpoint Access | Private only | Private only ✅ |
| NAT Gateways | 1 (single AZ) ❌ | 3 (per-AZ) ✅ |
| Network Firewall | 1 AZ | 3 AZs ✅ |
| VPC Endpoints (ECR/STS/Logs) | ❌ Missing | ❌ Missing |
| SG 10.0.0.0/8 ALL inbound | ⚠️ Present | ⚠️ Present ("Temp") |
| Control Plane Logging | ✅ All enabled | ✅ All enabled |
| KMS Encryption | ✅ | ✅ |
| Subnet IP availability | OK | ⚠️ eu-west-1c low (38 IPs) |
| Node Role ECR access | IRSA (scoped) | Node role (broad) |



---

## 8. Observability

### 8.1 Current State

| Pillar                | Tool                        | Coverage                                           |
| --------------------- | --------------------------- | -------------------------------------------------- |
| Application Metrics   | Datadog APM                 | ✅ Production (full)                                |
| Application Tracing   | Datadog APM                 | ✅ Production                                       |
| Application Logs      | Datadog (direct from pods)  | ✅ Production                                       |
| Cluster Metrics       | Datadog Kubernetes Explorer | Partial — pods, nodes, namespaces                  |
| Control Plane Metrics | CloudWatch (EKS managed)    | Available but not actively monitored               |
| Alerting              | Datadog Monitors            | 2 global monitors only (no-pod, abnormal restarts) |

### 8.2 Key Gaps Identified

1. **No control plane observability** — API server latency, etcd health, scheduler queue depth not monitored. If the control plane degrades, the team has no visibility until pods fail.

2. **Dev cluster is blind** — No Datadog agents in dev due to cost. No metrics, logs, or traces collected. Issues discovered only when deployments fail or users report problems.

3. **Only 2 alerting rules** — "no pod for deployment" and "abnormal restarts". No alerts for:
   - Node pressure (memory, disk, PID)
   - IP exhaustion
   - HPA at max replicas
   - Certificate expiry
   - DNS latency
### 8.3 Recommendations

1. **Control plane alerts in CloudWatch** — Configure CloudWatch Alarms for API server latency, etcd DB size, and scheduler pending queue. These metrics are already available (EKS publishes them) — just need alarms and notification routing.

2. **Dev cluster observability** — Consider OpenTelemetry (ADOT) collector as a cost-effective alternative for dev. Single DaemonSet can forward metrics to CloudWatch (included in AWS costs) and logs to CloudWatch Logs. No per-pod licensing.

3. **Dashboard organisation** — Follow a layered approach:
   - Level 1: Cluster health overview (red/yellow/green)
   - Level 2: Node and namespace utilisation
   - Level 3: Pod/container detail
   - Level 4: Application performance (existing Datadog APM)

4. **Replicate best-practice dashboard in Datadog** — AWS to share observability dashboard organisation document with recommended metrics, calculation methods, and hierarchy structure for the team to implement as a custom Datadog dashboard.

---

## 9. Discussion Outcomes & Clarifications

The following points were clarified during the review session:

### Secrets Management
Secrets are managed via **Argo CD** running in a central account. Argo CD syncs secrets from AWS Secrets Manager and applies updated manifests to the cluster. This is a valid pattern — no additional CSI driver or External Secrets Operator needed.

### Access Control
The team uses **EKS Access Entries** (not the legacy aws-auth ConfigMap) with role-based policies mapped to different user groups. Platform engineering has restricted prod access; SRE has admin. A limitation was noted: access entries have a cap on the number of namespaces per policy, which forced broader access in the multi-environment dev cluster.

### Single-Replica Applications
Many DD (data domain) applications run single replicas by design — they consume from single Kafka partitions to maintain message ordering. The team mitigates node restart risk by using Karpenter taints to trigger pre-scaling before node termination, then scaling back after restart. This is a conscious trade-off, not an oversight.

### Gateway API Migration
The team is planning to migrate from NGINX Ingress (deprecated) to Gateway API using Envoy (S2) as the implementation. AWS offered to review the migration architecture document and optionally connect with the Gateway API service team for a best-practice validation session.

### Disruption Budgets
The team has implemented disruption budgets with scheduled windows (every other Monday at 6–7 AM). However, they noted that nodes often expire (21-day TTL) rather than being disrupted during the window, because AMI drift events don't occur on a predictable schedule. The team expressed interest in a "forced restart" capability within the disruption window — not currently available natively.

### Kong Configuration Issues
89 `KongConfigurationTranslationFailed` events were observed. The team acknowledged Kong has been "a tricky customer" and will verify via the Kong Admin API whether all resources are syncing correctly. Priority investigation if this exists in production.

---

## 10. Recommended Next Steps

### Immediate (This Week)

1. Fix Kong HPA — add CPU/memory requests to Kong containers (requests = limits)
2. Investigate OPA Gatekeeper crash (prod-labelled instance)
3. Resolve ECR image pull secret rotation
4. Verify Kong configuration translation errors in production

### Short-Term (2–4 Weeks)

5. Tighten security groups — remove 10.0.0.0/8 ALL, implement recommended SG structure
6. Add VPC endpoints (ECR, STS, Logs) to both clusters — verify if traffic already routes via Transit Gateway to centralised endpoints
7. Deploy per-AZ NAT Gateways in dev (or regional NAT)
8. Add PDBs to infrastructure deployments (NGINX, Kong, EFS CSI)
9. Add istiod HPA stabilisation window + evaluate external metrics
10. Set resource requests = limits across all workloads (enforce via Helm chart single-value pattern)
11. Configure CloudWatch Alarms for EKS control plane metrics

### Medium-Term (1–2 Months)

12. Enable Graviton (arm64) in NodePool requirements
13. Add spot capacity type for dev/test pools
14. Right-size CPU requests based on Datadog actual usage data (p95 over 7 days)
15. Migrate load balancers to IP target type
16. Implement egress network policies (leverage EKS Auto Mode DNS-based policies)
17. Share observability dashboard best practices document
18. Build custom Datadog dashboard following recommended hierarchy
19. Review Gateway API migration architecture document



