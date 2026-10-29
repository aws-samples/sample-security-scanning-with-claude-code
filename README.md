# Security Scanning with Claude Code on AWS

This sample is a quick start for deploying isolated, per-user Amazon EC2 environments ("boxes") that run
[Claude Code](https://code.claude.com/docs) on Amazon Bedrock. Security teams can use them to run security
harnesses, such as Anthropic's open source defending-code reference harness or their own, with frontier
cybersecurity models like Claude Mythos to find, triage and fix vulnerabilities in code they own.

**Why isolated boxes?** AI-assisted vulnerability discovery clones untrusted repositories and lets an agent run
commands and build code. This sample keeps that work off laptops and away from production: each user gets their
own box with no inbound access, model calls use the user's own AWS identity, and prompts, responses, commands
and sessions are recorded in your AWS account (see [Audit and detection](#audit-and-detection) for what each record
covers). An administrator deploys everything from the AWS console: one shared
setup per account and region, then one box per user.

> **Note:** This sample is for evaluation and proof-of-concept use. Before you use it in production, apply the
> steps in [Hardening for production](docs/hardening-for-production.md) and review it with your security team.

> **Activity on a box is recorded.** Each user's terminal sessions and Claude Code activity (prompts,
> Claude's responses, the commands it runs, and the file contents it reads) are recorded for audit and
> stored in the account's telemetry bucket, readable only by administrators. Tell users this before they
> get a box.

## Use cases

- **Run a security harness on your code:** each box can come with an open source harness, such as Anthropic's
  defending-code reference harness, or you can bring your own (`InstallHarness = false`). Each box has common
  toolchains, `ExtraPackages` for more, and `sudo`.
- **Evaluate frontier cybersecurity models:** use Claude models on Amazon Bedrock, and add models that Claude Code
  doesn't list itself, such as Claude Mythos, to its `/model` picker.

## What each user gets

- An Amazon Linux 2023 instance in a private subnet. No inbound ports, no SSH keys; access is through
  AWS Systems Manager Session Manager only.
- A `claude` account with full `sudo`, so Claude Code and the user can install whatever they need.
- Claude Code configured for Amazon Bedrock, signed in with **the user's own AWS identity**
  (`aws login` for IAM users, or IAM Identity Center), so model usage is attributed to the person.
- Common toolchains: Java 21 + Maven, Node.js 22 + TypeScript, Python 3.12 + uv, Go, Rust, C/C++, .NET 8.
- Optionally, an open source security harness (Anthropic's defending-code reference harness), cloned and ready to use.
- Automatic stop after a configurable number of idle hours.

## How it fits together

```
 Your account (one region)
 ┌────────────────────────────────────────────────────────────────────────────────────────────┐
 │ shared.yaml (once)                                                                         │
 │   network.yaml ─ VPC, private subnet, NAT, endpoints, flow logs       (or your VPC)        │
 │   storage.yaml ─ telemetry + access-log buckets, KMS key, S3 endpoint (or your bucket)     │
 │   Session Manager preferences ─ land as 'claude', record every session                     │
 │   Bedrock invocation logging ─ every model request/response, server-side                   │
 │   SNS topic ─ emails the admin when a box's telemetry goes silent                          │
 │                                                                                            │
 │ box.yaml (once per user) ───────────────────────────────────────────────────────────────── │
 │   EC2 box ── Claude Code ──OTLP──▶ local collector ──▶ s3://<bucket>/claude-code/<owner>/  │
 │      │                                        └──heartbeat──▶ CloudWatch ─▶ alarm ─▶ SNS   │
 │      └── Bedrock (through the VPC endpoint) using the user's own sign-in                   │
 └────────────────────────────────────────────────────────────────────────────────────────────┘
```

The shared stack creates (or adopts) the network and the telemetry bucket, configures Session Manager and Bedrock
invocation logging for the account, and holds the settings every box uses. Each box stack creates one EC2 instance
for one user. On the box, Claude Code sends its telemetry to a local OpenTelemetry collector, which writes it to the
telemetry bucket and sends a heartbeat metric to CloudWatch; an alarm emails the admin when a running box stops
sending it. Model calls go to Amazon Bedrock with the user's own sign-in.

## What's in this repository

| Path | Purpose |
|---|---|
| `infra/shared.yaml` | **Deploy once per account and region.** Root stack; nests the two below. |
| `infra/network.yaml` | New VPC and the interface VPC endpoints boxes use; with your own VPC, only the endpoints you choose. |
| `infra/storage.yaml` | Telemetry bucket, KMS key, S3 gateway endpoint (each skippable). |
| `box/box.yaml` | **Deploy once per user.** The user's box, its role, and alarms. |
| `scripts/box-bootstrap.sh` | Runs on each box at first boot (downloaded from your S3 bucket) and runs the setup modules below. |
| `scripts/modules/` | One script per setup step: corporate CA, preflight checks, user, packages, telemetry, each toolchain, Claude Code, sign-in profile, settings, harness, banner, final checks. |
| `scripts/VERSION` | The kit version (commit date and hash), filled in when you download the repository as a zip. Boxes show it in the login banner and in `/etc/claude-scan/kit-version`. |
| `scripts/scan-harness.sh` | Helper that sets up the harness on each box and runs headless scans as an isolated user. |
| `scripts/claude-scan-doctor.sh` | The box health check users run when something doesn't work (`claude-scan-doctor`). |
| `policies/` | The `ClaudeScanUser` Identity Center permission set, and optional AWS Organizations guardrails (SCPs and an RCP). |
| `deploy.sh` | Optional command-line shortcut for the console steps below. |
| `docs/hardening-for-production.md` | What to add before you use the sample in production. |

## Prerequisites

- **An AWS account and region** for the boxes. A dedicated account is recommended
  (see [Account-wide settings](#account-wide-settings)).
- **Bedrock model access to Anthropic Claude models in that region**, including Anthropic's one-time
  use-case form (Bedrock console → Model catalog).
- **Administrator access** to deploy IAM resources, VPCs and CloudFormation stacks.
- **For each user:** an IAM user who can sign in to the console, or an IAM Identity Center user.
- **On each user's computer:** [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
  2.32 or later and the
  [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)
  (only needed to connect from a terminal; the EC2 console works without them).
- **Costs:** deploying creates billable resources; see [Costs](#costs) and [Clean up](#clean-up).

## Set up (console)

### 1. Upload the kit to S3

1. Download this repository (**Code → Download ZIP**) and unzip it, or clone it.
2. In the **S3 console**, create a bucket **in the region you'll deploy to** (or pick an existing one).
   It can stay private; CloudFormation reads it with your permissions.
3. Upload the repository's files into a folder named `claude-scan-kit` (the default `ArtifactPrefix`), so you
   have `s3://<bucket>/claude-scan-kit/infra/shared.yaml`.
4. Open `infra/shared.yaml` in the S3 console and copy its **Object URL**.

### 2. Deploy the shared setup (once per account and region)

1. **CloudFormation console → Create stack → With new resources.**
2. **Template source: Amazon S3 URL** → paste the Object URL of `infra/shared.yaml`.
3. **Stack name:** `claude-scan-shared` (the box template defaults to this name).
4. Fill in the parameters (see [Shared parameters](#shared-parameters)). At minimum:
   - **Kit bucket name** - the bucket from step 1 (just the name).
   - **Admin email for alarms.**
   - **Admin role ARN patterns** - the roles that may read telemetry (see the parameter's description).
   - **How users sign in** - `IdentityCenter` (enter the start URL and Identity Center region), `IamUser`
     or `InstanceRole`; applies to every box (see [Sign-in modes](#sign-in-modes)).
   - Choose **Yes** to create a VPC and bucket, or **No** and enter your existing IDs.
5. On the last page, tick both acknowledgements (IAM resources with custom names, and
   `CAPABILITY_AUTO_EXPAND` for nested stacks), then **Submit**.
6. When the stack reaches `CREATE_COMPLETE` (about 5 minutes), **confirm the subscription email** AWS sends
   to the admin address. Without it, alarms aren't delivered.

### 3. Deploy a box for a user (once per user)

1. **CloudFormation console → Create stack**, **Amazon S3 URL** → the Object URL of `box/box.yaml`.
2. **Stack name:** `claude-scan-box-<owner>`, for example `claude-scan-box-jdoe`.
3. Parameters:
   - **Owner** - short lowercase name, for example `jdoe`. Used in names, tags and telemetry paths.
   - Optional: instance type, disk size, toolchains, extra packages, idle-stop hours. Sign-in and models
     come from the shared stack.
4. Tick the IAM acknowledgement and **Submit**. The box is ready at `CREATE_COMPLETE`, typically
   5-25 minutes (toolchain installs take most of it).
5. **Give the user access to their box** (once per user). The user's `Owner` value must equal the box's `Owner`:
   - `IdentityCenter`: assign the `ClaudeScanUser` permission set, and make sure the user's `Owner`
     attribute holds that value (see [Identity Center permission set](#identity-center-permission-set)).
   - `IamUser`: add the IAM user to the shared stack's group (shared stack **Outputs** → `UserGroup`), and tag the
     user `Owner = <owner>` (IAM console → Users → the user → Tags). See [IAM users](#iam-users).
   - `InstanceRole`: nothing per user.
6. Send the user the box stack's **Outputs** → `ConnectCommand`. The login banner shows how to sign in.

### 4. The user connects and signs in

From a terminal (Windows, macOS or Linux) with AWS CLI v2 and the Session Manager plugin, signed in to
their own AWS identity on that computer (for example `aws login`):

```
aws ssm start-session --region <region> --target <instance-id>
```

Or: **EC2 console → Instances → select the box → Connect → Session Manager → Connect.**

They land as the `claude` user and see a banner with the next steps:

| AuthMode | Sign in on the box |
|---|---|
| `IamUser` | `aws login --remote --profile claude-login` - open the printed link on your laptop, sign in to the console (with MFA if you use it), paste the code back. Lasts up to 12 hours; run it again when it expires. |
| `IdentityCenter` | `aws sso login --profile claude --use-device-code` - open the link, approve. Claude Code re-runs this automatically when the session expires. |
| `InstanceRole` | Nothing to do. |

### 5. Start working

```
tmux                                  # keeps long jobs alive if the connection drops
claude                                # Claude Code, ready to use
```

Clone the code you want to review, or use the harness the box set up (see [About the harness](#about-the-harness)).

**Scrolling in tmux:** the mouse wheel scrolls back through earlier output (the box sets `mouse on` and a
50,000-line history). On Windows, use Windows Terminal rather than the legacy `cmd.exe` window, which
doesn't pass the mouse through. Without a mouse, press `Ctrl-b` then `[`, scroll with `PgUp`/`PgDn`, and
press `q` to exit. To select text with your own terminal instead of tmux, hold Shift (Option in iTerm2)
while dragging.

## Configuration

Details for customizing the shared and box stacks. The defaults work for most deployments; the setup steps
link here where a choice matters.

### Sign-in modes

| Mode | Identity Bedrock sees | Credentials on the box | Notes |
|---|---|---|---|
| `IamUser` | The person's IAM user | Short-lived session from `aws login` (no access keys) | Requires AWS CLI 2.32+ (the box has it). |
| `IdentityCenter` (default) | The person's Identity Center session | Short-lived SSO session | Best when you already use Identity Center. |
| `InstanceRole` | The box's role | Instance role (automatic) | Simplest; usage is attributed only by owner tag and telemetry. |

The mode is set once, in the shared stack, for every box. In the two user modes the boxes' own roles are
**denied Bedrock**, so an expired sign-in fails clearly instead of silently falling back to the box's identity.

**MFA.** `aws login` signs in through the console, so it uses whatever MFA the IAM user has. The shared
stack's `RequireMfa` option additionally requires `aws:MultiFactorAuthPresent` on the user's Bedrock and
Session Manager permissions. Leave it off until you've confirmed your users' sessions carry that flag, or
they'll be locked out.

### Shared parameters

| Parameter | Default | Notes |
|---|---|---|
| `ArtifactBucket`, `ArtifactPrefix` | -, `claude-scan-kit/` | Where you uploaded the kit. Same region as the stack. |
| `AdminEmail` | - | Receives alarms. Confirm the subscription. |
| `AdminPrincipalArnPatterns` | - (required with a new bucket) | Only these roles can read the bucket this stack creates. The console's account menu shows `<role or permission set>/<user>`; for a permission set enter `arn:aws:iam::*:role/aws-reserved/sso.amazonaws.com/*AWSReservedSSO_<permission set>_*`. |
| `AuthMode` | `IdentityCenter` | `IdentityCenter`, `IamUser` or `InstanceRole`, for every box. See [Sign-in modes](#sign-in-modes). |
| `SsoStartUrl`, `SsoRegion` | - | IdentityCenter mode: the access portal URL and Identity Center's region. |
| `SsoAccountId`, `SsoRoleName` | this account, `ClaudeScanUser` | IdentityCenter mode: the account and permission set users sign in with. |
| `RequireMfa` | No | IamUser mode; see [Sign-in modes](#sign-in-modes). |
| `ClaudeModel` | blank (Claude Code default) | Default model for every box: a Bedrock inference profile ID with your region's prefix - `us.` (US regions), `eu.` (Europe), `apac.` (Asia Pacific) or `global.` - for example `us.anthropic.claude-opus-5-5`. Users can still switch with `/model`. |
| `ExtraModelId`, `ExtraModelName`, `ExtraModelCapabilities`, `ExtraModelContextTokens` | blank, blank, Mythos 5.1 values, blank | Adds a row to Claude Code's `/model` picker for a model it doesn't list itself, such as Claude Mythos. See [Adding Claude Mythos](#adding-claude-mythos-or-another-model-claude-code-doesnt-list). |
| `CreateNetwork` | Yes | No = enter `ExistingVpcId`, `ExistingSubnetId` (private, with NAT), optionally `ExistingBedrockVpceId`. |
| `VpcCidr`, `PublicSubnetCidr`, `PrivateSubnetCidr` | `10.42.0.0/16`, `10.42.0.0/24`, `10.42.1.0/24` | The new VPC's address ranges. Change them together: both subnets must be inside the VPC's block. |
| `InterfaceEndpoints` | `auto` | Interface VPC endpoints to create. `auto` = all five below when the stack creates the VPC, none with your own VPC. Or `none`, or a comma-separated list: `ssm` (ssm, ssmmessages: Session Manager), `ec2messages` (only for SSM Agent versions before 3.3.40; not offered in newer Regions), `bedrock-runtime` (model calls), `bedrock` (model and inference-profile lookups), `logs` (heartbeat, failure reports, session recordings), `cloudformation` (the box's setup signal). With your own VPC, see below. |
| `ExistingVpcCidrs` | blank | With your own VPC and `InterfaceEndpoints`: all of the VPC's CIDR blocks (up to 4). |
| `CorporateCaBundleKey` | `none` | Only behind a TLS-inspecting firewall or proxy: upload its CA certificate (PEM) with the kit, e.g. `scripts/corporate-ca.pem`, and enter that path. Boxes add it to the system trust store and set `NODE_EXTRA_CA_CERTS`, `AWS_CA_BUNDLE`, `REQUESTS_CA_BUNDLE`, `SSL_CERT_FILE` and `PIP_CERT`. |
| `CreateS3GatewayEndpoint` | `auto` | `auto` = Yes with a new VPC, No with your own. `Yes` with your own VPC also needs `ExistingRouteTableIds` (the box subnet's route table). Skip if the VPC already has one. |
| `CreateBucket` | Yes | A bucket the stack creates is encrypted with its own KMS key and gets an access-log bucket. No = enter `ExistingBucketName`, and `ExistingKmsKeyArn` (the key ARN, not an alias) if it uses SSE-KMS: boxes then get access to that key only. |
| `RetentionDays` | 365 | Telemetry, Bedrock logs and session recordings in S3. |
| `ConfigureSessionManager` | Yes | Account-wide; see below. |
| `ConfigureBedrockLogging` | Yes | Account-wide; see below. |
| `LogRetentionDays` | 365 | Live session recordings in CloudWatch Logs. |
| `ExistingSessionLogGroupName` | blank | Only when re-creating a deleted shared stack under the same name: enter the kept `/claude-scan/<stack>/sessions` group to keep using it. |

#### Account-wide settings

Two settings apply to the **whole account in that region**, not just the boxes. That's why a dedicated
account is recommended:

- **Session Manager preferences** (`ConfigureSessionManager`): every Session Manager session to any
  instance runs as the `claude` OS user and is recorded. Instances without a `claude` user can't be
  reached with Session Manager while this is on. Creating the stack fails if someone already saved
  preferences in this region (Session Manager console → Preferences); set this to No to keep yours.
- **Bedrock model invocation logging** (`ConfigureBedrockLogging`): sends every model call's request and
  response in this region to the bucket. Creating the stack fails if logging is already configured in this
  region (Bedrock console → Settings); set this to No to keep yours. Deleting the stack turns logging off only
  if the stack set it and it still points to the stack's bucket.

#### Using your own VPC

The subnet must be private with outbound internet access (NAT), and the VPC must have DNS hostnames and
DNS support enabled. Boxes reach GitHub, package repositories and Claude Code updates through the internet.
These AWS services should be reachable through VPC endpoints (or the NAT):

| Service | Endpoint | Used for |
|---|---|---|
| S3 | `com.amazonaws.<region>.s3` (gateway) | Kit scripts, telemetry, session recordings, Amazon Linux packages |
| Session Manager | `ssm`, `ssmmessages` (and `ec2messages` for SSM Agent versions before 3.3.40) | Connecting to boxes (there's no other way in) |
| Bedrock | `bedrock-runtime`, `bedrock` | Model calls; model and inference-profile lookups |
| CloudWatch Logs | `logs` | Heartbeat, setup failure reports, live session recordings |
| CloudFormation | `cloudformation` | The box's "setup finished" signal |

The stack can create any of them (`CreateS3GatewayEndpoint`, `InterfaceEndpoints`). Before you list
interface endpoints for your own VPC:

- **They affect the whole VPC.** Private DNS sends *every* instance's calls to that service through the
  new endpoint, which is why the endpoints accept HTTPS from all CIDR blocks in `ExistingVpcCidrs`.
- **List only services the VPC has no endpoint for yet.** Creating a second endpoint for the same service
  fails (conflicting private DNS).
- **For endpoints you already have**, check that their security group allows HTTPS (443) from the box
  subnet's CIDR, or from the kit's box security group (shared stack **Outputs** → `BoxSecurityGroupId`; all
  boxes use it, so one rule covers every box), and that a restrictive S3 gateway endpoint policy allows the kit bucket, the telemetry
  bucket (`s3:PutObject`, `s3:GetEncryptionConfiguration`) and the Amazon Linux repositories
  (`arn:aws:s3:::al2023-repos-<region>-de612dc2/*`).
- If the VPC already has a `bedrock-runtime` endpoint, enter its ID as `ExistingBedrockVpceId` (used by
  the optional agent-perimeter SCP).

#### Using your own bucket

The stack can't change an existing bucket's policies, so add these yourself:

1. **Bedrock invocation logging** (if `ConfigureBedrockLogging = Yes`), as a bucket policy statement:
   ```json
   {"Sid": "AllowBedrockInvocationLogging", "Effect": "Allow",
    "Principal": {"Service": "bedrock.amazonaws.com"}, "Action": "s3:PutObject",
    "Resource": "arn:aws:s3:::<bucket>/bedrock-logs/*",
    "Condition": {"StringEquals": {"aws:SourceAccount": "<account-id>"},
                  "ArnLike": {"aws:SourceArn": "arn:aws:bedrock:<region>:<account-id>:*"}}}
   ```
2. **If the bucket uses a KMS key**, let Bedrock use it with this key policy statement:
   ```json
   {"Sid": "BedrockInvocationLogging", "Effect": "Allow",
    "Principal": {"Service": "bedrock.amazonaws.com"}, "Action": "kms:GenerateDataKey", "Resource": "*",
    "Condition": {"StringEquals": {"aws:SourceAccount": "<account-id>"}}}
   ```
   The key must be in the same account. Box roles get encrypt-only use of it through S3 automatically.
3. **Restrict reads to administrators**: the data includes prompts and source code.
4. **Default encryption must be on** (all new buckets have it). Session recordings require it.

### Box parameters

| Parameter | Default | Notes |
|---|---|---|
| `SharedStackName` | `claude-scan-shared` | Name of the shared stack. Network, bucket, sign-in, models, permissions and the security group come from it. |
| `Owner` | - | Lowercase, 2-30 chars. Must equal the user's `Owner` attribute (Identity Center) or tag (IAM user). |
| `InstanceType` | `t3.xlarge` | x86_64 types only. |
| `VolumeSize` | 100 GiB | |
| `Toolchains` | all seven | Comma-separated, no spaces: `java` (Corretto 21, Maven), `node` (Node.js 22, TypeScript, tsx, pnpm, yarn), `python` (3.12, pip, uv), `go`, `rust` (with Cargo), `cpp` (GCC, Clang, Make, CMake, GDB), `dotnet` (.NET 8 SDK). `none` installs none. |
| `ExtraPackages` | blank | More Amazon Linux packages, space-separated. |
| `EnableSandbox` | false | Installs Docker, for harnesses that run the code under test in containers. |
| `InstallHarness` | true | Clones Anthropic's open source defending-code reference harness. Claude Code and telemetry are always installed. |
| `AutoStopIdleHours` | 4 | Stops the box after this many hours under 2% CPU. 0 = never. Users can start their own box again from the EC2 console (Instance state → Start). |

#### Adding Claude Mythos (or another model Claude Code doesn't list)

Claude Code ships with a fixed list of models. Claude Mythos 5.1 isn't on it, and access to it is gated by
Anthropic per account, so the kit adds it only when you set these **shared stack** parameters. Every box in the
account then shows it:

| Parameter | Value for Claude Mythos 5.1 |
|---|---|
| `ExtraModelId` | `us.anthropic.claude-mythos-5-1` in US regions, `global.anthropic.claude-mythos-5-1` elsewhere |
| `ExtraModelName` | `Mythos 5.1` |
| `ExtraModelCapabilities` | `effort,xhigh_effort,max_effort,thinking,adaptive_thinking` (the default): adaptive thinking is always on, and effort goes from low to max |
| `ExtraModelContextTokens` | `1000000`: without it, Claude Code assumes 200K for a model it doesn't recognize and compacts the conversation too early |

Users then pick **Mythos 5.1** in `/model`. To start every session on it, also set `ClaudeModel` to the same ID.

**Before it works, in each account:**

- **Access:** your organization must be approved for Mythos through Anthropic's trusted access program,
  and the model enabled in the Bedrock console.
- **Data retention:** Mythos requires opting in to provider data sharing. Set the account's Bedrock data
  retention mode to `provider_data_share` with the Data Retention API. The
  [model card](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-mythos-5-1.html)
  links to the details.
- **No policy changes needed:** the ID matches the kit's Claude-only IAM and SCP patterns, and the first call
  subscribes to its Marketplace listing through Bedrock, which the kit's policies allow.

### Identity Center permission set

For `AuthMode = IdentityCenter`, don't sign users in with an administrator permission set. While a
session is active, anything running on the box can use it, including code in a repo being scanned. Use
the kit's least-privilege permission set instead, `ClaudeScanUser`. It allows:

- Claude models on Bedrock, and short-term Bedrock API keys for sandboxed tools
- Session Manager, plus starting and stopping, **for the user's own box only**
- the read-only lookups the EC2 console needs to connect

"Own box" works through Identity Center
[attributes for access control](https://docs.aws.amazon.com/singlesignon/latest/userguide/attributesforaccesscontrol.html).
An `Owner` attribute on each user's session must equal the `Owner` tag on their box, which is the box
stack's `Owner` parameter. Pick the Identity Center attribute that holds that value. `${path:userName}` works
when user names are short and lowercase. `Owner` allows only lowercase letters, digits and hyphens, so user
names that are email addresses (`jdoe@example.com`) can't match: use an attribute from your identity source that
holds the short name instead (for example an employee alias), and make each box's `Owner` that value.

To check what a user's session actually carries, look up their sign-in in CloudTrail (in Identity Center's
region): event `AssumeRoleWithSAML`, field `requestParameters.principalTags`. It should show `{"Owner": "<owner>"}`.

**With CloudFormation (recommended):** deploy `policies/permission-set-claude-scan-user.yaml` in the
account that administers Identity Center (the management account or a delegated administrator):

1. **Identity Center instance ARN:** IAM Identity Center console → Settings.
2. **`ConfigureOwnerAttribute`:** leave it at Yes unless attributes for access control are already set up.
   It's instance-wide, so with No, add an `Owner` key there yourself.
3. **Assignment (optional):** fill in `AccountId`, `PrincipalType` and `PrincipalId` to assign a group or
   user to the scanning account in the same step.

The shared stack's `SsoRoleName` defaults to `ClaudeScanUser`.

**In the console:**

1. IAM Identity Center → Permission sets → Create → Custom permission set.
2. Paste `policies/permission-set-claude-scan-user.json` as the inline policy, and set the session duration
   (8 hours suits long scans).
3. Settings → Attributes for access control → add key `Owner` with your chosen attribute.
4. AWS accounts → the scanning account → Assign users or groups → `ClaudeScanUser`.

### IAM users

With `AuthMode = IamUser`, the shared stack creates an IAM group, `<shared stack>-users-<region>` (its
**Outputs** → `UserGroup`), with the same permissions as the `ClaudeScanUser` permission set plus `aws login`.
For each user:

1. **IAM console → User groups →** that group **→ Add users**.
2. **IAM console → Users →** the user **→ Tags → Add tag:** key `Owner`, value = their box's `Owner`.

"Own box" works the same way as with Identity Center: the `Owner` tag on the user must equal the `Owner` tag
on the box. A user without the tag can't connect to any box. Users sign in on the box with `aws login`
(no access keys).

## Security and audit

What the sample records, how boxes are isolated, and optional organization guardrails.

### Audit and detection

Users have full `sudo` on their box, so recording can't be enforced from inside it. Instead, several
layers record activity. The ones outside the box can't be switched off from it, but no single layer sees
everything (see [What each layer can miss](#what-each-layer-can-miss)):

| Layer | Where | Can a box user switch it off? | What it captures |
|---|---|---|---|
| Bedrock invocation logging | `s3://<bucket>/bedrock-logs/` | No (server-side) | Every model request and response with the caller's identity - including the commands Claude chose to run and their output, since both travel in the conversation. |
| Session recordings | `s3://<bucket>/session-logs/` and CloudWatch Logs `/claude-scan/<shared-stack>/sessions` (live) | Partly - streamed output already sent is kept, and bucket versioning keeps the original if a recording is overwritten | Everything shown in the terminal. |
| VPC flow logs | CloudWatch Logs `/claude-scan/<network-stack>/vpc-flow-logs` (kit-created VPC only, 90 days) | No | Every connection in and out of the VPC, including outbound internet traffic. |
| Claude Code telemetry | `s3://<bucket>/claude-code/<owner>/{metrics,logs,traces}/` | Yes, as root - for example by changing Claude Code's settings, which no alarm detects | Sessions, tokens, cost, prompts, responses, tool calls, commands and tool output. |
| Telemetry heartbeat alarm | CloudWatch alarm `claude-scan-<owner>-telemetry-silent` → SNS email | Stopping the collector triggers it | The collector stopped while the box was running. It doesn't fire if Claude Code stops sending telemetry while the collector keeps running. |
| Telemetry delivery alarm | CloudWatch alarm `claude-scan-<owner>-telemetry-undelivered` → SNS email | It fires when telemetry stops leaving the box | For 15 minutes, telemetry has been piling up on the box instead of reaching the bucket, for example after a bucket, KMS key or S3 endpoint policy change. The box keeps it (up to 10,000 export requests, about half a day of continuous use) and sends it once writes work again. |
| S3 access logs | The shared stack's **Outputs** → `AccessLogsBucket` (when the stack creates the bucket) | No | Every request to the telemetry bucket, including which admin read which prompts or recordings. |
| CloudTrail | Your account or organization trail | No | AWS API calls by identity. |

Telemetry objects are gzipped OTLP JSON, partitioned `year=/month=/day=/hour=`, and arrive within about
a minute. Only the principals in `AdminPrincipalArnPatterns` can read the bucket the kit creates. When the
stack creates the bucket, the bucket and the live session recordings in CloudWatch Logs both use the kit's KMS key.

#### What each layer can miss

- **Claude Code telemetry** comes from the box. With root, a user can change Claude Code's settings or call
  Bedrock with another client while the collector keeps running, so neither telemetry alarm fires.
- **Bedrock invocation logging** is the server-side record of every model call and the caller's identity,
  from any client. It doesn't show what users type or run in the terminal themselves.
- **Session recordings** cover Session Manager sessions only, and show what the terminal displays, not what
  runs in the background.
- **VPC flow logs** show IP addresses and ports, not domain names or content.

To catch telemetry that was turned off, compare Bedrock invocation logs with each box's Claude Code
telemetry (see [Hardening for production](docs/hardening-for-production.md#detection-and-response)).

### Security model

- **Isolated:** no inbound access (boxes share one security group with no inbound rules, so they can't
  reach each other either), Session Manager only, IMDSv2, encrypted disk; each box's role can write only its
  own telemetry prefix and session recordings; users can start sessions only to their own box. In a VPC the
  kit builds, endpoint policies limit S3 to the kit's buckets and the other endpoints to this account's principals.
- **Not isolated:** boxes have outbound internet access through the NAT (needed for Git, package installs
  and updates), so data can leave over HTTPS. VPC flow logs record those connections; for tighter control,
  add egress filtering (see [Hardening for production](docs/hardening-for-production.md#network-egress)).
- **Telemetry stays in your account:** Claude Code telemetry, including prompts, responses and tool content, goes
  only to the kit's S3 bucket, readable only by `AdminPrincipalArnPatterns`. The kit sends it to no external
  collector or service.
- **Root on the box:** users can change anything on their own box, including telemetry. Detection, not
  prevention, covers that, and only partly (see [What each layer can miss](#what-each-layer-can-miss)).
- **Optional organization guardrails:** `policies/` has two SCPs and an RCP that lock the account down
  further (below).

#### Hardening for production

Before you use this sample in production, see [Hardening for production](docs/hardening-for-production.md):
egress filtering, endpoint and model restrictions, an off-account copy of the audit data, detection and
response, and a golden image.

### Optional: organization guardrails (SCPs and RCP)

Apply these from your AWS Organizations **management account** after the shared stack exists. Test on a
non-production account first: SCPs apply to every principal in the account except the exempted admins.

| File | Type | What it does |
|---|---|---|
| `scp-scan-guardrails.json` | SCP | Everyone except admins: no IAM changes, no provisioning or new network paths (IGW, NAT, peering, VPN, endpoints, routes, resource sharing), no tampering with logs, CloudTrail, Config, GuardDuty or Security Hub, no S3 deletes; nobody can leave the organization. |
| `scp-scan-agent-perimeter.json` | SCP | Box roles can do only what a box needs; box roles write only to the telemetry prefixes and read only the kit scripts; only Claude models; Bedrock calls only through the VPC endpoint. |
| `rcp-scan-data-perimeter.json` | RCP | The account's S3, KMS, SQS, Secrets Manager and role assumption are closed to principals outside your organization; TLS required. |

**Console:** AWS Organizations → Policies → Service control policies (or Resource control policies) →
Create policy → paste the file → replace the placeholders → Create → Targets → attach to the scanning account.

| Placeholder | Replace with |
|---|---|
| `"__PLATFORM_PRINCIPALS__"` (including the quotes) | A JSON list of admin role ARN patterns in the account, for example `["arn:aws:iam::<acct>:role/aws-reserved/sso.amazonaws.com/*AWSReservedSSO_AWSAdministratorAccess_*", "arn:aws:iam::<acct>:role/AWSControlTowerExecution", "arn:aws:iam::<acct>:role/aws-controltower-*", "arn:aws:iam::<acct>:role/stacksets-exec-*", "arn:aws:iam::<acct>:role/OrganizationAccountAccessRole", "arn:aws:iam::<acct>:role/claude-scan-platform-*"]` |
| `__BOX_ROLES__` | `arn:aws:iam::<acct>:role/claude-code-box-*` |
| `__TELEMETRY_BUCKET__` | Shared stack Outputs → `TelemetryBucket` |
| `__ARTIFACT_BUCKET__`, `__ARTIFACT_PREFIX__` | Shared stack Outputs → `ArtifactBucket`, `ArtifactPrefix` |
| `__VPCE_ID__` | Shared stack Outputs → `BedrockVpceId`. If it's `none`, delete the `DenyBedrockOutsideVpce` statement. |
| `__ORG_ID__` | AWS Organizations console → your organization ID (`o-...`) |

**Command line:** `SCAN_PROFILE=<profile> policies/render.sh` fills the placeholders from the shared
stack, validates each policy with IAM Access Analyzer, and prints the commands to create and attach them.

Effects to expect once attached: only admins can deploy or delete stacks; Bedrock calls from outside the
VPC endpoint (for example Claude Code on a user's laptop, using the same identity) are denied.

## Operations

Running the sample: costs, updates, clean up and troubleshooting.

### Costs

Approximate, us-west-2, before Bedrock usage (which is usually the largest cost):

| Item | Approx. monthly |
|---|---|
| NAT gateway (shared) | ~$33 + $0.045/GB processed |
| 7 interface VPC endpoints (shared, `InterfaceEndpoints = auto` with a new VPC) | ~$51 |
| 2 KMS keys (shared: telemetry, alarm notifications) | ~$2 + requests |
| Each box, `t3.xlarge` running 24×7 | ~$120 (much less with idle stop) |
| Each box, 100 GiB gp3 disk | ~$8 |
| VPC flow logs (shared) | ~$0.50/GB ingested into CloudWatch Logs |
| S3, CloudWatch Logs, alarms | usually a few dollars |

### Updating

- **Update the kit:** re-upload changed files to the same S3 location. New boxes use them. To refresh a
  running box's helper: `sudo aws s3 cp s3://<bucket>/claude-scan-kit/scripts/scan-harness.sh /usr/local/bin/`.
- **Check a box's kit version:** it's in the login banner and in `/etc/claude-scan/kit-version` on the box
  (`dev` when the files were uploaded from a git clone instead of a downloaded zip).
- **Add a toolchain or the harness to a running box** without rebuilding it: on the box, run
  `sudo claude-scan-bootstrap --only toolchain-rust` (or `toolchain-java`, `toolchain-node`, ..., `harness`,
  `sandbox`). It reruns that setup module.
- **Change sign-in or model settings** (shared stack): new boxes use them. On a running box, run
  `sudo claude-scan-bootstrap --only aws-profile managed-settings banner` to pick them up without a rebuild.
- **Upgrading boxes from a kit without shared sign-in settings:** update the shared stack first (fill in
  `AuthMode` and, for Identity Center, the start URL and region your boxes used), then update each box stack
  with the new `box.yaml`. That replaces the instance (see the next point). IAM users also need the group and
  `Owner` tag (see [IAM users](#iam-users)).
- **Rebuild a box:** update its stack with any changed parameter; the instance is replaced. **Files in the
  user's home directory, including `~/scan-results`, are lost** - copy anything worth keeping first.
- The shared stack's exported values can't change while box stacks use them. To move boxes to a different VPC
  or bucket, delete the boxes first.

### Clean up

- **Remove a user:** delete their `claude-scan-box-<owner>` stack, and remove their permission set assignment
  or group membership. Their telemetry and recordings stay in the bucket.
- **Remove everything:**
  1. Delete every `claude-scan-box-<owner>` stack. The shared stack can't be deleted while box stacks use its exports.
  2. Delete the shared stack. This also removes the Session Manager preferences and turns off Bedrock invocation
     logging in the account and region, if the stack configured them.
  3. The stack **keeps** the audit data on purpose: the telemetry bucket, the access-log bucket, the telemetry KMS
     key and the session recordings log group (`/claude-scan/<shared-stack>/sessions`). When you no longer need the
     data, empty and delete both buckets (they're versioned, so delete all object versions), delete the log group,
     and schedule the KMS key for deletion (7 to 30 days).
  4. To re-create the shared stack under the same name and keep using the recordings log group, set
     `ExistingSessionLogGroupName` instead of deleting it.

### Troubleshooting

Start with the doctor commands; they run the checks below and say what to fix:

- **On a box:** `claude-scan-doctor` (setup, sign-in, a one-token Bedrock call, telemetry delivery, Session Manager
  agent, internet access).
- **As an admin (CloudShell or a terminal):** `./deploy.sh doctor <owner>` (stack status and errors, the newest setup
  failure report, the instance's security groups and `Owner` tag, Session Manager registration, what the Session
  Manager endpoints' security groups allow, and the box's alarms). Read-only.

| Symptom | Fix |
|---|---|
| Shared stack: nested stack fails with S3 access denied | The kit bucket/prefix is wrong, in a different region, or you can't read it. Check the `infra/` URLs exist. |
| Shared stack: `SessionManagerPreferences` already exists | Session Manager preferences were saved before in this region. Set `ConfigureSessionManager = No`, or remove them and retry. |
| Shared stack: `BedrockInvocationLogging` fails | `already configured in this account and Region`: keep that logging and set `ConfigureBedrockLogging = No`. Otherwise, with your own bucket, add the bucket and key policy statements in [Using your own bucket](#using-your-own-bucket). |
| Box stack: `Received FAILURE signal with UniqueId i-...` | A setup step on the box failed. CloudFormation can't show which, so the box records it in two places that survive the rollback: **CloudWatch Logs** → log group `/claude-scan/<shared-stack>/heartbeat` → the newest `bootstrap-failure-<time>-<instance-id>` stream, and the instance's **system log** (EC2 console → the terminated instance → Actions → Monitor and troubleshoot → Get system log; search for `FAILED`). The first line names the setup module, line and command, e.g. `module toolchain-go: exit 1 at toolchain-go.sh line 3: dnf install -y golang`, followed by the last 200 lines of setup output. In the system log, `=== claude-scan module <name>: start / ok / FAILED` lines show how far setup got. Common causes: no outbound internet from the subnet, a wrong kit bucket or prefix, `scripts/modules/` not uploaded, or a misspelled `ExtraPackages` name. |
| Box stack fails with `preflight: N check(s) failed - ...` | Before installing anything, the box checks that it can reach and use what setup needs: the Amazon Linux package repositories, the telemetry bucket (write, and its encryption setting if Session Manager recording is on), CloudWatch Logs, the Session Manager, Bedrock and CloudFormation endpoints, and the internet hosts its modules download from. The message lists each failed check with what to fix, for example `HTTP 403 from the Amazon Linux repositories - the VPC's S3 gateway endpoint policy must allow s3:GetObject on arn:aws:s3:::al2023-repos-<region>-de612dc2/*`, or `no connection - ... their security group must allow HTTPS (443) from <subnet CIDR>`. The full PASS/FAIL list is in the same `bootstrap-failure-...` stream. |
| Box stack fails with `module verify: the SSM agent didn't connect to Session Manager within 3 minutes` | The preflight reached the Session Manager endpoints, but the agent couldn't register or open its connection, so nobody could have connected. Usually an SCP, or an `ssm`/`ssmmessages`/`ec2messages` VPC endpoint policy, denies the box role. The message ends with the agent's last error. |
| Alarm `claude-scan-<owner>-telemetry-undelivered` | The box can't write telemetry to the bucket. Check what changed in the bucket policy, its KMS key policy and the S3 gateway endpoint policy; the preflight's `telemetry-bucket` check shows the same error (`sudo claude-scan-bootstrap --only preflight` on the box). Queued telemetry is delivered once writes work again, and the alarm clears. |
| Setup log shows `WARNING: this box stack's box.yaml is from kit X but the scripts in the kit bucket are from kit Y` | The template used for the box stack and the files in the kit bucket come from different kit versions. Upload the whole kit from one zip, and update the box stack with that zip's `box.yaml`. |
| Box stack times out waiting for the signal | The box never got far enough to report. Redeploy with **Stack failure options → Preserve successfully provisioned resources**, connect, and read `/var/log/claude-scan-bootstrap.log` (each module's result and time are in `/var/log/claude-scan-modules.log`). |
| Can't start a session (`runAs user claude does not exist`) | The instance isn't a kit box; the run-as setting is account-wide. |
| Can't start a session (`TargetNotConnected`), even as an admin | The box's SSM agent isn't connected. Run `./deploy.sh doctor <owner>`: if the box isn't registered and the VPC has `ssm`, `ssmmessages` or `ec2messages` endpoints, their security group must allow HTTPS from the box subnet or the kit's box security group. After fixing, reboot the box so the agent retries at once. |
| `SessionManagerPlugin is not found` | Install the [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html) on the computer you connect from. The EC2 console's **Connect** and CloudShell don't need it. |
| Can't start a session (access denied) | The user's `Owner` (Identity Center attribute, or IAM user tag) must equal the box's `Owner`, and sessions pick up attributes only when they start: sign out and in again. IamUser: also check the user is in the shared stack's group and signed in on their own computer. |
| Claude Code: Bedrock `AccessDenied` | Sign in again (banner step 1); check model access and the use-case form; check the shared stack's `ClaudeModel` uses your region's prefix; with the agent SCP, calls must come from the box. |
| `AccessDenied` reading or writing another S3 bucket from a box | In a VPC the kit builds, the S3 gateway endpoint allows only the kit and telemetry buckets and the AWS-owned buckets boxes need. Add a statement to `S3GatewayEndpoint` in `infra/storage.yaml` (see [Hardening for production](docs/hardening-for-production.md#endpoints-and-models)). |
| `aws login` fails on the box | The IAM user needs the `signin` permissions from the shared stack's group; a permissions boundary may block them. |
| Alarm email says telemetry is silent | Connect and check `sudo systemctl status otelcol-contrib`; if it was stopped deliberately, review the session recordings and Bedrock logs. |
| Two shared stacks in one account and region (e.g. testing) | Only one can own the account-wide settings: set `ConfigureSessionManager = No` and `ConfigureBedrockLogging = No` on the second. Its boxes' sessions are then recorded to the first stack's bucket and log group, which their roles can't write, so sessions to them may be refused. |

## About the harness

With `InstallHarness = true`, each box clones Anthropic's open source
[defending-code reference harness](https://github.com/anthropics/defending-code-reference-harness) (Apache-2.0)
into the `claude` user's home directory at first boot, at the commit this kit was tested with. See its README
for what it does and how to use it. Its README also notes that it isn't maintained upstream. The kit doesn't
depend on it, so you can use any other harness instead.

**Headless scans** (`scan-harness.sh scan <git-url|dir>`) run without anyone approving each step, and the
repository under scan can steer the agent. So each scan runs on a fresh copy of the repository and the
harness, as a separate `claude-scanner` user:

- No `sudo`, and no access to your home directory or your AWS sign-in.
- Only a short-term Bedrock API key, minted from your sign-in when the scan starts.
- Firewall rules that allow only the VPC's endpoints: no internet and no instance metadata. Headless scans
  therefore need the `bedrock-runtime` and `bedrock` interface endpoints (`InterfaceEndpoints`).

Results go to `~/scan-results/<host>/<org>/<repo>/<time>/`, with `SCAN-INFO.json` (the repository, commit,
harness commit, model and status). A scan fails, instead of reporting old results, when a step doesn't
produce a complete report. In interactive use (`claude` in the harness directory), Claude Code runs as you,
with your permissions and sign-in, so review what it asks to run.

## Third-party software

This repository doesn't include third-party software. Boxes download the following at setup, each under its own
license or terms, which you accept by deploying:

| Software | Source | License or terms |
|---|---|---|
| Claude Code | Anthropic's installer (`claude.ai/install.sh`) | Anthropic's terms for Claude Code |
| defending-code reference harness | `github.com/anthropics/defending-code-reference-harness` | Apache-2.0 |
| OpenTelemetry Collector Contrib | GitHub releases of `open-telemetry/opentelemetry-collector-releases` | Apache-2.0 |
| TypeScript, tsx, pnpm, yarn (node toolchain) | npm registry | Their respective open source licenses |
| uv (python toolchain) | PyPI | Their respective open source licenses |
| Toolchains and other packages | Amazon Linux 2023 repositories | Their respective licenses |

Claude models on Amazon Bedrock are provided under Anthropic's terms, which you accept when you enable model
access in the Bedrock console.

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

## License

This library is licensed under the MIT-0 License. See the [LICENSE](LICENSE) file.
