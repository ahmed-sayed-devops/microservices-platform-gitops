# Storage & MySQL High Availability

This section implements the persistent storage, database high availability, and application caching layer of the private RKE2 Kubernetes platform.

The solution combines Longhorn persistent storage, MySQL StatefulSets, primary/replica architecture, Redis caching, HAProxy database routing, and an automated MySQL failover controller.

The storage and database HA workflow is deployed, integrated with the platform, and validated successfully.

---

## 1. Storage Architecture

Longhorn is used as the Kubernetes-native persistent storage platform.

It provides dynamic volume provisioning for stateful workloads and replicated storage for MySQL volumes.

```mermaid
graph TD
    K8S[Kubernetes Cluster]

    SC[Longhorn StorageClass]

    PVC1[mysql-primary-data]
    PVC2[mysql-replica-data]

    V1[Longhorn Volume]
    V2[Longhorn Volume]

    N1[rke2-worke01]
    N2[rke2-worke02]
    N3[rke2-worke03]

    K8S --> SC
    SC --> PVC1
    SC --> PVC2
    PVC1 --> V1
    PVC2 --> V2

    V1 --> N1
    V1 --> N2
    V1 --> N3

    V2 --> N1
    V2 --> N2
    V2 --> N3
```

The `longhorn` StorageClass is configured as the default StorageClass.

Key configuration:

- Provisioner: `driver.longhorn.io`
- Reclaim Policy: `Delete`
- Volume Binding Mode: `Immediate`
- Allow Volume Expansion: enabled
- Filesystem: `ext4`
- Number of replicas: `3`
- Data locality: disabled
- Data engine: `v1`

The Longhorn worker nodes are:

- `rke2-worke01`
- `rke2-worke02`
- `rke2-worke03`

All Longhorn nodes are healthy, schedulable, and available for storage workloads.

![Longhorn Storage Overview](../../screenshots/28-Longhorn-Storage-Overview.png)

*Evidence: Longhorn StorageClass, Longhorn nodes, and active Longhorn volumes.*

---

## 2. Longhorn Replicated Storage

Each MySQL persistent volume is provisioned through Longhorn with a replication factor of three.

This provides redundancy at the storage layer and protects persistent data from a single storage replica failure.

```mermaid
graph LR
    PVC[MySQL PVC]

    PVC --> VOL[Longhorn Volume]

    VOL --> R1[Replica 1]
    VOL --> R2[Replica 2]
    VOL --> R3[Replica 3]

    R1 --> W1[rke2-worke01]
    R2 --> W2[rke2-worke02]
    R3 --> W3[rke2-worke03]
```

The configured StorageClass contains:

```text
numberOfReplicas: "3"
```

The MySQL volumes are 10Gi and are reported as attached and healthy by Longhorn.

The storage layer provides:

- Dynamic provisioning
- Persistent block storage
- Replicated storage
- Kubernetes PVC integration
- Volume health monitoring
- Volume expansion support

![Longhorn Replication Configuration](../../screenshots/29-Longhorn-Replication-Config.png)

*Evidence: Longhorn replication configuration and MySQL volume details.*

---

## 3. MySQL Persistent Storage

MySQL is deployed using StatefulSets with dedicated PersistentVolumeClaims.

Two database instances are maintained:

- `mysql-primary-0`
- `mysql-replica-0`

Each instance has its own persistent volume.

```mermaid
graph TD
    PRIMARY[mysql-primary StatefulSet]
    REPLICA[mysql-replica StatefulSet]

    PVC1[mysql-primary-data]
    PVC2[mysql-replica-data]

    VOL1[Longhorn Volume]
    VOL2[Longhorn Volume]

    PRIMARY --> PVC1
    REPLICA --> PVC2

    PVC1 --> VOL1
    PVC2 --> VOL2
```

Current PVC configuration:

```text
mysql-primary-data   Bound   10Gi   RWO   longhorn
mysql-replica-data   Bound   10Gi   RWO   longhorn
```

Both StatefulSets are healthy and running with their required replicas.

![MySQL Persistent Storage](../../screenshots/30-MySQL-Persistent-Storage.png)

*Evidence: MySQL PVCs are Bound to Longhorn storage and both StatefulSets are available.*

---

## 4. MySQL Primary / Replica Architecture

The database layer follows a primary/replica architecture.

The primary handles normal persistent database operations while the replica provides a failover target.

```mermaid
graph LR
    APP[Backend Application]

    ROUTER[HAProxy<br/>mysql-router]

    PRIMARY[mysql-primary-0<br/>Primary]
    REPLICA[mysql-replica-0<br/>Replica]

    APP --> ROUTER
    ROUTER --> PRIMARY
    ROUTER -. Backup Target .-> REPLICA

    PRIMARY --> REPLICA
```

The StatefulSets provide stable database identities and persistent storage.

```text
mysql-primary-0
mysql-replica-0
```

![MySQL Primary Replica](../../screenshots/31-MySQL-Primary-Replica.png)

*Evidence: MySQL primary and replica StatefulSets and running database pods.*

---

## 5. Redis Caching Layer

Redis is deployed in the `microservices` namespace as the application caching layer.

It provides a fast in-memory data store for cacheable and frequently accessed application data.

The backend can use Redis to reduce unnecessary database reads and improve application response performance.

```mermaid
graph LR
    BACKEND[Backend Application]

    REDIS[Redis<br/>Cache]

    MYSQL[MySQL<br/>Persistent Database]

    BACKEND -->|Cache Read / Write| REDIS
    BACKEND -->|Persistent Data| MYSQL
```

The current Redis deployment is:

```text
Deployment: redis
Replicas:   1/1
Service:    redis
Port:       6379/TCP
ClusterIP:  10.43.194.16
```

The Redis pod is running successfully on:

```text
rke2-worke02
```

The Redis Service provides a stable internal Kubernetes endpoint:

```text
redis:6379
```

```mermaid
graph TD
    BACKEND[Backend]

    SERVICE[redis Service<br/>ClusterIP]

    POD[Redis Pod]

    BACKEND -->|6379/TCP| SERVICE
    SERVICE --> POD
```

Redis is intentionally treated as a caching layer rather than the system of record.

MySQL remains responsible for persistent application data, while Redis provides fast access to cacheable data.

---

## 6. Database Services

The database layer uses dedicated Kubernetes Services to separate application access from individual database pod identities.

```mermaid
graph TD
    APP[Application]

    WRITE[mysql-write]
    ROUTER[mysql-router]

    PRIMARY[mysql-primary]
    REPLICA[mysql-replica]

    REDIS[redis]

    PRIMARYPOD[mysql-primary-0]
    REPLICAPOD[mysql-replica-0]
    REDISPOD[Redis Pod]

    APP --> WRITE
    APP --> REDIS

    WRITE --> ROUTER

    ROUTER --> PRIMARY
    ROUTER --> REPLICA

    PRIMARY --> PRIMARYPOD
    REPLICA --> REPLICAPOD

    REDIS --> REDISPOD
```

The deployed database-related Services are:

```text
mysql-primary
mysql-replica
mysql-router
mysql-write
redis
```

The database router exposes:

```text
3306/TCP
```

for MySQL traffic and:

```text
8404/TCP
```

for HAProxy statistics.

Redis exposes:

```text
6379/TCP
```

for internal application caching.

---

## 7. HAProxy Database Routing

HAProxy is deployed as the `mysql-router` component.

It provides a stable database endpoint for the application and abstracts the application from individual MySQL pod identities.

```mermaid
graph LR
    APP[Application]

    HAPROXY[HAProxy<br/>mysql-router:3306]

    PRIMARY[mysql-primary-0]
    REPLICA[mysql-replica-0]

    APP --> HAPROXY

    HAPROXY -->|Primary Path| PRIMARY
    HAPROXY -. Backup Path .-> REPLICA
```

HAProxy performs TCP health checks against the database endpoints and maintains the replica as the backup database target.

The HAProxy statistics interface is exposed through:

```text
mysql-router:8404
```

![MySQL HAProxy Routing](../../screenshots/32-MySQL-HAProxy-Routing.png)

*Evidence: MySQL Services and HAProxy router configuration.*

---

## 8. Automated Failover Controller

A dedicated `mysql-failover-controller` manages database failure detection and automatic failover.

The controller continuously checks the current primary and performs the required recovery actions when the primary becomes unavailable.

```mermaid
graph TD
    FC[mysql-failover-controller]

    CHECK[Check Current Primary]

    HEALTHY[Primary Healthy]
    FAILED[Primary Failed]

    PROMOTE[Promote mysql-replica]

    STATE[Update Failover State]

    ROUTER[Update HAProxy]

    RESTART[Restart mysql-router]

    FC --> CHECK

    CHECK --> HEALTHY
    CHECK --> FAILED

    HEALTHY --> CHECK

    FAILED --> PROMOTE
    PROMOTE --> STATE
    STATE --> ROUTER
    ROUTER --> RESTART
```

The failover state is maintained through:

```text
mysql-failover-state
```

The state tracks:

```text
current-primary
rejoin-required
```

The controller is deployed as a Kubernetes Deployment with one active replica.

![MySQL Failover Controller](../../screenshots/33-MySQL-Failover-Controller.png)

*Evidence: Failover controller deployment and database HA controller output.*

---

## 9. Normal HA Baseline

Before performing the failure test, the database platform was operating normally.

```mermaid
graph LR
    PRIMARY[mysql-primary-0<br/>Running]

    REPLICA[mysql-replica-0<br/>Running]

    ROUTER[mysql-router<br/>Running]

    REDIS[Redis<br/>Running]

    FC[Failover Controller<br/>Running]

    PRIMARY --> REPLICA
    ROUTER --> PRIMARY
    FC --> PRIMARY
```

The baseline database state was:

```text
mysql-primary-0              Running
mysql-replica-0              Running
mysql-router                 Running
mysql-failover-controller    Running
redis                        Running

current-primary              mysql-primary
rejoin-required              false
```

![MySQL Failover Baseline](../../screenshots/34-MySQL-Failover-Baseline.png)

*Evidence: Healthy MySQL HA baseline before the controlled failure test.*

---

## 10. Automatic Failover Test

A controlled failure was introduced by deleting the current primary pod:

```text
mysql-primary-0
```

The StatefulSet automatically recreated the database pod while the failover controller detected the database failure.

```mermaid
graph TD
    NORMAL[Normal Operation]

    FAILURE[mysql-primary-0 Failure]

    DETECT[Failover Controller<br/>Detects Failure]

    PROMOTE[Promote mysql-replica]

    STATE[Update HA State]

    ROUTE[Update HAProxy Routing]

    RECREATE[Recreate mysql-primary-0]

    RECOVERY[Database HA Recovered]

    NORMAL --> FAILURE

    FAILURE --> DETECT
    FAILURE --> RECREATE

    DETECT --> PROMOTE
    PROMOTE --> STATE
    STATE --> ROUTE

    ROUTE --> RECOVERY
    RECREATE --> RECOVERY
```

The failover controller successfully detected the failed primary after consecutive health-check failures.

It then performed the failover procedure:

```text
mysql-primary considered FAILED
mysql-replica promoted
New primary: mysql-replica
Rejoin required: true
HAProxy configuration updated
HAProxy restart requested
```

This confirms that the automatic failover mechanism is functioning as designed.

---

## 11. Failover State Transition

After the failure event, the database platform transitioned to the replica as the active primary.

```mermaid
graph LR
    OLD[mysql-primary<br/>Previous Primary]

    NEW[mysql-replica<br/>New Primary]

    RECOVERED[mysql-primary-0<br/>Recovered Instance]

    OLD -->|Failure| NEW
    OLD -->|StatefulSet Recovery| RECOVERED
    NEW -->|Rejoin / Synchronization| RECOVERED
```

The failover controller updated the cluster state to:

```text
current-primary: mysql-replica
rejoin-required: true
```

The recreated `mysql-primary-0` does not immediately take ownership of the primary role.

The promoted replica remains the active primary while the recovered instance goes through the rejoin and recovery workflow.

![MySQL Data Persistence and Recovery](../../screenshots/35-MySQL-Data-Persistence-Recovery.png)

*Evidence: MySQL recovery state after the primary failure and automatic replica promotion.*

---

## 12. Automatic Recovery and Rejoin

After failover, the platform performs the recovery workflow for the original primary.

```mermaid
graph TD
    FAILOVER[mysql-replica becomes Primary]

    WAIT[Wait for mysql-primary Recovery]

    READONLY[Prepare Recovered mysql-primary]

    REJOIN[Rejoin mysql-primary as Replica]

    SYNC[Replication Synchronization]

    HEALTHY[Healthy Primary + Replica]

    FAILOVER --> WAIT
    WAIT --> READONLY
    READONLY --> REJOIN
    REJOIN --> SYNC
    SYNC --> HEALTHY
```

The recovered database instance is brought back into the replication topology while the promoted replica continues serving as the active primary.

This recovery model avoids an uncontrolled role switch immediately after the original primary pod is recreated.

---

## 13. Database and Cache Traffic Flow

The application layer uses Redis for fast cache access and MySQL for persistent database operations.

```mermaid
graph TD
    CLIENT[Application Request]

    BACKEND[Backend Service]

    CACHE[Redis Cache]

    DBROUTER[mysql-write]

    HAPROXY[HAProxy]

    MYSQL[MySQL Primary]

    CLIENT --> BACKEND

    BACKEND --> CACHE

    BACKEND --> DBROUTER

    DBROUTER --> HAPROXY

    HAPROXY --> MYSQL
```

This separation allows the platform to keep frequently accessed cacheable data in Redis while persistent application data remains in MySQL.

---

## 14. Database HA Failure Flow

The complete database failure-handling workflow is:

```mermaid
graph TD
    A[Normal Database Operation]

    B[Primary Failure]

    C[Health Checks Detect Failure]

    D[Replica Promotion]

    E[Failover State Updated]

    F[HAProxy Routing Updated]

    G[Original Primary Recreated]

    H[Recovered Instance Rejoins]

    I[Replication Synchronization]

    J[Healthy HA Database]

    A --> B
    B --> C
    C --> D
    D --> E
    E --> F
    F --> G
    G --> H
    H --> I
    I --> J
```

The architecture combines multiple layers of resilience:

```mermaid
graph TD
    STORAGE[Longhorn<br/>Persistent Storage]

    MYSQL[MySQL<br/>Primary / Replica]

    CACHE[Redis<br/>Application Cache]

    CONTROLLER[Failover Controller]

    ROUTER[HAProxy<br/>Database Endpoint]

    STORAGE --> MYSQL
    MYSQL --> CONTROLLER
    CONTROLLER --> ROUTER
    ROUTER --> MYSQL
    MYSQL --> CACHE
```

Longhorn provides persistent replicated storage.

MySQL provides persistent database storage and a replication-based failover target.

Redis provides a fast application caching layer.

HAProxy provides a stable database endpoint, while the failover controller automates database failure handling.

---

## 15. StatefulSet Design

StatefulSets are used instead of Deployments for MySQL because MySQL is a stateful workload.

They provide:

- Stable pod identities
- Stable storage association
- PersistentVolumeClaim integration
- Ordered lifecycle behavior
- Predictable database instance names

```mermaid
graph LR
    STS[StatefulSet]

    ID[Stable Identity]

    PVC[PersistentVolumeClaim]

    STORAGE[Persistent Storage]

    POD[MySQL Pod]

    STS --> ID
    STS --> PVC
    PVC --> STORAGE
    STS --> POD
```

The database instances therefore maintain predictable identities:

```text
mysql-primary-0
mysql-replica-0
```

---

## 16. Why Longhorn

Longhorn was selected because it integrates directly with Kubernetes PersistentVolumeClaims while providing replicated persistent storage.

```mermaid
graph TD
    WORKLOAD[Stateful Workload]

    PVC[PersistentVolumeClaim]

    SC[StorageClass]

    LH[Longhorn]

    REPLICATED[Replicated Persistent Storage]

    WORKLOAD --> PVC
    PVC --> SC
    SC --> LH
    LH --> REPLICATED
```

This separates persistent storage from the lifecycle of individual MySQL pods.

If a database pod is recreated, its persistent storage remains associated with the workload through its PVC.

---

## 17. Why Redis

Redis is used as an application caching layer because cache workloads have different characteristics from persistent database workloads.

```mermaid
graph LR
    BACKEND[Backend]

    REDIS[Redis Cache]

    MYSQL[MySQL Database]

    BACKEND -->|Fast Cache Access| REDIS
    BACKEND -->|Persistent Data| MYSQL
```

The separation provides a clear responsibility model:

- Redis → fast, cache-oriented data access
- MySQL → persistent application data
- Longhorn → persistent storage for MySQL
- HAProxy → stable MySQL access endpoint
- Failover Controller → automated MySQL failover

Redis is kept internal to the Kubernetes cluster through its ClusterIP Service.

---

## 18. GitOps Integration

The storage, database, cache, and HA resources are managed as part of the platform GitOps model.

Argo CD manages the Kubernetes resources from the Git repository.

```mermaid
graph LR
    GIT[Git Repository]

    ARGO[Argo CD]

    K8S[Kubernetes]

    STORAGE[Longhorn Resources]

    MYSQL[MySQL Resources]

    REDIS[Redis Resources]

    HA[HA Components]

    GIT --> ARGO
    ARGO --> K8S

    K8S --> STORAGE
    K8S --> MYSQL
    K8S --> REDIS
    K8S --> HA
```

This keeps the platform declarative, reproducible, and integrated with the same GitOps workflow used by the application layer.

---

## 19. High Availability Layers

The final platform uses multiple complementary mechanisms for availability and performance.

```mermaid
graph TD
    PLATFORM[Stateful Application Platform]

    STORAGEHA[Storage HA<br/>Longhorn Replication]

    DBHA[Database HA<br/>MySQL Primary / Replica]

    CACHE[Application Cache<br/>Redis]

    ROUTINGHA[Database Routing<br/>HAProxy]

    FAILUREHA[Failure Automation<br/>Failover Controller]

    PLATFORM --> STORAGEHA
    PLATFORM --> DBHA
    PLATFORM --> CACHE
    PLATFORM --> ROUTINGHA
    PLATFORM --> FAILUREHA
```

Each layer has a dedicated responsibility:

- Longhorn provides replicated persistent storage.
- MySQL provides persistent database storage and replication.
- Redis provides application caching.
- HAProxy provides a stable database access endpoint.
- The failover controller automates database failure detection and failover.
- StatefulSets provide stable database identities and storage associations.
- Argo CD manages the Kubernetes resources declaratively.

---

## 20. Validation Summary

The storage and MySQL HA implementation is operational, and the controlled primary failure scenario completed successfully.

```mermaid
graph TD
    LH[Longhorn Healthy]

    PVC[Persistent Volumes Bound]

    MYSQL[MySQL Primary / Replica Running]

    REDIS[Redis Cache Running]

    HAPROXY[HAProxy Running]

    FC[Failover Controller Running]

    TEST[Controlled Primary Failure]

    DETECT[Failure Detected]

    PROMOTE[Automatic Replica Promotion]

    RECOVERY[Primary Pod Recovery]

    SUCCESS[Storage & MySQL HA Operational]

    LH --> PVC
    PVC --> MYSQL

    MYSQL --> HAPROXY
    MYSQL --> FC

    REDIS --> SUCCESS

    FC --> TEST
    TEST --> DETECT
    DETECT --> PROMOTE
    PROMOTE --> RECOVERY

    RECOVERY --> SUCCESS
```

Validated components:

- Longhorn installation
- Longhorn worker nodes
- Default StorageClass
- Dynamic persistent volume provisioning
- 10Gi MySQL persistent volumes
- Three-way Longhorn replication configuration
- MySQL primary StatefulSet
- MySQL replica StatefulSet
- MySQL Services
- Redis caching layer
- Redis Service
- HAProxy database router
- Failover controller
- Primary failure detection
- Automatic replica promotion
- HA state transition
- Primary pod recreation
- Database recovery workflow
- GitOps management through Argo CD

The storage, database HA, and Redis caching layers are operational and integrated with the overall microservices platform.

---

## 21. Final Storage Architecture

```mermaid
graph TD
    APP[Microservices Application]

    BACKEND[Backend]

    REDIS[Redis Cache]

    MYSQLWRITE[mysql-write]

    ROUTER[HAProxy<br/>mysql-router]

    PRIMARY[MySQL Current Primary]

    REPLICA[MySQL Replica]

    PVC1[Primary PVC]

    PVC2[Replica PVC]

    LH1[Longhorn Volume]

    LH2[Longhorn Volume]

    FC[MySQL Failover Controller]

    ARGO[Argo CD]

    APP --> BACKEND

    BACKEND --> REDIS
    BACKEND --> MYSQLWRITE

    MYSQLWRITE --> ROUTER

    ROUTER --> PRIMARY
    ROUTER -. Failover Target .-> REPLICA

    PRIMARY --> PVC1
    REPLICA --> PVC2

    PVC1 --> LH1
    PVC2 --> LH2

    PRIMARY --> REPLICA

    FC --> PRIMARY
    FC --> REPLICA
    FC --> ROUTER

    ARGO --> MYSQLWRITE
    ARGO --> REDIS
    ARGO --> PRIMARY
    ARGO --> REPLICA
    ARGO --> ROUTER
    ARGO --> FC
```

The resulting design provides a production-oriented stateful platform where persistent storage, database replication, caching, routing, automated failover, recovery, and GitOps management work together as a single Kubernetes-native architecture.