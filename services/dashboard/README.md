# Dashboard

Two-view dashboard for the AIOps demo, served from a single Flask application.

## Views

### Citizen Portal (`/`)

A government-service-inspired "Check your passport application" page. Citizens enter their
application reference number and see the current status with a progress tracker.

After the break is introduced, citizens looking up standard adult applications
see their status stuck on "Payment Received - Awaiting Processing" with a
warning that the application has not progressed. This is the experience that
generates calls to the contact centre.

### Engineering Dashboard (`/engineering`)

A dark-themed operations dashboard showing service health, Kafka topics,
database stats, throughput, and recent deployments. Everything looks green
and operational — because from the platform's perspective, it is. The
misrouting bug doesn't cause errors, crashes, or alerts.

The subtle hint is in the "Recent Changes" section: a config update to
payment-svc from a few days ago. But there's nothing to flag it as
problematic.

## API Endpoints

- `GET /api/citizen/lookup?ref=CZ-00042` — look up an application by reference
- `GET /api/engineering/overview` — service health, Kafka, database stats
- `GET /api/engineering/throughput` — processing throughput over the last 30 minutes

## Environment Variables

- `DATABASE_URL` — PostgreSQL connection string
- `KAFKA_ADMIN_URL` — Kafka Flask admin shim URL
- `PAYMENT_SVC_URL` — payment-svc base URL (for health checks)
- `APP_SVC_URL` — app-svc base URL (for health checks)
