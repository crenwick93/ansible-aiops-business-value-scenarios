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
_producer: Producer | None = None


def get_producer() -> Producer:
    global _producer
    if _producer is None:
        _producer = Producer(
            {
                "bootstrap.servers": KAFKA_BOOTSTRAP,
                "client.id": "payment-svc",
            }
        )
    return _producer


def _delivery_cb(err, msg) -> None:
    if err is not None:
        logger.error("Kafka delivery failed: %s", err)


def route_topic(fee_type: str) -> str:
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
        return jsonify({"error": "citizen_ref is required and must be a non-empty string"}), 400
    if not isinstance(fee_type, str) or not fee_type:
        return jsonify({"error": "fee_type is required and must be a non-empty string"}), 400
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
    except Exception as e:
        logger.exception("Failed to send payment: %s", e)
        return jsonify({"error": str(e)}), 500
    logger.info(
        "Payment received citizen_ref=%s fee_type=%s routed_topic=%s transaction_id=%s",
        citizen_ref,
        fee_type,
        topic,
        transaction_id,
    )
    return jsonify({"transaction_id": transaction_id}), 202
