# Application service

Subscribes to the `payments` Kafka topic and updates the `applications` table in PostgreSQL for each payment event.

## Behavior

- A **background thread** runs a `confluent_kafka` consumer in consumer group `app-svc` on topic `payments` (`earliest` offset if no committed position; auto-commit enabled).
- For each message, the service parses JSON, reads `citizen_ref`, and runs:
  - `UPDATE applications SET status = 'paid_pending_processing', updated_at = NOW() WHERE citizen_ref = <citizen_ref> AND status = 'awaiting_payment'`
- If no row is updated (unknown citizen or status not `awaiting_payment`), a warning is logged. Invalid JSON or missing `citizen_ref` is logged as an error with the full exception.
- The **Flask** app (served on port `5001` in the demo) exposes only `GET /health`, which always returns `200` and `{"status": "healthy"}`.

## Configuration

- **`KAFKA_BOOTSTRAP`**: Kafka brokers (default `localhost:9092`).
- **`DATABASE_URL`**: PostgreSQL DSN (default `postgresql://passports_user:passports_pass@localhost:5432/passports`).

Use a single Gunicorn worker so only one process runs one consumer; the included systemd unit uses `-w 1`.

## Run locally

```bash
python3.11 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
export KAFKA_BOOTSTRAP=localhost:9092
export DATABASE_URL=postgresql://passports_user:passports_pass@localhost:5432/passports
gunicorn -b 0.0.0.0:5001 -w 1 app:app
```

Install under `/opt/app-svc` and enable `systemd/app-svc.service`; set brokers and DSN in `/etc/app-svc.env` as needed.
