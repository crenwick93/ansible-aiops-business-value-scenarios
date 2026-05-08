import json
import logging
import os
import signal
import sys
import threading
import time
from typing import Any

import psycopg2
from confluent_kafka import Consumer, KafkaException
from flask import Flask, jsonify
from psycopg2 import OperationalError

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
    stream=sys.stdout,
)
logger = logging.getLogger("app-svc")

KAFKA_BOOTSTRAP = os.environ.get("KAFKA_BOOTSTRAP", "localhost:9092")
DATABASE_URL = os.environ.get(
    "DATABASE_URL",
    "postgresql://passports_user:passports_pass@localhost:5432/passports",
)

PAYMENTS_TOPIC = "payments"
CONSUMER_GROUP = "app-svc"
_shutdown = threading.Event()
_db_conn: Any = None
_db_lock = threading.Lock()

app = Flask(__name__)


def _get_db():
    global _db_conn
    with _db_lock:
        if _db_conn is None or _db_conn.closed:
            _db_conn = psycopg2.connect(DATABASE_URL)
        return _db_conn


def _close_db() -> None:
    global _db_conn
    with _db_lock:
        if _db_conn is not None and not _db_conn.closed:
            _db_conn.close()
        _db_conn = None


def _advance_application(citizen_ref: str, from_status: str, to_status: str) -> int:
    sql = (
        "UPDATE applications "
        "SET status = %s, updated_at = NOW() "
        "WHERE citizen_ref = %s AND status = %s"
    )
    for attempt in range(3):
        try:
            conn = _get_db()
            with conn:
                with conn.cursor() as cur:
                    cur.execute(sql, (to_status, citizen_ref, from_status))
                    n = cur.rowcount
            return n
        except OperationalError as e:
            logger.error("Database error (attempt %s): %s", attempt + 1, e, exc_info=True)
            _close_db()
            if attempt == 2:
                raise
            time.sleep(0.5 * (attempt + 1))


def _process_payment_message(value: bytes) -> None:
    data = json.loads(value.decode("utf-8"))
    citizen_ref = data["citizen_ref"]

    # Advance through the application lifecycle.
    # Normal flow: awaiting_payment → paid_pending_processing
    # Replay flow: paid_pending_processing → processing (message was held in DLQ)
    n = _advance_application(citizen_ref, "awaiting_payment", "paid_pending_processing")
    if n:
        logger.info("Payment received citizen_ref=%s status=paid_pending_processing", citizen_ref)
        return

    n = _advance_application(citizen_ref, "paid_pending_processing", "processing")
    if n:
        logger.info("Application advancing citizen_ref=%s status=processing", citizen_ref)
        return

    logger.warning("No advancement possible citizen_ref=%s (already processed or missing)", citizen_ref)


def _consumer_loop() -> None:
    conf = {
        "bootstrap.servers": KAFKA_BOOTSTRAP,
        "group.id": CONSUMER_GROUP,
        "auto.offset.reset": "earliest",
        "enable.auto.commit": True,
    }
    try:
        consumer = Consumer(conf)
    except KafkaException as e:
        logger.error("Failed to create Kafka consumer: %s", e, exc_info=True)
        return
    consumer.subscribe([PAYMENTS_TOPIC])
    try:
        while not _shutdown.is_set():
            msg = consumer.poll(1.0)
            if msg is None:
                continue
            if msg.error():
                logger.error("Kafka poll error: %s", msg.error())
                continue
            raw = msg.value()
            if raw is None:
                logger.warning("Skipping message with null payload")
                continue
            try:
                _process_payment_message(raw)
            except (json.JSONDecodeError, KeyError, UnicodeDecodeError) as e:
                logger.error("Invalid Kafka message: %s", e, exc_info=True)
            except Exception as e:
                logger.error("Error processing message: %s", e, exc_info=True)
    except KafkaException as e:
        logger.error("Consumer loop failed: %s", e, exc_info=True)
    finally:
        try:
            consumer.close()
        except Exception as e:
            logger.error("Error closing consumer: %s", e, exc_info=True)


def _on_shutdown(signum, frame) -> None:
    _shutdown.set()


def _start_consumer_thread() -> None:
    for s in (signal.SIGINT, signal.SIGTERM):
        try:
            signal.signal(s, _on_shutdown)
        except (ValueError, OSError):
            pass
    t = threading.Thread(target=_consumer_loop, name="kafka-consumer", daemon=True)
    t.start()
    logger.info("Kafka consumer thread started topic=%s group=%s", PAYMENTS_TOPIC, CONSUMER_GROUP)


_start_consumer_thread()


@app.route("/health", methods=["GET"])
def health():
    return jsonify({"status": "healthy"}), 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5001, threaded=True)
