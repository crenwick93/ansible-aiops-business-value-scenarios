# Demo Runbook

Step-by-step guide for presenters.  Follow this sequence for a smooth demo.

## Pre-flight checklist (morning of the demo)

- [ ] `.env` is populated with valid credentials
- [ ] `make check` passes
- [ ] AWS credentials are active and have EC2/VPC permissions
- [ ] ServiceNow PDI is awake (PDIs sleep after inactivity — log in to wake it)
- [ ] You can SSH to a test EC2 instance (verify key pair works)
- [ ] AAP is configured with the required job templates (if using AAP)
- [ ] Your laptop can reach the ServiceNow instance and AWS region

## Infrastructure setup (~5 minutes)

```bash
make up
```

This provisions 4 EC2 instances (Kafka, PostgreSQL, payment-svc, app-svc) and
waits for health checks.  While it runs, explain the architecture to the
audience using the diagram in ARCHITECTURE.md.

**Expected output:** Terraform apply completes, health checks pass for both
services.

## CMDB setup (~1 minute)

```bash
make seed-cmdb
```

Creates the business service and 4 component CIs in ServiceNow with typed
relationships.  Show the audience the CMDB map in ServiceNow after this
completes.

**Expected output:** 5 CIs created, 7 relationships created, sys_ids printed.

## Start traffic (~30 seconds)

```bash
make seed-traffic
```

Starts the traffic generator in the background.  It sends ~1 payment request
per second with a realistic mix of fee types.  Show `tail -f traffic.log` to
the audience briefly.

**Expected output:** Traffic flowing, applications being processed normally.

---

## Act 1: Everything is fine (1 minute)

Open two browser tabs:
- **Citizen portal:** `http://<dashboard-ip>:8080/` — try looking up `CZ-00042`
- **Engineering dashboard:** `http://<dashboard-ip>:8080/engineering`

**Presenter talking points:**
- "This is a passport application service processing citizen payments"
- Switch to the **engineering dashboard**: "From the platform team's perspective,
  everything is green. Services are healthy, traffic is flowing, no alerts"
- Switch to the **citizen portal**: "Citizens can check their application status.
  Let's look one up — it's progressing normally"

```bash
# Dashboard IP from Terraform outputs:
terraform -chdir=infra/terraform output dashboard_urls
```

---

## Act 2: Introduce the failure (1 minute)

```bash
make demo-break
```

**Presenter talking points:**
- "A config change was deployed — maybe a well-meaning PR, maybe a typo"
- "Standard adult passport fee payments are now silently going to the DLQ"
- "Health checks are still green. Monitoring sees nothing. The service is 'healthy'"
- Let traffic flow for 60 seconds to build up DLQ messages

**Expected output:** Config modified, service restarted, still returns 200 on
/health.

---

## Act 3: The human signal (2 minutes)

**Presenter talking points:**
- "Days pass.  Citizens who paid for standard adult passports call the contact centre"
- Switch to the **citizen portal**: look up an application with `fee.standard.adult`.
  It's stuck on "Payment Received - Awaiting Processing" with a warning message
- Switch to the **engineering dashboard**: "But look — everything is still green.
  The platform team has no idea this is happening"
- "A call-centre agent notices the pattern and raises a ServiceNow incident"
- "This is the signal that monitoring couldn't provide"

```bash
make demo-incident
```

Show the incident in ServiceNow.  Point out that the business service field
links to the CMDB graph.

**Expected output:** Incident created, number printed (e.g. INC0010042).

---

## Act 4: Automated diagnostics (2 minutes)

```bash
make demo-diagnose
```

**Presenter talking points:**
- "EDA picks up the incident and triggers the diagnostic orchestrator"
  (in the live demo via `ansible-rulebook`; here we run it directly)
- "The orchestrator walks the CMDB graph — it finds 4 components"
- "For each component, it runs the matching diagnostic role"
- "The Kafka role spots 300+ messages in the DLQ, all with the same routing key"
- "The application role reads config.py and sees the misrouting"
- "The database role sees growing stuck applications"
- "All evidence is bundled and sent to ALIA"

**Expected output:** Diagnostic payloads collected, ALIA response displayed,
work note posted to the ServiceNow incident.

Show the work note in ServiceNow — the audience sees the AI's analysis and
recommendation.

---

## Act 5: Approved remediation (1 minute)

**Presenter talking points:**
- "ALIA recommends: run 'replay_held_messages' with these parameters"
- "An engineer reviews the recommendation — this is suggestion, not automation"
- "The engineer approves, and the remediation runs"
- "Note: the playbook is GENERIC.  It replays messages from any queue.
  ALIA's contribution is the parameters, not the playbook itself"

```bash
make demo-fix
```

**Expected output:** Messages replayed from DLQ to main topic, applications
start processing again.

---

## Act 6: Resolution (1 minute)

**Presenter talking points:**
- "The held messages are replayed, citizens' applications start progressing"
- "The root cause (config.py misrouting) should also be fixed — that's a
  separate change management process"
- "The entire diagnostic-to-remediation loop took minutes, not days"

---

## Cleanup

```bash
make reset     # restore config, clear DLQ (if demoing again)
make nuke      # full teardown when done for the day
```

## Timing summary

| Step              | Duration    | Cumulative |
|-------------------|-------------|------------|
| Infrastructure    | ~5 min      | 5 min      |
| CMDB setup        | ~1 min      | 6 min      |
| Start traffic     | ~30 sec     | 6.5 min    |
| Act 1: Happy path | ~1 min      | 7.5 min    |
| Act 2: Break      | ~1 min      | 8.5 min    |
| Accumulate DLQ    | ~1 min wait | 9.5 min    |
| Act 3: Incident   | ~2 min      | 11.5 min   |
| Act 4: Diagnose   | ~2 min      | 13.5 min   |
| Act 5: Fix        | ~1 min      | 14.5 min   |
| Act 6: Wrap-up    | ~1 min      | 15.5 min   |
| **Total**         |             | **~16 min**|

Allow 20 minutes with Q&A buffer.
