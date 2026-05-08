# AIOps Business Value Demo — Presenter Guide

## The Point

This demo shows how Ansible Automation Platform (AAP) with Event-Driven Ansible (EDA) and Ansible Lightspeed Intelligent Assist (ALIA) can **dramatically reduce Mean Time To Resolution (MTTR)** for complex, cross-team incidents.

The scenario is deliberately subtle — a partial failure that doesn't trigger traditional monitoring. Services are up, health checks pass, but citizens are stuck. In the real world, this kind of issue bounces between teams for days. Here, it's diagnosed in under 60 seconds.

---

## The Scenario

**UK Passport Online Application Service** — citizens submit passport applications and pay fees. Standard adult applications are stuck at "Payment Received" and never progress. Premium and child applications work fine.

**Root cause:** A routing misconfiguration in the payment service sends `fee.standard.adult` payments to a dead letter queue instead of the main processing topic. Services are healthy. No alerts fire. Citizens just wait.

**Why this is hard without automation:**
- No single team owns the full picture
- Health checks all pass (it's not an outage)
- The symptom (stuck applications) is in a different system than the cause (routing config)
- Traditional debugging means ticket ping-pong between app team, middleware team, and storage team

---

## The Flow

### 1. Incident Created (ServiceNow)
A call centre agent raises an incident: "Passport applications stuck at payment stage."

**Business value:** This is the trigger. In the old world, this ticket sits in a queue for hours before anyone looks at it.

### 2. Event-Driven Ansible Detects It
The EDA rulebook polls ServiceNow for new incidents (state=1). Within 10 seconds of the incident being created, EDA triggers the workflow automatically.

**Business value:** Zero human latency. No waiting for someone to pick up the ticket, read it, decide who to assign it to.

### 3. CMDB Lookup (Service Reliability Team)
The workflow's first step queries the ServiceNow CMDB to resolve the service graph:
- "Passport online application service" depends on: `payment-svc`, `kafka-payment-queue`, `app-svc`, `postgres-app-db`

It then derives **operational parameters** from the CMDB — topic names, service URLs, storage hosts — and passes them to the diagnostic steps.

**Business value:** The CMDB tells us WHERE to look. In an enterprise with hundreds of services and thousands of components, you can't run diagnostics on everything. The service graph scopes the investigation to only the relevant components.

**Why this matters for the narrative:** Without this step, you'd need a human to manually figure out which systems are involved. That's tribal knowledge that lives in people's heads, is lost when they leave, and takes time to recall at 3am.

### 4. Parallel Diagnostics (Three Teams, Simultaneously)

The workflow fans out to three different organisational teams — all running in parallel:

| Node | Team | What it does |
|------|------|-------------|
| Diagnose Application | Application Services | Checks health endpoints for payment-svc and app-svc |
| Diagnose Message Queue | Middleware Services | Queries Kafka via Kafdrop — topic stats, DLQ message counts |
| Diagnose Storage | Storage Services | Checks disk/storage capacity on affected hosts |

Each diagnostic playbook is **generic and reusable**. It doesn't know about passports or payments — it receives parameters from the CMDB Lookup (topic names, URLs, hostnames) and runs its standard checks against those targets.

**Business value:** Three teams' expertise encoded as automation, running simultaneously. In the manual world, you'd raise a ticket to each team, wait for them to investigate one at a time, and hope they report back. Here it takes 5 seconds total.

**The cross-silo story:** Each team owns and maintains their own diagnostic playbooks. The Service Reliability team orchestrates them via the workflow. Nobody had to build a monolithic "check everything" script — each team contributed their domain expertise independently.

### 5. AI Router (Service Reliability Team)
All diagnostic results converge here. ALIA receives:
- The incident description
- The Kafka diagnostics (showing ~47% of payments are in the DLQ)
- The application diagnostics (everything healthy)
- The storage diagnostics (capacity fine)

ALIA produces a structured root cause analysis with step-by-step remediation.

**Business value:** The AI correlates data from three different domains simultaneously — something that would take a human engineer significant time to piece together. It identifies that the DLQ accumulation + healthy services = routing misconfiguration, not an outage.

### 6. Update SNOW Incident (Service Reliability Team)
The AI analysis is posted directly to the incident's work notes and the state is advanced to "In Progress".

**Business value:** The incident now contains actionable remediation steps before any human has even looked at it. An engineer picking up this ticket has a clear path to resolution instead of starting from scratch.

---

## Key Messages

### Time
- **Before:** Incident raised → assigned → reassigned → investigated → root cause found → fixed. Typically 4-48 hours for a subtle issue like this.
- **After:** Incident raised → diagnosed → remediation steps provided. Under 60 seconds.

### Tribal Knowledge
- Diagnostic expertise is codified in reusable playbooks, not locked in people's heads
- The CMDB service graph replaces "ask Dave, he knows how this connects"
- New team members benefit from day one

### Team Collaboration Without Ticket Ping-Pong
- Three teams' diagnostics run in parallel without any human coordination
- No "I've checked my bit, it's not us, reassigning to middleware"
- The workflow crosses organisational silos automatically

### Precision Over Brute Force
- The CMDB scopes the investigation to only affected components
- Diagnostic playbooks skip cleanly when their component isn't in the service graph
- At scale (hundreds of services), this prevents wasted compute and noisy false results

---

## Talking Points for Q&A

**"Could the AI just figure this out without the diagnostics?"**
No. Without real data, the AI guesses. With the DLQ message counts and healthy service endpoints as evidence, it can pinpoint routing as the cause. Garbage in, garbage out — the diagnostics give it facts.

**"Why not just have better monitoring/alerting?"**
This failure doesn't trigger alerts. Services are up. No error rates spike. The only symptom is that applications stop progressing — which looks identical to "nobody submitted an application" from a metrics standpoint. This is the class of problem that monitoring misses.

**"What if the CMDB is wrong or incomplete?"**
Valid concern. The diagnostic playbooks skip gracefully when parameters are missing. An incomplete CMDB means fewer diagnostics run, not a failure. This actually incentivises teams to maintain their CMDB — because accurate data leads to faster resolution.

**"Do teams need to change how they work?"**
No. Each team writes their diagnostic playbooks in their own org, using their own project. The Service Reliability team wires them into the workflow. Teams don't need to know about EDA or ALIA — they just maintain good operational playbooks.

**"What about remediation — does it auto-fix?"**
Not in this demo. The AI recommends steps; a human approves. But the architecture supports it — you could add a remediation node after the AI Router that launches a fix playbook with approval gates. The point is: you've gone from "we don't know what's wrong" to "here's exactly what to do" in under a minute.
