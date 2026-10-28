# Hardening for production

This sample is for evaluation and proof-of-concept use. This page lists what to add before you use it in
production.

- [Intended use](#intended-use)
- [Account and organization](#account-and-organization)
- [Network egress](#network-egress)
- [Endpoints and models](#endpoints-and-models)
- [Audit data in another account](#audit-data-in-another-account)
- [Detection and response](#detection-and-response)
- [Supply chain](#supply-chain)
- [Access and data](#access-and-data)

## Intended use

The kit is built for interactive work. A user runs Claude Code on their own box, reviews what Claude does,
and works on code their organization owns. Boxes have outbound internet access through the NAT for Git,
package installs and Claude Code updates.

Autonomous pipelines that build and run untrusted code, or run exploits against test targets, need more
isolation:

- **One AWS account per engagement or target,** closed when the work ends.
- **No internet egress.** Use VPC endpoints, package mirrors and a prebuilt image (see
  [Supply chain](#supply-chain)).
- **An enforcement layer outside the agent** that limits which targets and tools it can reach, such as an
  egress proxy with a per-engagement allowlist. Users and agents have `sudo` on the box, so prompts and
  settings on the box don't count as a control.

## Account and organization

- **A dedicated AWS account** for the boxes. Session Manager preferences and Bedrock invocation logging apply to
  the whole account and Region, and the organization guardrails assume that only scanning workloads run there.
- **The organization guardrails** in `policies/` (two SCPs and an RCP). See
  [Optional: organization guardrails](../README.md#optional-organization-guardrails-scps-and-rcp).
- **EC2 declarative policies** (AWS Organizations) fix account-wide EC2 settings so that principals in the
  account can't change them:
  - VPC Block Public Access in ingress-only mode. Boxes still reach the internet through the NAT gateway.
  - IMDSv2 required by default.
  - Block public access for AMIs and EBS snapshots.
  - Allowed AMIs, limited to Amazon and your own image accounts.
  - EC2 serial console access off.

## Network egress

Boxes reach the internet through a NAT gateway, and nothing filters that traffic. VPC flow logs record the
connections, but only as IP addresses, not domain names. AWS API calls through the kit's VPC endpoints don't
go through the NAT. The kit doesn't build egress controls.

**Control egress with AWS Network Firewall** on the NAT path. Use a stateful domain-list rule group that
allows only the domains boxes need, and drop all other traffic. Boxes need:

- AWS services that the box VPC has no endpoint for, such as STS (`sts.<region>.amazonaws.com`). With
  Identity Center sign-in, also `oidc.<sso-region>.amazonaws.com` and `portal.sso.<sso-region>.amazonaws.com`.
- Downloads: `github.com`, `release-assets.githubusercontent.com`, `claude.ai` and `downloads.claude.ai`.
  The Node and Python toolchains also need `registry.npmjs.org`, `pypi.org` and `files.pythonhosted.org`.
- Your code hosts and package registries, and whatever your harness downloads.

Network Firewall needs firewall subnets and route changes. It costs per endpoint-hour and per GB processed.
The kit's VPC has no firewall subnets, so either use your own VPC with central egress inspection
(`CreateNetwork = No`) or add the firewall outside the stack. In your own VPC, the firewall applies to every
workload, not only the boxes.

## Endpoints and models

In a VPC the kit builds, the endpoint policies allow only what boxes need:

| Endpoint | Allows |
|---|---|
| `bedrock-runtime` | Model calls (`InvokeModel`, `InvokeModelWithResponseStream`, `CountTokens`, `CallWithBearerToken`) by this account's principals. This endpoint has the policy in your own VPC too. |
| `bedrock`, `ssm`, `ssmmessages`, `ec2messages`, `logs`, `cloudformation` | Calls by this account's principals. |
| S3 gateway | Reads of the kit files (`<kit bucket>/<prefix>*`). Writes to the telemetry bucket, by this account's principals. Reads of the AWS-owned buckets for Amazon Linux packages and SSM Agent updates (`al2023-repos-<region>-de612dc2`, `amazon-ssm-<region>`, `aws-ssm-<region>`, `<region>-birdwatcher-prod`). |

As a result, a box can't copy data to other S3 buckets in the Region, and it can't use another account's
credentials with these services. Traffic to S3 in other Regions goes through the NAT. Egress filtering
(above) and the agent-perimeter SCP (box roles write only to the telemetry bucket) cover that path.

In your own VPC (`CreateNetwork = No`), the endpoints the kit creates serve every workload in the VPC. So
there, only `bedrock-runtime` gets a policy; add the others yourself if the VPC's workloads allow it.
Other workloads may use other accounts' roles, or `cfn-signal` and `cfn-init` calls that aren't signed with
IAM credentials.

To let boxes use another bucket, add a statement to the `S3GatewayEndpoint` policy in `infra/storage.yaml`.
If you patch boxes with Patch Manager, add its buckets too. Their names have per-Region suffixes; see
[SSM Agent communications with AWS managed S3 buckets](https://docs.aws.amazon.com/systems-manager/latest/userguide/ssm-agent-technical-details.html).

**Models.** The kit's policies allow Claude models only (`anthropic.claude-*`), and that includes `global.`
inference profiles. A global profile can route requests to any supported commercial AWS Region:

- **If your data must stay in one geography,** deny global cross-Region inference with an SCP (from the
  [Amazon Bedrock documentation](https://docs.aws.amazon.com/bedrock/latest/userguide/global-cross-region-inference.html)).
  Then use your geography's profile IDs (`us.`, `eu.`, `apac.`) for `ClaudeModel` and `ExtraModelId`:

  ```json
  {
    "Version": "2012-10-17",
    "Statement": [
      {
        "Sid": "DenyGlobalCrossRegionInference",
        "Effect": "Deny",
        "Action": "bedrock:*",
        "Resource": "*",
        "Condition": {
          "StringEquals": { "aws:RequestedRegion": "unspecified" },
          "ArnLike": { "bedrock:InferenceProfileArn": "arn:aws:bedrock:*:*:inference-profile/global.*" }
        }
      }
    ]
  }
  ```

- **To allow only the models you approved,** replace the `anthropic.claude-*` patterns with exact inference
  profile and foundation model ARNs. The patterns are in `BoxBedrockPolicy` and `UserGroupPolicy`
  (`infra/shared.yaml`), the permission set (`policies/permission-set-claude-scan-user.*`) and the
  agent-perimeter SCP.

## Audit data in another account

The telemetry bucket, its KMS key and the access-log bucket all live in the scanning account. An
administrator of that account can change or delete them. Keep a copy in a log-archive account with S3
Replication:

- Cross-Region Replication (CRR) copies to another Region.
- Same-Region Replication (SRR) keeps the copy in the same Region.

The kit doesn't build replication; set it up outside the stack:

1. **Destination bucket** in the log-archive account:
   - Versioning on.
   - S3 Object Lock with a default retention period (governance or compliance mode, per your policy).
   - Its own KMS key.
   - Object Ownership set to **Bucket owner enforced**.
   - A lifecycle rule that matches your retention.
2. **Replication role** in the scanning account. It needs:
   - On the source: `s3:GetReplicationConfiguration` and `s3:ListBucket` on the bucket, and
     `s3:GetObjectVersionForReplication` and `s3:GetObjectVersionTagging` on its objects.
   - `kms:Decrypt` on the kit's key (shared stack **Outputs** → `TelemetryKmsKeyArn`).
   - `s3:ReplicateObject` and `s3:ReplicateTags` on the destination, and `kms:Encrypt` on the
     destination key.
3. **Add the replication role to `AdminPrincipalArnPatterns`** (update the shared stack). The kit's bucket
   policy denies `s3:ListBucket` and object reads to every other principal.
4. **Destination bucket policy and key policy** that let the replication role replicate objects and use the
   key. Don't grant `s3:ReplicateDelete`.
5. **Replication rule** on the telemetry bucket:
   - Scope: the whole bucket, or the `claude-code/`, `session-logs/` and `bedrock-logs/` prefixes.
   - Replicate objects encrypted with AWS KMS, using the destination key.
   - Change replica ownership to the destination bucket owner.
   - Leave **delete marker replication** off, so deleting an object in the source doesn't hide the copy.
   - To copy objects that already exist, use S3 Batch Replication.

Replicate the access-log bucket the same way if you also need its record of reads off the account. Note that
CRR copies prompts, responses and the code Claude read into another Region, so check your data-residency
rules first. The replication rule isn't part of the template, so check that it's still in place after each
shared stack update.

## Detection and response

The kit alarms when a box's telemetry stops or isn't delivered. Add account-level detection on top:

- **Amazon GuardDuty,** including Runtime Monitoring for EC2 for process-level findings on boxes.
- **AWS Config rules** for the settings the kit relies on, such as `s3-bucket-versioning-enabled`,
  `ec2-imdsv2-check` and `vpc-flow-logs-enabled`. Use **IAM Access Analyzer** to flag external access to the
  bucket and key.
- **Amazon EventBridge rules on CloudTrail events** that notify the kit's SNS topic (shared stack
  **Outputs** → `AlarmTopicArn`). Watch for:
  - Requests from box roles (`claude-code-box-*`) that the SCPs denied.
  - IAM, security group, route table, VPC endpoint and NAT gateway changes in the scanning account.
  - Logging changes:
    - `StopLogging` and `DeleteTrail`.
    - Policy, lifecycle, versioning and replication changes on the telemetry bucket.
    - `DisableKey` and `ScheduleKeyDeletion` on the kit's key.
    - `DeleteModelInvocationLoggingConfiguration`.
    - Changes to the Session Manager preferences document.
- **Bedrock usage alarms** on the `AWS/Bedrock` `InputTokenCount` and `OutputTokenCount` metrics, plus an
  AWS Budgets alert on Bedrock cost. They catch runaway agent loops and stolen credentials.
- **A quarantine runbook,** written and practiced before you need it:
  1. **Isolate the box.** Replace its security group with one that has no rules. Existing connections keep
     going until they close. To cut them at once, add network ACL deny rules for the box's private IP
     address on its subnet.
  2. **Revoke credentials.** Use **Revoke active sessions** on the box role
     (`claude-code-box-<owner>-<region>`) and on the user's role. Then remove the user's permission set
     assignment or IAM group membership.
  3. **Preserve evidence.** Snapshot the box's EBS volume and stop the instance. Delete the box stack only
     after the investigation ends: deleting it deletes the instance and its volume. Keep that owner's
     telemetry, session recordings and Bedrock logs for the time window.
  4. **Clean up after.** Rotate anything the box could reach, such as tokens the user put on the box. Treat
     everything the box produced as untrusted.

## Supply chain

When a box is set up, it downloads and installs software:

- Claude Code (latest version).
- The OpenTelemetry Collector (a pinned version, from GitHub).
- Amazon Linux packages.
- npm and PyPI tools.
- The harness (from its default branch).

A compromised or changed upstream reaches every new box.

- **Build a golden image** with EC2 Image Builder. Start from Amazon Linux 2023 and add the toolchains,
  Claude Code and the collector at versions you've reviewed. Scan the image with Amazon Inspector.
  1. Publish its AMI ID to an SSM parameter.
  2. Set the box parameter `LatestAmiId` to that parameter's name.
  3. Set `Toolchains = none` so setup doesn't install them again.

  Setup still installs Claude Code and the collector itself. To use the image's copies, edit
  `scripts/modules/claude-code.sh` and `scripts/modules/telemetry.sh`. Also turn off Claude Code's
  auto-updates (`DISABLE_AUTOUPDATER=1` in `scripts/modules/managed-settings.sh`), so boxes keep the
  version you reviewed.
- **Pin your harness** to a reviewed commit or release, and keep a copy in a repository you control.
- **Use package mirrors,** such as AWS CodeArtifact for npm and PyPI, instead of the public registries.
  With a golden image and mirrors, boxes need no internet egress.

## Access and data

- **Session length:** the permission set template's `SessionDurationHours` defaults to 8 hours. Use the
  shortest length that works for your users.
- **MFA:** require MFA in IAM Identity Center. In IAM user mode, set `RequireMfa = Yes` (see
  [IAM users](../README.md#iam-users)).
- **Who can read telemetry:** review the roles in `AdminPrincipalArnPatterns` regularly. Telemetry includes
  prompts, responses and the code Claude reads. The access-log bucket records each read.
- **CloudTrail data events** for the telemetry bucket, if you need S3 API activity in your organization trail.
- **Retention and Region:** set `RetentionDays` and `LogRetentionDays` to match your data-retention policy.
  Telemetry, session recordings and Bedrock logs contain the code that boxes read, and they stay in the
  stack's Region.
- **Treat scan results as untrusted.** Reports, patches and proof-of-concept code come from an agent that read
  untrusted repositories, and they may contain injected instructions or malicious code. Review them before
  they leave the box, and run them only in an isolated environment.
- **Patching:** boxes start from the latest Amazon Linux 2023 AMI when they're created. Rebuild them
  regularly (see [Updating](../README.md#updating)), or patch them with AWS Systems Manager Patch Manager and
  add its buckets to the S3 gateway endpoint policy (see [Endpoints and models](#endpoints-and-models)).
