# Progressive Delivery

## Overview

This platform uses Argo Rollouts to implement progressive delivery for the application layer, integrated with Argo CD (GitOps) and Gateway API / Envoy Gateway.

Two rollout strategies are intentionally used:

- Backend: Canary deployment with Gateway API traffic weighting.
- Frontend: Blue/Green deployment with separate Active and Preview Services.

Argo CD remains responsible for GitOps reconciliation and maintaining the desired application state, while Argo Rollouts manages the runtime rollout lifecycle.

The current implementation uses manual promotion. This makes each rollout stage observable and allows the new version to be validated before production traffic is switched.

Automated metric-based promotion and rollback using Prometheus and Argo Rollouts Analysis are considered future enhancements.

---

## Architecture

~~~mermaid
graph TD
    A[Git Repository] --> B[Argo CD]
    B --> C[Application Manifests]
    C --> D[Argo Rollouts]

    D --> E[Backend Canary]
    D --> F[Frontend BlueGreen]

    E --> G[Gateway API HTTPRoute]
    G --> H[Envoy Gateway]
    H --> I[Users]

    F --> J[Frontend Active Service]
    J --> G
    F --> K[Frontend Preview Service]
~~~

The architecture separates three main responsibilities:

- Argo CD manages the desired state from Git.
- Argo Rollouts manages ReplicaSets and progressive delivery.
- Gateway API and Envoy Gateway manage external application routing.

---

# 1. GitOps with Argo CD

## 1.1 Argo CD Application

The application platform is managed by an Argo CD Application named:

`microservices-platform`

The Application tracks the Git repository and recursively manages manifests under the `apps/` directory.

The main source configuration is:

~~~yaml
spec:
  source:
    repoURL: git@github.com:ahmed-sayed-devops/microservices-platform-gitops.git
    targetRevision: main
    path: apps
    directory:
      recurse: true

  destination:
    server: https://kubernetes.default.svc

  syncPolicy:
    automated:
      prune: true
      selfHeal: true
~~~

The Git repository is the source of truth for the desired application state.

Argo CD continuously reconciles the desired state stored in Git with the actual state of the Kubernetes cluster.

Automated pruning removes resources that are no longer defined in Git, while self-healing allows Argo CD to restore resources that drift from the declared configuration.

## 1.2 HTTPRoute Runtime Differences

The Backend Canary rollout dynamically changes Gateway API HTTPRoute weights.

Therefore, the Argo CD Application ignores only the runtime-managed backend weights:

~~~yaml
ignoreDifferences:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    jqPathExpressions:
      - .spec.rules[].backendRefs[].weight
~~~

This is intentionally limited to the backend weight fields.

The HTTPRoute remains GitOps-managed, while Argo Rollouts is allowed to modify the runtime traffic weights required for Canary progression.

## 1.3 Argo CD Health Verification

Command:

~~~bash
kubectl get application microservices-platform -n argocd
~~~

Expected state:

~~~text
NAME                     SYNC STATUS   HEALTH STATUS
microservices-platform   Synced        Healthy
~~~

### Evidence

![Argo CD Application Healthy](../screenshots/13-ArgoCD-Healthy.png)

Screenshot: `13-ArgoCD-Healthy.png`

This evidence confirms that the application is synchronized with Git and currently healthy.

---

# 2. Backend Canary Deployment

The Backend uses an Argo Rollouts Rollout resource with the Canary strategy.

The Canary implementation uses two Services:

- `backend-stable`
- `backend-canary`

Gateway API is used as the traffic router between the stable and canary Services.

## 2.1 Canary Configuration

The Backend Rollout uses the following strategy:

~~~yaml
strategy:
  canary:
    stableService: backend-stable
    canaryService: backend-canary

    trafficRouting:
      plugins:
        argoproj-labs/gatewayAPI:
          httpRoute: application-route
          namespace: microservices

    steps:
      - setWeight: 10
      - pause: {}
      - setWeight: 25
      - pause: {}
      - setWeight: 50
      - pause: {}
      - setWeight: 100
      - pause: {}
~~~

The intended progression is:

~~~text
10% Canary
   ↓
Validation / Pause
   ↓
25% Canary
   ↓
Validation / Pause
   ↓
50% Canary
   ↓
Validation / Pause
   ↓
100% Canary
   ↓
Promotion
~~~

The pause steps are intentionally configured as manual gates in the current lab implementation.

This allows the operator to inspect the rollout and validate the new version before moving to the next stage.

## 2.2 Healthy Backend Rollout

The currently promoted Backend version is:

`a7medsayed/backend:v1.0.2`

Command:

~~~bash
kubectl argo rollouts get rollout backend -n microservices
~~~

The successful runtime state shows:

~~~text
Status: Healthy
Strategy: Canary
Images:
a7medsayed/backend:v1.0.2 (stable)
~~~

The rollout has:

- 3 desired replicas.
- 3 current replicas.
- 3 updated replicas.
- 3 ready replicas.
- 3 available replicas.
- Previous ReplicaSets scaled down.

### Evidence

![Backend Rollout Healthy](../screenshots/14-Backend-Rollout-Healthy.png)

Screenshot: `14-Backend-Rollout-Healthy.png`

This evidence demonstrates that the Backend Canary rollout completed successfully and that `v1.0.2` became the stable release.

## 2.3 Backend Canary Configuration

Command:

~~~bash
kubectl describe rollout backend -n microservices
~~~

The configuration contains:

~~~text
Strategy:
  Canary

Canary Service:
  backend-canary

Stable Service:
  backend-stable

Steps:
  Set Weight: 10
  Pause
  Set Weight: 25
  Pause
  Set Weight: 50
  Pause
  Set Weight: 100
  Pause

Traffic Routing:
  argoproj-labs/gatewayAPI
~~~

### Evidence

![Backend Canary Configuration](../screenshots/15-Backend-Canary-Config.png)

Screenshot: `15-Backend-Canary-Config.png`

This demonstrates the actual Canary strategy configured in the cluster.

## 2.4 Stable and Canary Services

The Backend uses separate Services for stable and canary traffic.

Command:

~~~bash
kubectl get svc backend-stable backend-canary -n microservices
~~~

### Evidence

![Backend Canary Services](../screenshots/17-Backend-Canary-Services.png)

Screenshot: `17-Backend-Canary-Services.png`

The Services provide distinct traffic destinations that Argo Rollouts can associate with the stable and canary ReplicaSets.

Argo Rollouts manages the runtime selectors using the `rollouts-pod-template-hash` label.

## 2.5 Gateway API Traffic Routing

The Backend Canary is integrated with the Gateway API through:

`application-route`

The HTTPRoute contains references to both backend Services.

The runtime routing state can contain:

~~~yaml
backendRefs:
  - name: backend-stable
    port: 4000
    weight: 100

  - name: backend-canary
    port: 4000
    weight: 0
~~~

During an active Canary rollout, Argo Rollouts changes these weights according to the configured rollout steps.

Command:

~~~bash
kubectl get httproute application-route \
  -n microservices \
  -o yaml
~~~

### Evidence

![Backend Canary HTTPRoute](../screenshots/18-Backend-Canary-HTTPRoute.png)

Screenshot: `18-Backend-Canary-HTTPRoute.png`

This demonstrates the integration between:

~~~text
Argo Rollouts
      ↓
Gateway API Plugin
      ↓
HTTPRoute
      ↓
backend-stable / backend-canary
~~~

The important design point is that Argo Rollouts uses Gateway API routing weights to control how production traffic is distributed between the stable and canary Services.

---

# 3. Frontend Blue/Green Deployment

The Frontend uses the Blue/Green rollout strategy.

The Rollout manages two Services:

~~~text
frontend
frontend-preview
~~~

Their roles are:

~~~text
frontend
    → Active / Production traffic

frontend-preview
    → Preview / Validation traffic
~~~

The external Gateway HTTPRoute continues to reference only the `frontend` Service.

The Preview Service is intentionally not used as the production backend.

Argo Rollouts controls which ReplicaSet each Service selects.

## 3.1 Blue/Green Configuration

The Frontend Rollout uses:

~~~yaml
strategy:
  blueGreen:
    activeService: frontend
    previewService: frontend-preview
    autoPromotionEnabled: false
~~~

The rollout workflow is:

~~~text
New version committed to Git
        ↓
Argo CD reconciliation
        ↓
Argo Rollouts creates new ReplicaSet
        ↓
New ReplicaSet becomes Preview
        ↓
Preview Pods become Ready
        ↓
Preview validation
        ↓
Manual Promotion
        ↓
Active Service switches
        ↓
Old ReplicaSet is scaled down
~~~

`autoPromotionEnabled: false` creates an explicit validation gate between deployment and production activation.

## 3.2 Successful Blue/Green Rollout

The successful Frontend release is:

`a7medsayed/frontend:v1.0.1`

The final successful state is:

~~~text
v1.0.1 → stable, active
v1.0.0 → old ReplicaSet, scaled down
~~~

Command:

~~~bash
kubectl argo rollouts get rollout frontend -n microservices
~~~

Expected successful state:

~~~text
Status: Healthy
Strategy: BlueGreen

Images:
a7medsayed/frontend:v1.0.1 (stable, active)

revision:2
frontend-56fd8cdb7f
stable,active

revision:1
frontend-655f4bdcc6
ScaledDown
~~~

### Evidence

![Frontend Blue Green Healthy](../screenshots/20-Frontend-BlueGreen-Healthy.png)

Screenshot: `20-Frontend-BlueGreen-Healthy.png`

This demonstrates that the new Frontend version became the stable Active release and that the previous ReplicaSet was scaled down.

## 3.3 Active and Preview Services

Command:

~~~bash
kubectl get svc frontend frontend-preview -n microservices
~~~

### Evidence

![Frontend Blue Green Services](../screenshots/21-Frontend-BlueGreen-Services.png)

Screenshot: `21-Frontend-BlueGreen-Services.png`

The two Services are maintained as part of the Blue/Green lifecycle.

During a rollout:

~~~text
frontend
    ↓
Active ReplicaSet

frontend-preview
    ↓
Preview ReplicaSet
~~~

The Services use the `rollouts-pod-template-hash` selector to identify the corresponding ReplicaSet.

## 3.4 Blue/Green Runtime State

Command:

~~~bash
kubectl describe rollout frontend -n microservices
~~~

The important configuration is:

~~~text
Active Service:
  frontend

Preview Service:
  frontend-preview

Auto Promotion Enabled:
  false
~~~

The Rollout status also exposes:

- Active selector.
- Preview selector.
- Current Pod hash.
- Stable ReplicaSet.
- Updated replicas.
- Ready replicas.

### Evidence

![Frontend Blue Green State](../screenshots/23-Frontend-BlueGreen-State.png)

Screenshot: `23-Frontend-BlueGreen-State.png`

This provides direct evidence of how Argo Rollouts tracks the Active and Preview ReplicaSets.

---

# 4. Frontend End-to-End Validation

The application is exposed externally through Envoy Gateway and Gateway API.

The production endpoint is:

`https://app.microservices.home.arpa`

After the successful promotion, the application displays:

`Frontend Release v1.0.1`

### Evidence

![Frontend Production v1.0.1](../screenshots/24-Frontend-Production-v1.0.1.png)

Screenshot: `24-Frontend-Production-v1.0.1.png`

This provides user-facing evidence of the successful release.

The complete traffic path is:

~~~mermaid
graph LR
    A[Browser] --> B[Envoy Gateway]
    B --> C[Gateway API HTTPRoute]
    C --> D[frontend Service]
    D --> E[Active ReplicaSet]
    E --> F[Frontend v1.0.1]
~~~

The important distinction is that the Gateway continues routing to the Service named:

`frontend`

Argo Rollouts changes the Service selector when switching between Blue and Green ReplicaSets.

---

# 5. Failed Frontend Preview Scenario

A controlled failure scenario was introduced to validate the behavior of an unsuccessful Preview release.

The intentionally invalid image was:

`a7medsayed/frontend:v9.9.9`

The image does not exist, so the new Preview Pods cannot start successfully.

The expected behavior is:

~~~text
Current Active
v1.0.1
    ↓
Production traffic

New Preview
v9.9.9
    ↓
ImagePullBackOff
~~~

The important behavior is that the currently active production version remains available while the Preview release fails.

## 5.1 Failed Rollout

Command:

~~~bash
kubectl argo rollouts get rollout frontend -n microservices
~~~

### Evidence

![Failed Frontend Rollout](../screenshots/25-Failed-Frontend-Rollout.png)

Screenshot: `25-Failed-Frontend-Rollout.png`

The evidence shows the failed Preview ReplicaSet while the existing stable release remains Active.

## 5.2 Failed Preview Pods

Command:

~~~bash
kubectl get pods -n microservices \
  -l app.kubernetes.io/name=frontend
~~~

### Evidence

![Failed Preview Pods](../screenshots/26-Failed-Preview-Pods.png)

Screenshot: `26-Failed-Preview-Pods.png`

The Preview Pods are stuck in:

`ImagePullBackOff`

while the existing production Pods remain healthy.

## 5.3 Production Remains Available

The production application was tested while the Preview release was failing.

### Evidence

![Production Unaffected](../screenshots/27-Production-Unaffected.png)

Screenshot: `27-Production-Unaffected.png`

This validates the main Blue/Green safety property demonstrated by the lab:

A failed Preview release does not automatically replace the currently active production version.

---

# 6. Rollout Promotion

For the successful Frontend release, promotion was performed manually:

~~~bash
kubectl argo rollouts promote frontend -n microservices
~~~

Before promotion:

~~~text
v1.0.0 → Active
v1.0.1 → Preview
~~~

After promotion:

~~~text
v1.0.1 → Active
v1.0.0 → ScaledDown
~~~

This is the final successful state demonstrated in the cluster.

---

# 7. Canary vs Blue/Green

The platform intentionally demonstrates both strategies.

| Capability | Backend | Frontend |
|---|---|---|
| Strategy | Canary | Blue/Green |
| Stable Service | `backend-stable` | `frontend` |
| New Version Service | `backend-canary` | `frontend-preview` |
| Gateway traffic split | Yes | No |
| Progressive percentages | 10/25/50/100 | N/A |
| Preview validation | Yes | Yes |
| Manual promotion | Yes | Yes |
| Gateway API integration | Yes | Indirect |
| Active production traffic | Stable/weighted | Active Service |

### Canary

Canary gradually changes the amount of production traffic reaching the new version:

~~~text
100% Stable
     ↓
90% Stable / 10% Canary
     ↓
75% Stable / 25% Canary
     ↓
50% Stable / 50% Canary
     ↓
100% New Version
~~~

The exact transition is controlled by Argo Rollouts and reflected in the Gateway API HTTPRoute weights.

### Blue/Green

Blue/Green keeps two environments available:

~~~text
Blue
Active / Production
v1.0.0

Green
Preview
v1.0.1
~~~

After validation, the Active Service selector is switched to the new ReplicaSet.

---

# 8. GitOps and Progressive Delivery Interaction

~~~mermaid
graph TD
    A[Developer] --> B[Git Commit]
    B --> C[Git Repository]
    C --> D[Argo CD]
    D --> E[Kubernetes Desired State]
    E --> F[Argo Rollouts]

    F --> G[Backend Canary]
    F --> H[Frontend BlueGreen]

    G --> I[Gateway API]
    I --> J[Envoy Gateway]

    H --> I
~~~

The important separation of responsibilities is:

### Git / Argo CD

Defines:

- Application manifests.
- Container image versions.
- Services.
- Rollout strategies.
- Gateway API resources.
- Desired configuration.

### Argo Rollouts

Controls:

- ReplicaSets.
- Canary progression.
- Blue/Green Active and Preview state.
- Runtime Service selectors.
- Gateway API traffic weights for the Backend.
- Promotion and rollout lifecycle.

### Envoy Gateway / Gateway API

Controls:

- External application entry point.
- HTTP/HTTPS listeners.
- Host/path routing.
- Forwarding traffic to Kubernetes Services.

---

# 9. Failure and Recovery Model

The demonstrated failed Preview scenario follows this model:

~~~mermaid
graph TD
    A[New Release] --> B[Preview]
    B --> C{Healthy?}
    C -->|Yes| D[Validate]
    D --> E[Promote]
    E --> F[New Active Version]

    C -->|No| G[Keep Current Active]
    G --> H[Investigate / Abort / Revert]
~~~

The key design principle is:

Do not expose an unverified release as the Active production version.

For the current lab, recovery can be performed through Git by reverting the bad image change and allowing Argo CD to reconcile the known-good desired state.

---

# 10. Current Implementation Decisions

## Manual Promotion

The current implementation deliberately uses manual promotion:

~~~yaml
autoPromotionEnabled: false
~~~

This makes the rollout process explicit and easy to inspect during the lab.

## No Weighted Gateway Routing for Frontend

The Frontend does not add `frontend-preview` to the production HTTPRoute.

Instead:

~~~text
HTTPRoute
   ↓
frontend Service
   ↓
Active ReplicaSet
~~~

Argo Rollouts changes the Service selector during the Blue/Green transition.

This keeps the Gateway routing configuration simple and lets Rollouts own the Active/Preview switch.

## Gateway API for Backend Canary

The Backend Canary uses the Gateway API plugin so that traffic percentages are reflected directly in the HTTPRoute.

This allows the rollout controller to control:

~~~text
backend-stable
backend-canary
~~~

through Gateway API weights.

---

# 11. Production Enhancement

The current lab implementation uses manual pauses and manual promotion.

A future production-oriented enhancement would introduce:

~~~text
Prometheus
    ↓
Argo Rollouts AnalysisTemplate
    ↓
AnalysisRun
    ↓
Success / Failure
    ↓
Promote or Abort
~~~

Possible metrics could include:

- HTTP error rate.
- Request latency.
- Application health.
- Availability.
- Business-specific success metrics.

This is intentionally documented as a future enhancement rather than part of the current implementation.

---

# 12. Evidence Index

| Screenshot | Evidence |
|---|---|
| `13-ArgoCD-Healthy.png` | Argo CD Application is Synced and Healthy |
| `14-Backend-Rollout-Healthy.png` | Backend Canary rollout healthy and promoted |
| `15-Backend-Canary-Config.png` | Backend Canary strategy and rollout stages |
| `17-Backend-Canary-Services.png` | Stable/Canary backend Services |
| `18-Backend-Canary-HTTPRoute.png` | Gateway API routing between stable/canary |
| `20-Frontend-BlueGreen-Healthy.png` | Frontend Blue/Green successful state |
| `21-Frontend-BlueGreen-Services.png` | Frontend Active/Preview Services |
| `23-Frontend-BlueGreen-State.png` | Active/Preview selectors and Rollout state |
| `24-Frontend-Production-v1.0.1.png` | Production frontend running v1.0.1 |
| `25-Failed-Frontend-Rollout.png` | Failed Preview rollout |
| `26-Failed-Preview-Pods.png` | Preview Pods in ImagePullBackOff |
| `27-Production-Unaffected.png` | Production remains available during failed Preview |

---

# 13. Result

The Progressive Delivery portion of the platform demonstrates two production-relevant rollout strategies:

~~~text
Backend
Canary
10% → 25% → 50% → 100%
        ↓
Gateway API traffic shifting

Frontend
Blue/Green
Active → Preview → Validation → Promotion
~~~

Both strategies are managed through Argo Rollouts and integrated into the GitOps workflow through Argo CD.

The implementation also includes a controlled failed Preview scenario demonstrating that a bad release can be isolated from the currently active production version.

## Current Status

- [x] Argo CD GitOps Application
- [x] Backend Canary Rollout
- [x] Gateway API traffic routing
- [x] Frontend Blue/Green Rollout
- [x] Active / Preview Services
- [x] Manual promotion
- [x] Successful production release
- [x] Failed Preview scenario
- [x] Production remains available during failed Preview
- [ ] Automated metric-based promotion
- [ ] Automated metric-based rollback

The automated analysis items are intentionally left as future enhancements and are not required to claim the current Progressive Delivery implementation as complete.
