# Deploy, test, break, destroy

About 3 hours and £1-2, destroyed the same day. Everything runs from AWS CloudShell, so there's nothing to install locally.

## 0. Before you start

- Use your own AWS account, signed in as an IAM admin user with MFA. Region: eu-west-2 (London).
- Set a budget alert first: Billing > Budgets > Zero spend or £5.
- Get your public IP from https://checkip.amazonaws.com **in your own browser**, not in CloudShell, which has its own IP.
- Use your own test Entra tenant only, never an employer's or a client's.

## 1. Entra ID test tenant and app registration (free)

In https://entra.microsoft.com:

1. Use your personal tenant, or create one under Manage tenants. Copy the **Directory (tenant) ID**.
2. Users > New user: `analyst1@<tenant>.onmicrosoft.com`. First sign-in sets up MFA through security defaults.
3. App registrations > New registration, single tenant. Redirect URI: **Web**, `https://localhost/oauth2/idpresponse` (a placeholder until step 5). Copy the **Application (client) ID**.
4. Certificates & secrets > New client secret. Copy the **Value**, not the Secret ID.
5. API permissions > Grant admin consent.
6. Enterprise applications > the app > Properties > **Assignment required: Yes**. Then Users and groups > assign analyst1.

## 2. CloudShell and Terraform

Upload the repo as a zip (Actions > Upload file), or clone it. Then:

```bash
mkdir -p ~/bin && cd /tmp
curl -fsSLO https://releases.hashicorp.com/terraform/1.9.8/terraform_1.9.8_linux_amd64.zip
unzip -o terraform_1.9.8_linux_amd64.zip -d ~/bin
export PATH=$HOME/bin:$PATH
export TF_DATA_DIR=/tmp/tfdata     # the AWS provider is too big for CloudShell's 1 GB home
cd ~/secure-analytics-dashboard-aws/terraform
cp terraform.tfvars.example terraform.tfvars && nano terraform.tfvars
terraform init
terraform validate                 # should say Success
terraform fmt -check -recursive    # if it lists files: terraform fmt -recursive
```

If CloudShell restarts, run the two `export` lines and `terraform init` again. The state stays in your home folder.

## 3. Registry and empty secret first

```bash
terraform apply -target=aws_ecr_repository.app -target=aws_secretsmanager_secret.oidc
read -s ENTRA_SECRET     # paste the client secret Value, press Enter
aws secretsmanager put-secret-value --secret-id pharma-dash/entra-client-secret --secret-string "$ENTRA_SECRET"
unset ENTRA_SECRET
```

Store the secret as plain text, not key/value JSON. Any `terraform plan` fails until it has a value.

## 4. Build and push the image

```bash
cd ../app
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGISTRY=$ACCOUNT.dkr.ecr.eu-west-2.amazonaws.com
aws ecr get-login-password --region eu-west-2 | docker login --username AWS --password-stdin $REGISTRY
docker build -t $REGISTRY/pharma-dash:v2 .
docker push $REGISTRY/pharma-dash:v2
```

## 5. Full apply

```bash
cd ../terraform && terraform plan && terraform apply
```

Then:

1. Set the Entra redirect URI to the `entra_redirect_uri` output.
2. Confirm the alarm subscription email.
3. Wait 5-10 minutes for the server to bootstrap, and check it:

```bash
TG=$(aws elbv2 describe-target-groups --names pharma-dash-app --query 'TargetGroups[0].TargetGroupArn' --output text)
aws elbv2 describe-target-health --target-group-arn $TG --query 'TargetHealthDescriptions[].TargetHealth.State'
```

## 6. Test

1. Open `dashboard_url` in a private window and accept the self-signed certificate warning.
2. Sign in as analyst1. You should see "Signed in as ... (verified)".
3. From a phone on mobile data, the URL should time out, because only your IP is allowed.
4. The audit events appear in CloudWatch under `/pharma-dash/app-audit`.

## 7. Break it

- `sudo podman kill dashboard` (via Session Manager): systemd restarts it in about 20 seconds.
- `sudo systemctl stop dashboard`:
  1. The target goes unhealthy and the alarm emails you.
  2. The Auto Scaling Group replaces the server.
  3. The audit log survives in CloudWatch.

## 8. Destroy

```bash
terraform destroy
rm -f terraform.tfstate*     # state holds the secret and the TLS private key
```

Then check that no NAT gateway or Elastic IP is left, and delete the Entra client secret.

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| Browser times out | Wrong IP in `allowed_cidrs`, or you're on a VPN |
| AADSTS50011 | Redirect URI doesn't match the output |
| AADSTS50105 | User not assigned to the app |
| 401 or 561 after sign-in | Wrong secret: the Secret ID instead of the Value, or JSON instead of plain text |
| 502 or 503 | Server still booting or app crashed. Check `/var/log/bootstrap.log`, `systemctl status dashboard` and `/var/log/dashboard/app.log` |
| "not verified" or the session closes | Token check failing. Check the server can reach the internet through the NAT |


## Remote state (recommended)

Terraform state holds secrets, so keep it off your laptop. Create the bucket and lock table once, outside this Terraform (it cannot create its own state store):

```
BUCKET=pharma-dash-tfstate-$(openssl rand -hex 4)
aws s3api create-bucket --bucket $BUCKET --region eu-west-2 --create-bucket-configuration LocationConstraint=eu-west-2
aws s3api put-public-access-block --bucket $BUCKET --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-versioning --bucket $BUCKET --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket $BUCKET --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"aws:kms"},"BucketKeyEnabled":true}]}'
aws dynamodb create-table --table-name pharma-dash-tflock --attribute-definitions AttributeName=LockID,AttributeType=S --key-schema AttributeName=LockID,KeyType=HASH --billing-mode PAY_PER_REQUEST --region eu-west-2
```

Then copy `terraform/backend.tf.example` to `terraform/backend.tf` and run `terraform init -migrate-state -backend-config="bucket=$BUCKET"`. Check `terraform plan` shows no changes.

To tear down: run `terraform destroy` first, then delete every version in the bucket and the bucket itself, then delete the lock table. They sit outside Terraform, so destroy does not remove them.
