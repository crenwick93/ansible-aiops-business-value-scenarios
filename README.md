# AIOps Business Value Scenarios

A push-button demo showing how **Ansible Automation Platform (AAP)**,
**Event-Driven Ansible (EDA)**, and **Ansible Lightspeed Intelligent Assist
(ALIA)** combine into an AIOps pattern for automated incident diagnosis and
remediation.

## The scenario

A UK passport online application service silently fails: a configuration
change causes one category of payment messages to be routed to a dead-letter
queue instead of the main processing topic.  Health checks stay green.
Monitoring sees nothing wrong.  But citizens start calling the contact centre
because their paid applications aren't progressing.

A call-centre agent raises a ServiceNow incident.  From there, the AIOps
pipeline takes over:

1. **EDA** picks up the incident and triggers a diagnostic workflow
2. The **orchestrator playbook** walks the ServiceNow CMDB graph, dispatching
   diagnostic roles to each component CI
3. The aggregated diagnostic evidence is sent to **ALIA**
4. ALIA identifies the root cause and recommends a parameterised remediation
5. An engineer reviews the recommendation and approves the replay job
6. The **remediation playbook** replays the held messages, clearing the backlog

## Prerequisites

| Tool              | Version  | Purpose                        |
|-------------------|----------|--------------------------------|
| Terraform         | >= 1.5   | AWS infrastructure provisioning|
| Ansible           | >= 2.16  | Playbooks and diagnostic roles |
| ansible-rulebook  | >= 1.0   | Event-Driven Ansible           |
| Python            | >= 3.11  | Services, scripts, traffic gen |
| jq                | any      | JSON parsing in Makefile       |
| AWS account       | —        | EC2, VPC, SGs                  |
| ServiceNow PDI    | —        | CMDB and incident management   |

## Quickstart

```bash
# 1. Clone and configure
git clone <this-repo>
cd ansible-aiops-business-value-scenarios
cp .env.example .env

# 2. Create an EC2 key pair in your target region (eu-west-1)
#    Go to AWS Console → EC2 → Key Pairs → Create key pair
#    Download the .pem file and note the key pair name
chmod 600 ~/path/to/your-key.pem

# 3. Edit .env with your credentials
#    - AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
#    - SSH_KEY_NAME        (the key pair name from step 2)
#    - SSH_PRIVATE_KEY_PATH (local path to the .pem file)
#    - SERVICENOW_INSTANCE_URL / USERNAME / PASSWORD
#    - DEMO_DOMAIN         (your Route53 domain, or leave blank)

# 4. Verify prerequisites
make check

# 5. Provision infrastructure (~5 minutes)
make up

# 6. Seed the ServiceNow CMDB
make seed-cmdb

# 7. Run the full demo
make demo-full
```

## Makefile targets

| Target            | Description                                              |
|-------------------|----------------------------------------------------------|
| `make help`       | List all targets                                         |
| `make check`      | Verify prerequisites and .env configuration              |
| `make up`         | Provision AWS infrastructure, wait for healthy services   |
| `make seed-cmdb`  | Create business service and CIs in ServiceNow CMDB       |
| `make seed-traffic`| Start background traffic generator                      |
| `make demo-break` | Introduce the misrouting failure                         |
| `make demo-incident`| Create a ServiceNow incident manually                  |
| `make demo-diagnose`| Run the diagnostic orchestrator                        |
| `make demo-fix`   | Replay held messages (remediation)                       |
| `make demo-full`  | Run the entire demo sequence end-to-end                  |
| `make reset`      | Restore to pre-break state                               |
| `make teardown-cmdb`| Remove demo CIs from ServiceNow                       |
| `make down`       | Destroy AWS infrastructure                               |
| `make nuke`       | Full cleanup (CMDB + infrastructure)                     |

## AAP Configuration

This project provides the playbooks, roles, and rulebooks.  You configure AAP:

**Credentials needed in AAP:**
- Machine credential for SSH access to EC2 instances
- ServiceNow credential (instance URL, username, password)

**Projects (one per org, all pointing to this repo):**
- Service Reliability: `AIOps Business Value Scenarios`
- Application Services: `Application Automation`
- Middleware Services: `Middleware Automation`
- Database Services: `Database Automation`

**Job Templates (Service Reliability):**
- `CMDB Lookup` — runs `playbooks/service_reliability/cmdb_lookup.yml`
- `ALIA Enrichment` — runs `playbooks/service_reliability/alia_enrichment.yml`
- `Replay Held Messages` — runs `playbooks/service_reliability/replay_held_messages.yml`
- `Rollback Service Configuration` — runs `playbooks/service_reliability/rollback_service_config.yml`

**Workflow (Service Reliability — cross-org orchestration):**
- CMDB Lookup → fan out to Application Services' "Check Application Health"
  + Middleware Services' "Check Consumer Lag" → converge on ALIA Enrichment

**EDA Controller (Service Reliability):**
- Import `rulebooks/service_reliability/servicenow_incident_rulebook.yml`
- Configure the webhook source or ServiceNow event source
- Map the action to the `Incident Diagnostics Workflow`

**Inventory:**
- Use the `inventory/aws_ec2.yml` dynamic inventory
- Ensure `boto3` is installed in the execution environment

## Project structure

See [ARCHITECTURE.md](ARCHITECTURE.md) for detailed component descriptions.
See [DEMO.md](DEMO.md) for the presenter runbook.
See [docs/troubleshooting.md](docs/troubleshooting.md) for common issues.

## Cleanup

```bash
make nuke    # tears down CMDB entries and destroys all AWS infrastructure
```
