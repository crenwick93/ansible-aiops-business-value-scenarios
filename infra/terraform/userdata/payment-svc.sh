#!/bin/bash
set -euxo pipefail
exec > >(tee -a /var/log/userdata-payment-svc.log) 2>&1
log() { echo "[$(date -Is)] $*"; }
trap 'log "ERROR on line $LINENO"; exit 1' ERR

log "Install Python 3.11 and tooling"
dnf install -y python3.11 python3.11-pip
mkdir -p /opt/payment-svc
export KAFKA_BOOTSTRAP="${kafka_host}:9092"

cat >/opt/payment-svc/config.py <<'PY'
ROUTING_RULES = {
    "fee.standard.adult": "payments.dlq",
    "fee.standard.child": "payments",
    "fee.priority.adult": "payments",
    "fee.priority.child": "payments",
}

DEFAULT_TOPIC = "payments"
PY

cat >/opt/payment-svc/app.py <<'PY'
import json
import logging
import os
import sys
import uuid
from datetime import datetime, timezone

from confluent_kafka import KafkaException, Producer
from flask import Flask, jsonify, request

import config

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
    stream=sys.stdout,
)
logger = logging.getLogger("payment-svc")

KAFKA_BOOTSTRAP = os.environ.get("KAFKA_BOOTSTRAP", "localhost:9092")

app = Flask(__name__)
_producer = None


def get_producer():
    global _producer
    if _producer is None:
        _producer = Producer(
            {
                "bootstrap.servers": KAFKA_BOOTSTRAP,
                "client.id": "payment-svc",
            }
        )
    return _producer


def _delivery_cb(err, msg):
    if err is not None:
        logger.error("Kafka delivery failed: %s", err)


def route_topic(fee_type):
    return config.ROUTING_RULES.get(fee_type, config.DEFAULT_TOPIC)


@app.route("/health", methods=["GET"])
def health():
    return jsonify({"status": "healthy"}), 200


@app.route("/pay", methods=["POST"])
def pay():
    if not request.is_json:
        return jsonify({"error": "Content-Type must be application/json"}), 400
    data = request.get_json(silent=True) or {}
    citizen_ref = data.get("citizen_ref")
    fee_type = data.get("fee_type")
    if not isinstance(citizen_ref, str) or not citizen_ref:
        return jsonify({"error": "citizen_ref is required"}), 400
    if not isinstance(fee_type, str) or not fee_type:
        return jsonify({"error": "fee_type is required"}), 400
    topic = route_topic(fee_type)
    transaction_id = str(uuid.uuid4())
    payload = {
        "citizen_ref": citizen_ref,
        "fee_type": fee_type,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "transaction_id": transaction_id,
    }
    value = json.dumps(payload, separators=(",", ":"), ensure_ascii=False)
    try:
        producer = get_producer()
        producer.produce(
            topic,
            value=value.encode("utf-8"),
            key=citizen_ref.encode("utf-8"),
            callback=_delivery_cb,
        )
        producer.poll(0)
        producer.flush(timeout=30.0)
    except KafkaException as e:
        logger.exception("Failed to send payment to Kafka: %s", e)
        return jsonify({"error": str(e)}), 500
    logger.info(
        "Payment received citizen_ref=%s fee_type=%s routed_topic=%s transaction_id=%s",
        citizen_ref, fee_type, topic, transaction_id,
    )
    return jsonify({"transaction_id": transaction_id}), 202
PY

pip3.11 install --no-cache-dir "flask>=3.0" "gunicorn>=22.0" "confluent-kafka>=2.3.0"
chown -R root:root /opt/payment-svc
chmod 755 /opt/payment-svc/app.py

cat >/etc/systemd/system/payment-svc.service <<UNIT
[Unit]
Description=Payment service (Flask + Kafka)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/payment-svc
Environment=KAFKA_BOOTSTRAP=${kafka_host}:9092
Environment=PYTHONUNBUFFERED=1
ExecStart=/usr/bin/python3.11 -m gunicorn -b 0.0.0.0:5000 -w 2 --threads 2 app:app
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now payment-svc.service
log "payment-svc user-data completed"
