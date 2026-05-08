import json
import logging
import os
import sys
import time
from datetime import datetime, timezone

import psycopg2
import psycopg2.extras
import requests
from flask import Flask, jsonify, render_template, request

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
    stream=sys.stdout,
)
logger = logging.getLogger("dashboard")

app = Flask(__name__)

DATABASE_URL = os.environ.get(
    "DATABASE_URL",
    "postgresql://passports_user:passports_pass@localhost:5432/passports",
)
KAFKA_ADMIN_URL = os.environ.get("KAFKA_ADMIN_URL", "http://localhost:8080")
PAYMENT_SVC_URL = os.environ.get("PAYMENT_SVC_URL", "http://localhost:5000")
APP_SVC_URL = os.environ.get("APP_SVC_URL", "http://localhost:5001")

STATUS_LABELS = {
    "awaiting_payment": "Awaiting Payment",
    "paid_pending_processing": "Payment Received - Awaiting Processing",
    "processing": "Processing",
    "complete": "Complete",
}


def get_db():
    return psycopg2.connect(DATABASE_URL, connect_timeout=5)


# -------------------------------------------------------------------------
# Citizen portal routes
# -------------------------------------------------------------------------

@app.route("/")
def citizen_home():
    return render_template("citizen.html")


@app.route("/api/citizen/lookup")
def citizen_lookup():
    ref = request.args.get("ref", "").strip().upper()
    if not ref:
        return jsonify(error="Please enter a reference number"), 400
    try:
        with get_db() as conn:
            with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
                cur.execute(
                    "SELECT citizen_ref, fee_type, status, created_at, updated_at "
                    "FROM applications WHERE citizen_ref = %s ORDER BY created_at DESC LIMIT 1",
                    (ref,),
                )
                row = cur.fetchone()
    except Exception as e:
        logger.error("Database error: %s", e)
        return jsonify(error="Service temporarily unavailable"), 503

    if not row:
        return jsonify(found=False, ref=ref), 200

    fee_label = row["fee_type"].replace("fee.", "").replace(".", " ").title()
    status_raw = row["status"]
    status_label = STATUS_LABELS.get(status_raw, status_raw.replace("_", " ").title())

    steps = ["Awaiting Payment", "Payment Received - Awaiting Processing", "Processing", "Complete"]
    current_step = 0
    for i, s in enumerate(steps):
        if s == status_label:
            current_step = i
            break

    days_waiting = 0
    if status_raw in ("awaiting_payment", "paid_pending_processing"):
        delta = datetime.now(timezone.utc) - row["updated_at"].replace(tzinfo=timezone.utc)
        days_waiting = delta.days

    return jsonify(
        found=True,
        ref=row["citizen_ref"],
        fee_type=fee_label,
        status=status_label,
        status_raw=status_raw,
        current_step=current_step,
        total_steps=len(steps),
        steps=steps,
        submitted=row["created_at"].isoformat(),
        last_updated=row["updated_at"].isoformat(),
        days_since_update=days_waiting,
    )


# -------------------------------------------------------------------------
# Engineering dashboard routes
# -------------------------------------------------------------------------

@app.route("/engineering")
def engineering_home():
    return render_template("engineering.html")


_BOOT_TIME = time.time()

_SERVICE_UPTIMES = {
    "payment-svc": 18 * 86400 + 4 * 3600,
    "app-svc": 22 * 86400 + 9 * 3600,
}


@app.route("/api/engineering/overview")
def engineering_overview():
    data = {"timestamp": datetime.now(timezone.utc).isoformat()}

    # Service health checks
    services = []
    for name, url in [("payment-svc", PAYMENT_SVC_URL), ("app-svc", APP_SVC_URL)]:
        uptime_s = _SERVICE_UPTIMES.get(name, 0) + int(time.time() - _BOOT_TIME)
        try:
            r = requests.get(f"{url}/health", timeout=3)
            services.append({
                "name": name,
                "status": "healthy" if r.status_code == 200 else "degraded",
                "response_ms": int(r.elapsed.total_seconds() * 1000),
                "http_status": r.status_code,
                "uptime_s": uptime_s,
            })
        except Exception:
            services.append({
                "name": name,
                "status": "unreachable",
                "response_ms": None,
                "http_status": None,
                "uptime_s": uptime_s,
            })
    data["services"] = services

    # Resource utilisation (simulated — low and stable)
    import random
    data["resources"] = [
        {"name": "payment-svc", "cpu_pct": round(12 + random.uniform(-2, 2), 1), "mem_pct": 34},
        {"name": "app-svc", "cpu_pct": round(8 + random.uniform(-2, 2), 1), "mem_pct": 28},
        {"name": "kafka", "cpu_pct": round(18 + random.uniform(-3, 3), 1), "mem_pct": 52},
        {"name": "postgres", "cpu_pct": round(5 + random.uniform(-1, 1), 1), "mem_pct": 41},
    ]

    # SLA (static — looks healthy)

    # Kafka — only expose broker health and aggregate throughput.
    # Individual topic names/counts are hidden to avoid giving away the DLQ issue.
    try:
        r = requests.get(f"{KAFKA_ADMIN_URL}/topics", timeout=5)
        r.raise_for_status()
        topics = r.json().get("topics", [])
        total_messages = sum(t.get("message_count_approx", 0) for t in topics)
        data["kafka"] = {
            "status": "healthy",
            "broker_count": 1,
            "topic_count": len(topics),
            "messages_total": total_messages,
        }
    except Exception:
        data["kafka"] = {"status": "unreachable"}

    # Database — only health and latency. No counts that could reveal the backlog.
    try:
        import time as _time
        t0 = _time.monotonic()
        with get_db() as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT 1")
        latency_ms = round((_time.monotonic() - t0) * 1000)
        data["database"] = {
            "status": "healthy",
            "latency_ms": latency_ms,
        }
    except Exception:
        data["database"] = {"status": "unreachable", "latency_ms": None}

    # 30-day uptime (simulated — all green, services have been stable)
    data["uptime"] = [
        {"name": "payment-svc", "pct": 100.0, "days": [1]*30},
        {"name": "app-svc", "pct": 100.0, "days": [1]*30},
        {"name": "kafka", "pct": 100.0, "days": [1]*30},
        {"name": "postgres", "pct": 100.0, "days": [1]*30},
    ]

    # Traffic & error rates (simulated — healthy traffic, zero errors)
    data["rates"] = [
        {"name": "payment-svc", "req_per_sec": round(4.2 + random.uniform(-0.5, 0.5), 1), "error_pct": 0.0},
        {"name": "app-svc", "req_per_sec": round(3.8 + random.uniform(-0.5, 0.5), 1), "error_pct": 0.0},
    ]

    # Overall platform status — always looks fine because individual services are healthy
    all_healthy = all(s["status"] == "healthy" for s in services)
    data["platform_status"] = "All Systems Operational" if all_healthy else "Degraded"

    return jsonify(data)


@app.route("/api/engineering/throughput")
def engineering_throughput():
    """Recent throughput — shows traffic IS flowing (which it is, just to the wrong topic)."""
    try:
        with get_db() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT date_trunc('minute', updated_at) AS minute, count(*) "
                    "FROM applications "
                    "WHERE updated_at > NOW() - INTERVAL '30 minutes' "
                    "GROUP BY minute ORDER BY minute"
                )
                rows = cur.fetchall()
        points = [{"time": r[0].isoformat(), "count": r[1]} for r in rows]
        return jsonify(throughput=points)
    except Exception as e:
        return jsonify(error=str(e)), 503


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080, debug=False)
