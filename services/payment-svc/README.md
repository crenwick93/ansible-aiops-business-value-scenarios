# Payment service

HTTP API that accepts passport fee payments and publishes each payment as a JSON event to a Kafka topic chosen by `fee_type`.

## Endpoints

| Method | Path     | Description |
|--------|----------|-------------|
| `GET`  | `/health` | Liveness. Always returns `200` and `{"status": "healthy"}`, independent of routing configuration. |
| `POST` | `/pay`    | Body (JSON): `citizen_ref` (string), `fee_type` (string). Publishes a message with `citizen_ref`, `fee_type`, ISO 8601 UTC `timestamp`, and a UUID `transaction_id`. Responds with `202` and `{"transaction_id": "..."}`. |

## Configuration

- **`KAFKA_BOOTSTRAP`**: Comma-separated broker list (default `localhost:9092`).

## Routing

`config.py` defines `ROUTING_RULES`, mapping each `fee_type` to a Kafka topic name, plus `DEFAULT_TOPIC` for any unknown `fee_type`. The break playbook edits `ROUTING_RULES` (for example, changing one entry from `payments` to `payments.dlq`) so a subset of traffic no longer lands on the topic the downstream consumer reads. The payment service and `/health` still succeed; the bug shows up in processing or lag, not in this service’s health check.

## Run locally

```bash
python3.11 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
export KAFKA_BOOTSTRAP=localhost:9092
gunicorn -b 0.0.0.0:5000 app:app
```

Deploy with systemd: install code under `/opt/payment-svc` (or adjust paths), create a venv, and enable `systemd/payment-svc.service`. Set `KAFKA_BOOTSTRAP` in `/etc/payment-svc.env` to override the default from the unit file.
