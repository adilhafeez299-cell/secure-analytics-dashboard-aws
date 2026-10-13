# Design: assumptions, decisions and trade-offs

## The brief

A small team of analysts needs an internal web app, such as a reporting dashboard, hosted in the cloud. The data is sensitive. Get it up and running, securely, and be able to keep it running.

## Assumptions

Every decision below follows from these. If one is wrong, the design changes in a known place.

| Area | Assumption | Why it matters |
| --- | --- | --- |
| Users | 10-15 analysts, one team, UK, office and home, business hours | One server is enough; no out-of-hours SLA |
| Identity | The client uses Microsoft 365, so Entra ID is their login | Reuse their accounts and MFA |
| Data | Sensitive, e.g. pseudonymised clinical data; treated as GxP until told otherwise | Drives encryption, audit trail, UK residency, validation |
| Volume | Gigabytes, read-mostly | A small managed database is enough |
| App | R Shiny or Python dashboard reading a database; stateless | Easy to containerise and scale out |
| Availability | A short outage is tolerable; data loss is not | One server first, strong backups from day one |
| Access | Internal only | No open internet endpoint; login in front of everything |
| Starting point | Greenfield: a new AWS account, data allowed to move there | The biggest assumption; see *If the assumptions change* |

## Decisions

### 1. AWS, London region

- UK data residency in eu-west-2.
- AWS publishes GxP guidance and maps 21 CFR Part 11 to shared responsibility.
- The load balancer can sign users in against Entra ID directly, so the client keeps its identity provider.
- **When Azure wins:** the client is all-Microsoft with an existing landing zone. Follow the client's cloud. The design maps across: Application Gateway, Key Vault, Azure Database for PostgreSQL, Azure Monitor.

### 2. One VM in an Auto Scaling Group, not Kubernetes

For 15 users, Kubernetes adds a control plane, upgrades and skills overhead for no benefit. An ASG of one gives self-healing now and scaling later by changing two numbers. At around 200 users, ECS Fargate (same container, no servers to patch) comes before EKS. EKS makes sense if the client already runs Kubernetes.

### 3. A container image

The image carries the OS libraries, the runtime and the packages together, so what was tested is what runs. (The demo pins only the top-level packages; see *Known limitations* in the README.) Every release is a new immutable tag; rollback is the previous tag. The same image moves to ECS or Kubernetes without changes.

### 4. Login at the load balancer, verified again in the app

The ALB's `authenticate-oidc` action means no request reaches the app unauthenticated. The app still verifies the ALB's signed JWT (algorithm, signer ARN, signature, expiry) before trusting a name. That protects the audit trail from a forged header if anything ever reached the app another way.

### 5. Secrets in Secrets Manager with a customer-managed KMS key

Nothing secret in code, images or config files. Terraform creates an empty secret; the value goes in through the CLI. Trade-off: the value still lands in Terraform state, so production state lives in an encrypted S3 backend.

### 6. No SSH

Session Manager instead: no port 22, no keys to manage, every session logged.

### 7. Logs leave the server

The app writes JSON audit events (user, action, time). The CloudWatch agent ships them off the server, so replacing a server never loses the trail.

## Security controls

| Layer | Control |
| --- | --- |
| Network | Only the load balancer is public; security group allows client IP ranges only; app accepts traffic only from the load balancer |
| Login | Entra ID single sign-on with MFA; only assigned users; 1-hour sessions |
| Transit | HTTPS only, TLS 1.2+ policy; HTTP redirects to HTTPS |
| At rest | Encrypted disks; secret encrypted with a customer-managed KMS key |
| Server | No public IP, no SSH, IMDSv2 with hop limit 1 (containers can't reach instance credentials) |
| Container | Non-root, read-only root filesystem, all Linux capabilities dropped, no-new-privileges |
| Supply chain | Pinned top-level packages; ECR scan on push; immutable tags |
| Detection | Alarms on health, errors, latency, CPU; VPC Flow Logs; ALB access logs |

## Compliance mapping: MHRA data integrity (ALCOA+)

Designed against the MHRA GXP Data Integrity Guidance (2018). Other rules that may apply: FDA 21 CFR Part 11 (US submissions), EU GMP Annex 11, UK GDPR.

| Principle | Where the design meets it |
| --- | --- |
| Attributable | Named Entra logins, no shared accounts, verified identity in every audit event |
| Contemporaneous | Timestamps written automatically on every event |
| Original | Source data kept in versioned storage; the dashboard reads, never overwrites |
| Accurate | Pinned, scanned, immutable image; changes through change control |
| Enduring, Available | Logs and data off the server; encrypted backups; tested restores |
| Complete | Every action logged; logs locked against edits (CloudTrail with Object Lock in the full design) |

**Shared responsibility:** there is no GxP-certified cloud. AWS runs the data centres and services; the customer validates the system built on top (IQ, OQ, PQ) and keeps it in a validated state. Infrastructure as code, immutable images and change control are the evidence.

## Scaling to 200 users

| Layer | Change |
| --- | --- |
| App servers | ASG min 2, spread across 2 AZs, scale on CPU or request count |
| Sessions | Stateless app; sticky sessions on the target group for Shiny's in-memory sessions (already on) |
| Database | RDS Multi-AZ, plus a read replica if reporting load is heavy |
| Access | Entra groups per team |
| Environments | Separate dev, test and prod, ideally separate AWS accounts |

## If the assumptions change

**Data is on-prem:** migrate it (this design plus a validated migration), go hybrid (app in AWS, data over site-to-site VPN), or keep it on-prem (the same container runs on the client's Linux servers).

**Regulated migration:** discover, plan (including rollback), build the target with Terraform, trial migration with reconciliation (row counts, checksums, sampled records, audit trail carried across), IQ/OQ, parallel run, cutover, hypercare, then decommission and archive. Tools: AWS DataSync (files), AWS DMS (databases), AWS Application Migration Service (servers).

**Client leaves Microsoft 365:** the load balancer accepts any OIDC identity provider (e.g. Okta, Google). With none at all, Amazon Cognito with MFA, and the client owns joiners and leavers.

## Rough cost

Full phase-1 design: roughly £150-300 a month in London, dominated by the load balancer, NAT gateway and database, not the server. The demo build costs about £1-2 for an afternoon. Confirm with the AWS Pricing Calculator before quoting.

## Sources

- [MHRA GXP Data Integrity Guidance and Definitions (2018)](https://assets.publishing.service.gov.uk/government/uploads/system/uploads/attachment_data/file/687246/MHRA_GxP_data_integrity_guide_March_edited_Final.pdf)
- [GxP Systems on AWS](https://docs.aws.amazon.com/whitepapers/latest/gxp-systems-on-aws/gxp-systems-on-aws.html)
- [Authenticate users using an Application Load Balancer](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/listener-authenticate-users.html)
