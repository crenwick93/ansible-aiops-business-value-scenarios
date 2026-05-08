#!/bin/bash
set -euxo pipefail
exec > >(tee -a /var/log/userdata-app-svc.log) 2>&1
log() { echo "[$(date -Is)] $*"; }
trap 'log "ERROR on line $LINENO"; exit 1' ERR

log "Install Python 3.11, client libs, libpq"
dnf install -y python3.11 python3.11-pip

mkdir -p /opt/app-svc

cat >/opt/app-svc/app.py <<'PY'
import json
import logging
import os
import random
import threading
import time
from datetime import datetime, timedelta, timezone
from http import HTTPStatus

import psycopg2
from confluent_kafka import Consumer, KafkaError
from flask import Flask, jsonify

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("app-svc")

app = Flask(__name__)
BOOT = os.environ["KAFKA_BOOTSTRAP"]
DB_URL = os.environ["DATABASE_URL"]


def connect_db():
    return psycopg2.connect(DB_URL, connect_timeout=10)


def process_payment_event(payload: dict) -> None:
    citizen = str(payload.get("citizen_ref") or "").strip()
    fee_type = str(payload.get("fee_type") or "unknown")
    if not citizen:
        return
    new_status = "processing"
    with connect_db() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "UPDATE applications SET status = %s, updated_at = now() "
                "WHERE citizen_ref = %s RETURNING id, created_at",
                (new_status, citizen),
            )
            row = cur.fetchone()
            if row:
                created_at = row[1]
                age_days = (datetime.now() - created_at).days
                log.info("Processed %s [%s] applied %d days ago -> %s", citizen, fee_type, age_days, new_status)
            else:
                age_hours = random.randint(2, 72)
                created_at = datetime.now() - timedelta(hours=age_hours)
                cur.execute(
                    "INSERT INTO applications (citizen_ref, fee_type, status, created_at) VALUES (%s, %s, %s, %s)",
                    (citizen, fee_type, new_status, created_at),
                )
                age_days = age_hours // 24
                log.info("Processed %s [%s] applied %d days ago -> %s", citizen, fee_type, age_days, new_status)
        conn.commit()


def kafka_consumer_loop() -> None:
    c = Consumer(
        {
            "bootstrap.servers": BOOT,
            "group.id": "app-svc-payments",
            "enable.auto.commit": True,
            "auto.offset.reset": "earliest",
        }
    )
    c.subscribe(["payments"])
    log.info("Subscribed to payments; bootstrap=%s", BOOT)
    while True:
        try:
            msg = c.poll(1.0)
        except Exception as exc:  # noqa: BLE001
            log.error("poll error: %s", exc)
            time.sleep(1)
            continue
        if msg is None:
            continue
        if msg.error():
            if msg.error().code() == KafkaError._PARTITION_EOF:
                continue
            log.error("Kafka error: %s", msg.error())
            continue
        try:
            payload = json.loads(msg.value().decode("utf-8"))
        except (json.JSONDecodeError, UnicodeError) as exc:
            log.warning("Bad message: %s", exc)
            continue
        try:
            process_payment_event(payload)
        except Exception as exc:  # noqa: BLE001
            log.exception("Handle message failed: %s", exc)


def _start_consumer() -> None:
    t = threading.Thread(target=kafka_consumer_loop, name="kafka-consumer", daemon=True)
    t.start()


_start_consumer()


@app.route("/health")
def health():
    return jsonify(status="ok", bootstrap=BOOT, database="passports", ts=time.time()), HTTPStatus.OK
PY

pip3.11 install --no-cache-dir "flask>=3.0" "gunicorn>=22.0" "confluent-kafka>=2.3.0" "psycopg2-binary>=2.9.9"
chmod 755 /opt/app-svc/app.py
chown -R root:root /opt/app-svc

cat >/etc/systemd/system/app-svc.service <<UNIT
[Unit]
Description=App service (Kafka consumer + Flask on 5001)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/app-svc
Environment=KAFKA_BOOTSTRAP=${kafka_host}:9092
Environment=DATABASE_URL=postgresql://passports_user:passports_pass@${postgres_host}:5432/passports
Environment=PYTHONUNBUFFERED=1
ExecStart=/usr/bin/python3.11 -m gunicorn -b 0.0.0.0:5001 -w 1 --threads 4 --timeout 120 app:app
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now app-svc.service
log "app-svc user-data completed"
