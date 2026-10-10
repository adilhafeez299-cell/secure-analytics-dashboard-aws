# Evidence

Screenshots from the live build on 9 October 2026. Account IDs, my IP address, tenant and client IDs, and user identifiers are blacked out or cropped.

| File | Shows |
| --- | --- |
| 01-terraform-apply.png | `terraform apply` creating subnets, security groups, NAT and the load balancer |
| 02-v1-bug-spinners.png | v1: dashboard stuck on spinners for a user whose token needed padding |
| 03-v2-verified-dashboard.png | v2: "Signed in as ... (verified)" with data loaded |
| 04-audit-log-v2.png | CloudWatch audit log: `verified: true`, `app_version: v2`, two users (user IDs blacked out) |
| 05-container-kill-restart.png | Container killed, restarted by systemd, healthy after about a minute |
| 06-service-stop-recovery.png | Target going unhealthy, draining, and a replacement instance initialising |
| 07-no-ssh-no-key-pair.png | EC2 console: no key pair, private IP only. Admin is Session Manager |
| 08-ecr-scan-high-1.png | ECR scan on push: one HIGH finding (zlib), accepted and documented |
| 09-asg-service-linked-role-error.png | The Auto Scaling service-linked role error on a new account |

Not captured: HTTP to HTTPS redirect, a phone on mobile data timing out, the alarm emails (they arrived; no screenshot yet).
