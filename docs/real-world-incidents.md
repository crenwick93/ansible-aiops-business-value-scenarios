# Real-World Incidents: Silent Misconfigurations

These are real production incidents caused by the same pattern our demo illustrates —
a single configuration value is wrong, no error is thrown, and the system silently
misbehaves until someone notices the business impact.

Use these to build empathy with your audience: "This isn't theoretical. This happens
to the best-run organisations in the world."

---

## Knight Capital Group (2012)

**What happened:** During a deployment, an engineer forgot to update a routing flag on
one of eight servers. That single server began executing a retired test algorithm against
live market orders. The system processed $7 billion in erroneous trades in 45 minutes.

**Business impact:** $440 million loss. The company was bankrupt within days and had to
be acquired.

**Why it's relevant to our demo:** One config value (`payments.dlq` vs `payments`) on
one service. No errors thrown. No alerts fired. The system "worked" — it just routed
orders to the wrong place. The longer it ran undetected, the worse the damage.

**Source:** SEC report, August 2013 — "In the Matter of Knight Capital Americas LLC"

---

## Facebook / Meta Global Outage (October 2021)

**What happened:** A routine BGP configuration change accidentally withdrew the routes
that allowed Facebook's own DNS servers to be reachable. Every Facebook, Instagram, and
WhatsApp service disappeared from the internet for 6 hours.

**Business impact:** Estimated $100 million in lost revenue. 3.5 billion users affected.
Engineers couldn't even badge into data centres because the door systems relied on
Facebook's internal network.

**Why it's relevant to our demo:** A config change that passed review and was deployed
via automation. The system that was supposed to audit the change was itself dependent on
the thing that broke. Cross-team diagnosis was physically impossible because
communication tools (Workplace) were also down.

**Source:** Facebook Engineering blog post, "More details about the October 4 outage"

---

## Cloudflare WAF Outage (July 2019)

**What happened:** A single regex rule deployed to Cloudflare's Web Application Firewall
caused catastrophic backtracking. CPU usage hit 100% on every edge server globally.
All Cloudflare-proxied websites went offline for 27 minutes.

**Business impact:** Millions of websites down simultaneously. Cloudflare processes ~10%
of all HTTP requests globally.

**Why it's relevant to our demo:** One rule in a config file. It passed staging tests
(which didn't have enough traffic to trigger the backtracking). No error until it hit
production load. The fix was a one-line config revert — but finding it took the full
27 minutes because the team initially assumed it was a DDoS attack.

**Source:** Cloudflare blog, "Details of the Cloudflare outage on July 2, 2019"

---

## Amazon S3 Outage (February 2017)

**What happened:** An engineer ran a command to take a small number of S3 subsystem
servers offline for maintenance. A typo in the command removed far more servers than
intended. The cascading failure took down S3 and every AWS service that depended on it
(which was nearly all of them) for 4 hours.

**Business impact:** Estimated $150 million in losses across the S3-dependent ecosystem.
Took down Slack, Trello, Quora, and the AWS health dashboard itself (so AWS couldn't
even communicate the outage status to customers).

**Why it's relevant to our demo:** A single mistyped parameter in an operational command.
The system accepted it without validation. No error was returned. The blast radius was
invisible until services started failing minutes later.

**Source:** AWS post-incident summary, "Summary of the Amazon S3 Service Disruption"

---

## GitLab Database Deletion (January 2017)

**What happened:** During an incident response for a different problem, a fatigued
engineer ran `rm -rf` on what they believed was a replication staging directory. It was
the production PostgreSQL data directory. 300GB of live data deleted.

**Business impact:** 6 hours of data permanently lost. 18 hours of downtime. Five
different backup strategies all failed or were untested.

**Why it's relevant to our demo:** The root cause was a config confusion — the engineer
was on the wrong host. The environment looked identical. No guardrails distinguished
production from staging. This is the "ticket ping-pong" problem: the DB team was
firefighting a replication issue that was originally escalated by the app team, operating
under pressure across team boundaries.

**Source:** GitLab's public incident postmortem (live-streamed the recovery)

---

## British Airways IT Failure (May 2017)

**What happened:** A contractor disconnected and then reconnected a power supply to a
data centre. The surge on reconnection corrupted server configurations. Systems came back
online with incorrect routing and data synchronisation settings.

**Business impact:** All flights grounded for 3 days. 75,000 passengers stranded.
Estimated cost: £80 million.

**Why it's relevant to our demo:** The hardware came back "online" — green lights
everywhere. But the software configurations were silently corrupted. Systems appeared
healthy individually but couldn't communicate correctly. It took days because each team
saw their own systems as functional.

**Source:** House of Commons Transport Committee report, September 2017

---

## Key Pattern

Every one of these shares the same DNA:

1. **A single configuration value was wrong**
2. **No error was thrown at the point of misconfiguration**
3. **Monitoring showed "healthy" because it measured availability, not correctness**
4. **The blast radius was invisible until business impact surfaced**
5. **Cross-team diagnosis was the bottleneck** — not the fix itself

The fix in each case was trivial (revert one line, re-run one command, restore one
setting). The *finding* took hours or days because no single team had visibility across
the full path from config to business impact.

That's exactly what AIOps solves: automated, cross-boundary diagnosis that follows the
data rather than respecting org chart silos.
