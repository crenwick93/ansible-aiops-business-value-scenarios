# AIOps Demo — Walk-through Instructions

## URLs and Credentials

| Service | URL |
|---------|-----|
| AAP | https://aap.sandbox2797.opentlc.com |
| ServiceNow | https://dev355616.service-now.com |
| Citizen Portal | http://dashboard.sandbox2797.opentlc.com:8080 |
| Engineering Dashboard | http://dashboard.sandbox2797.opentlc.com:8080/engineering |
| Kafdrop (Kafka UI) | http://dashboard.sandbox2797.opentlc.com:9000 |

| AAP User | Org |
|----------|-----|
| app_admin | Application Services |
| middleware_admin | Middleware Services |
| sre_admin | Service Reliability |

> Password for all org admins is set via `AAP_ORG_ADMIN_PASSWORD` in `.env`

---

## 1. Show the Automation Catalog (2 orgs)

**Goal:** Set the scene — this is a mature AAP customer with automation broken into team-owned orgs.

1. Log into AAP as `app_admin`
2. Show **Templates** — these are the Application Services team's automation:
   - Deploy Application
   - Diagnose Application
   - Restart Application Service
   - Rollback Payment Service Config
3. Log out, log in as `middleware_admin`
4. Show **Templates** — Middleware Services own Kafka operations:
   - Patch Kafka Brokers
   - Diagnose Message Queue
   - Rotate Kafka Credentials
   - Rebalance Partitions
   - Replay Held Messages

> **Talking point:** Each team owns and maintains their own automation. No single team has access to everything.

---

## 2. Show EDA and the Workflow (SRE view)

1. Log into AAP as `sre_admin`
2. Navigate to **Event-Driven Ansible > Rulebook Activations**
3. Show **ServiceNow Incident Monitor** is running — polling ServiceNow for new incidents
4. Navigate to **Automation Controller > Templates**
5. Open **Incident Diagnostics Workflow** — show the visualiser:
   - CMDB Lookup fans out to 4 parallel diagnostics
   - Automation Catalog collects available templates
   - AI Router analyses everything and suggests a fix
   - Update SNOW Incident posts results back

> **Talking point:** The SRE team owns the cross-cutting orchestration. They don't need to know the details of each domain — the workflow delegates to each team's diagnostics.

---

## 3. Show the Citizen Portal — Working vs Stuck

**Goal:** Show a citizen who paid and is progressing, vs one who paid but is stuck.

1. Open the **Citizen Portal** in a browser
2. Look up a **priority** application reference — it will show status progressing through the stages normally
3. Look up a **standard adult** application reference — it will be stuck at "Payment Received" and not progressing

> To find real references, check the database or Kafdrop. Standard adult applications (`fee.standard.adult`) are the ones being misrouted to the DLQ, so they never reach processing. Priority and child applications work fine.

---

## 4. Show the Engineering Dashboard — No Obvious Issues

1. Open the **Engineering Dashboard**: `http://dashboard.sandbox2797.opentlc.com:8080/engineering`
2. Point out: services show healthy, no alerts firing, throughput looks normal
3. This is the subtle nature of the bug — it doesn't trigger traditional monitoring

> **Talking point:** This is why AIOps matters. The system looks healthy from a platform perspective, but citizens are suffering. Traditional monitoring misses this class of partial failure.

---

## 5. Create the Incident Manually in ServiceNow

1. Open ServiceNow: `https://dev355616.service-now.com`
2. Navigate to **Incident > Create New**
3. Fill in:

| Field | Value |
|-------|-------|
| **Caller** | Chris Renwick |
| **Category** | Software |
| **Impact** | 2 - Medium |
| **Urgency** | 1 - High |
| **Assignment group** | Service Reliability |
| **Business service** | Passport online application service |
| **Short description** | Passport applications stuck at payment stage - citizens waiting 14+ days |

4. Paste this into the **Description** field:

```
Call centre receiving increasing complaints from citizens whose standard adult
passport applications are stuck at "Payment Received - Awaiting Processing".
Citizens have been charged but applications are not progressing to the processing stage.

Affected references reported by citizens:
- CIT-SMITH01 — submitted 21 April, last updated 23 April, stuck 14 days
- CIT-JONES02 — submitted 22 April, stuck 13 days
- CIT-BROWN03 — submitted 24 April, stuck 11 days

Citizen-facing status page shows red warning: "Your payment was received
but your application has not yet progressed."
```

5. Click **Submit**

---

## 6. Watch the Workflow Execute

1. Switch to AAP (logged in as `sre_admin`)
2. Navigate to **Jobs** — the workflow should appear within ~30 seconds
3. Click into it and watch the visualiser:
   - CMDB Lookup resolves all components from the service graph
   - 4 diagnostics fan out in parallel (app, kafka, storage, database)
   - Automation Catalog collects available templates
   - AI Router runs (takes ~30s — two ALIA calls)
   - Update SNOW Incident posts everything back

---

## 7. Show the ServiceNow Results

Once the workflow completes (final node turns green):

1. Switch to the **ServiceNow incident**
2. Scroll to **Work Notes** — show the AI analysis:
   - **Root Cause** — payment-svc is misrouting `fee.standard.adult` to the DLQ
   - **Evidence** — specific log lines and metrics cited
   - **Remediation** — step-by-step fix instructions
   - **Assignment** — reassigned to Application Services
   - **Suggested Remediation** — "Rollback Payment Service Config" Ansible Job Template with reason
3. Show the **Assignment group** has changed from "Service Reliability" to "Application Services"

> **Talking point:** The ticket went from "new" to "in progress" with a full root cause analysis, evidence, remediation steps, and team assignment — all automated. No ticket ping-pong.

---

## 8. Be the Application Team — Verify the Issue

Now pretend you're the app team who just received this ticket.

1. SSH to payment-svc:
   ```
   ssh ec2-user@payment-svc.sandbox2797.opentlc.com
   ```

2. Check the logs — you'll see standard adult payments going to the DLQ:
   ```
   sudo journalctl -u payment-svc -f
   ```

3. Look at the config file — you'll see the incorrect routing:
   ```
   vi /opt/payment-svc/config.py
   ```
   Line 2 shows `"fee.standard.adult": "payments.dlq"` — that's the bug.
   Exit vi with `:q`

---

## 9. Run the Remediation

1. Log into AAP as `app_admin`
2. Navigate to **Templates > Rollback Payment Service Config**
3. Click **Launch**
4. The template will:
   - Fetch the correct config from Git
   - Detect the drift
   - Back up the broken config
   - Restore the correct config
   - Restart payment-svc
   - Verify health

---

## 10. Verify the Fix

1. SSH back to payment-svc and follow the logs:
   ```
   sudo journalctl -u payment-svc -f
   ```
   You'll see `fee.standard.adult` now going to the `payments` topic (not DLQ).

2. Copy a `CIT-XXXXXX` reference from the log output (pick one with `fee.standard.adult`)

3. Open the **Citizen Portal** and paste the reference into the lookup field — it should now show the application progressing past "Payment Received" into the processing stages

> **Talking point:** A standard adult passport application is now flowing through correctly — the config drift has been resolved by running a single Ansible Job Template.

---

## 11. Close the Incident

1. Switch back to **ServiceNow**
2. Open the incident
3. Change **State** to **Resolved**
4. Add a **Close note**:
   ```
   Root cause identified by automated diagnostics — payment-svc config drift was routing
   fee.standard.adult to DLQ. Resolved by running Rollback Payment Service Config job template.
   Standard adult applications now processing normally.
   ```
5. Click **Update**

---

## Resetting the Demo

To re-break the environment and run the demo again:

1. SSH to payment-svc and re-introduce the misrouting:
   ```
   ssh ec2-user@payment-svc.sandbox2797.opentlc.com
   sudo vi /opt/payment-svc/config.py
   ```
   Change `"fee.standard.adult": "payments"` to `"fee.standard.adult": "payments.dlq"`, save and quit (`:wq`)

2. Restart the service:
   ```
   sudo systemctl restart payment-svc
   ```

3. Verify it's broken — check the logs show standard adult going to the DLQ:
   ```
   sudo journalctl -u payment-svc -f | grep fee.standard.adult
   ```

Alternatively, run the break playbook from your local machine:
```
ansible-playbook playbooks/_demo/break/introduce_misrouting.yml -i inventory/aws_ec2.yml
```

The environment is now ready for another demo run — start again from Step 5.
