# Build log

What actually happened when I deployed this. Problems and fixes are kept on purpose: they're the useful part.

## Deployment

- **Date:** 9 October 2026
- **Region:** eu-west-2 (London)
- **Account:** a personal AWS account, with a personal Microsoft Entra tenant
- **Image tags:** v1 (first deploy), v2 (fix described below)
- **Terraform:** 1.9.8, run from AWS CloudShell, local state

## Problems and fixes

| # | What went wrong | How I found it | Fix |
| --- | --- | --- | --- |
| 1 | Entra sign-up: "selected user account does not exist in tenant" | Error at sign-in | A personal Microsoft account has no tenant of its own. Created a directory through a free Azure account |
| 2 | CloudShell opened in us-east-1 | Resources not where expected | Switched to eu-west-2 and re-uploaded the code |
| 3 | `terraform.tfvars` broken after pasting into nano | Parse error | Rewrote it with a heredoc |
| 4 | Client secret appeared in a chat window | I noticed straight away | Treated it as exposed: deleted it in Entra, created a new one, stored it with `read -s` so it never hits history |
| 5 | Secret read as null from Secrets Manager | App could not sign in | I had run `read -s` but not `put-secret-value`. Ran it and checked a VersionId came back |
| 6 | CloudShell session expired mid-build | Commands not found | Re-exported PATH and `TF_DATA_DIR`, ran `terraform init`, confirmed state still listed the resources |
| 7 | Auto Scaling Group failed to create | `Access denied when assuming role AWSServiceRoleForAutoScaling` | The service-linked role was not ready on a new account. Confirmed it existed and re-ran `terraform apply` |
| 8 | ECR scan: HIGH 1, CVE-2026-85091 (zlib heap overflow) | Scan on push | No fixed version available. Accepted and documented. v2 on a fresh base shows the same single finding |
| 9 | Dashboard stuck on spinners for some users | Network tab: websocket opened and closed in about 112 ms. App log: `invalid token: Signature verification failed` | **Bug in my code.** The load balancer signs `header.payload` with base64 padding. v1 stripped the padding first, so verification failed whenever a token needed padding (depends on name length). v2 verifies the exact signed text, with a test that fails on v1 |
| 10 | Misdiagnoses on the way | Each looked plausible | Ruled out in turn: Chrome third-party cookie blocking, missing email on the test user, my Azure subscription, the Entra free tier, and the network path (the key endpoint answered 403, so the route was fine) |
| 11 | No audit events in CloudWatch, `journalctl` empty | `podman logs` said the container was not logging | `--log-driver=passthrough` sent output to /dev/null. v2 uses `k8s-file` with a path, and the agent ships that file |
| 12 | App hid why a token check failed | Bare `except` returned "unverified" | v2 logs the reason, never the token |
| 13 | Each audit line appears twice in CloudWatch | Two writers to one file (log driver and systemd append) | Known and harmless. Fix is `StandardOutput=journal` and `StandardError=journal`. Not applied yet |

## Failure tests

**Container killed** (`podman kill dashboard`): systemd restarted it in about 22 s, healthy in about 60 s.

**Service stopped** (`systemctl stop dashboard`):

| Event | Time after the stop |
| --- | --- |
| Target marked unhealthy | 48 s |
| Auto Scaling launched a replacement | 85 s |
| Replacement healthy | about 5 minutes |

**Instance stopped from the console:** the Auto Scaling Group replaced it in about 2 minutes.

**Access test:** from a VPN address the site timed out, as designed. The load balancer security group allows only one IP.

**Alerts:** the `no-healthy-hosts` alarm email arrived about 4.5 minutes after the service stop, and the OK email about 2 minutes later, from the SNS topic.

**Not confirmed:** whether the replaced server's log stream stayed in CloudWatch after replacement.

## Teardown

To be completed after `terraform destroy`: errors, leftovers, bill.

## What I learned

- Test the identity check against a token from the real load balancer early. My unit test used tokens that happened not to need padding.
- Ship container logs on day one. Silence in the log was the first sign something was wrong.
- A health check and an Auto Scaling Group give you self-healing for free, but one server still means about five minutes of downtime. Two servers in two zones is the answer, not a faster restart.
- Pasting a secret into the wrong window is easy. Rotate immediately and carry on.
