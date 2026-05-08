#!/bin/bash
set -euxo pipefail
exec > >(tee -a /var/log/userdata-dashboard.log) 2>&1
log() { echo "[$(date -Is)] $*"; }
trap 'log "ERROR on line $LINENO"; exit 1' ERR

log "Install Python 3.11 and tooling"
dnf install -y python3.11 python3.11-pip

mkdir -p /opt/dashboard/templates

pip3.11 install --no-cache-dir "flask>=3.0" "psycopg2-binary>=2.9" "requests>=2.31" "gunicorn>=21.2"

# ---------- Flask app ----------
cat >/opt/dashboard/app.py <<'PY'
import logging
import os
import sys
import time
from datetime import datetime, timezone

import psycopg2
import psycopg2.extras
import requests
from flask import Flask, jsonify, render_template, request

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s [%(name)s] %(message)s", stream=sys.stdout)
logger = logging.getLogger("dashboard")
app = Flask(__name__)

DATABASE_URL = os.environ.get("DATABASE_URL", "postgresql://passports_user:passports_pass@localhost:5432/passports")
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
                    "FROM applications WHERE citizen_ref = %s ORDER BY created_at DESC LIMIT 1", (ref,))
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
    return jsonify(found=True, ref=row["citizen_ref"], fee_type=fee_label, status=status_label,
        status_raw=status_raw, current_step=current_step, total_steps=len(steps), steps=steps,
        submitted=row["created_at"].isoformat(), last_updated=row["updated_at"].isoformat(),
        days_since_update=days_waiting)

@app.route("/engineering")
def engineering_home():
    return render_template("engineering.html")

_BOOT_TIME = time.time()
_SERVICE_UPTIMES = {"payment-svc": 18*86400+4*3600, "app-svc": 22*86400+9*3600}

@app.route("/api/engineering/overview")
def engineering_overview():
    import random
    data = {"timestamp": datetime.now(timezone.utc).isoformat()}
    services = []
    for name, url in [("payment-svc", PAYMENT_SVC_URL), ("app-svc", APP_SVC_URL)]:
        uptime_s = _SERVICE_UPTIMES.get(name, 0) + int(time.time() - _BOOT_TIME)
        try:
            r = requests.get(f"{url}/health", timeout=3)
            services.append({"name": name, "status": "healthy" if r.status_code == 200 else "degraded",
                "response_ms": int(r.elapsed.total_seconds() * 1000), "http_status": r.status_code, "uptime_s": uptime_s})
        except Exception:
            services.append({"name": name, "status": "unreachable", "response_ms": None, "http_status": None, "uptime_s": uptime_s})
    data["services"] = services
    data["resources"] = [
        {"name": "payment-svc", "cpu_pct": round(12 + random.uniform(-2, 2), 1), "mem_pct": 34},
        {"name": "app-svc", "cpu_pct": round(8 + random.uniform(-2, 2), 1), "mem_pct": 28},
        {"name": "kafka", "cpu_pct": round(18 + random.uniform(-3, 3), 1), "mem_pct": 52},
        {"name": "postgres", "cpu_pct": round(5 + random.uniform(-1, 1), 1), "mem_pct": 41},
    ]
    try:
        r = requests.get(f"{KAFKA_ADMIN_URL}/topics", timeout=5)
        r.raise_for_status()
        topics = r.json().get("topics", [])
        total_messages = sum(t.get("message_count_approx", 0) for t in topics)
        data["kafka"] = {"status": "healthy", "broker_count": 1, "topic_count": len(topics), "messages_total": total_messages}
    except Exception:
        data["kafka"] = {"status": "unreachable"}
    try:
        import time as _time
        t0 = _time.monotonic()
        with get_db() as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT 1")
        latency_ms = round((_time.monotonic() - t0) * 1000)
        data["database"] = {"status": "healthy", "latency_ms": latency_ms}
    except Exception:
        data["database"] = {"status": "unreachable", "latency_ms": None}
    data["uptime"] = [
        {"name": "payment-svc", "pct": 100.0, "days": [1]*30},
        {"name": "app-svc", "pct": 100.0, "days": [1]*30},
        {"name": "kafka", "pct": 100.0, "days": [1]*30},
        {"name": "postgres", "pct": 100.0, "days": [1]*30},
    ]
    data["rates"] = [
        {"name": "payment-svc", "req_per_sec": round(4.2 + random.uniform(-0.5, 0.5), 1), "error_pct": 0.0},
        {"name": "app-svc", "req_per_sec": round(3.8 + random.uniform(-0.5, 0.5), 1), "error_pct": 0.0},
    ]
    all_healthy = all(s["status"] == "healthy" for s in services)
    data["platform_status"] = "All Systems Operational" if all_healthy else "Degraded"
    return jsonify(data)

@app.route("/api/engineering/throughput")
def engineering_throughput():
    try:
        with get_db() as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT date_trunc('minute', updated_at) AS minute, count(*) FROM applications WHERE updated_at > NOW() - INTERVAL '30 minutes' GROUP BY minute ORDER BY minute")
                rows = cur.fetchall()
        return jsonify(throughput=[{"time": r[0].isoformat(), "count": r[1]} for r in rows])
    except Exception as e:
        return jsonify(error=str(e)), 503

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080, debug=False)
PY

# ---------- Citizen template ----------
cat >/opt/dashboard/templates/citizen.html <<'CITIZENEOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Check your passport application</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:"GDS Transport",Arial,sans-serif;font-size:16px;line-height:1.5;color:#0b0c0c;background:#f3f2f1}
.gh{background:#0b0c0c;padding:10px 0;border-bottom:10px solid #1d70b8}
.gh-c{max-width:960px;margin:0 auto;padding:0 20px;display:flex;align-items:center;gap:10px}
.gh-t{color:white;font-size:24px;font-weight:700;text-decoration:none}
.pb{max-width:960px;margin:0 auto;padding:10px 20px;border-bottom:1px solid #b1b4b6;background:#f3f2f1}
.pb-tag{background:#1d70b8;color:white;padding:2px 8px;font-size:14px;font-weight:700;text-transform:uppercase;letter-spacing:1px}
.pb-text{font-size:14px;margin-left:10px;color:#505a5f}
main{max-width:960px;margin:0 auto;padding:30px 20px 60px}
h1{font-size:36px;font-weight:700;margin-bottom:20px}
h2{font-size:24px;font-weight:700;margin-bottom:15px}
p{margin-bottom:15px;color:#505a5f}
label{display:block;font-size:19px;font-weight:700;margin-bottom:5px;color:#0b0c0c}
.hint{font-size:16px;color:#505a5f;margin-bottom:10px}
input[type=text]{font-family:inherit;font-size:19px;padding:8px 10px;border:2px solid #0b0c0c;width:100%;max-width:320px}
input[type=text]:focus{outline:3px solid #fd0;outline-offset:0;box-shadow:inset 0 0 0 2px #0b0c0c}
.btn{font-family:inherit;font-size:19px;font-weight:700;padding:10px 20px;background:#00703c;color:white;border:none;cursor:pointer;box-shadow:0 2px 0 #002d18;margin-top:10px}
.btn:hover{background:#005a30}
.rp{background:white;border-left:5px solid #1d70b8;padding:25px 30px;margin-top:30px;display:none}
.rp.vis{display:block}
.rp.nf{border-left-color:#d4351c}
.st{display:flex;gap:0;margin:25px 0;position:relative}
.ss{flex:1;text-align:center;position:relative;padding-top:40px;font-size:14px;color:#505a5f}
.ss::before{content:"";position:absolute;top:12px;left:0;right:0;height:4px;background:#b1b4b6}
.ss:first-child::before{left:50%}
.ss:last-child::before{right:50%}
.ss::after{content:"";position:absolute;top:4px;left:50%;transform:translateX(-50%);width:20px;height:20px;border-radius:50%;background:#b1b4b6;border:3px solid #f3f2f1;z-index:1}
.ss.done::before{background:#00703c}
.ss.done::after{background:#00703c}
.ss.cur::after{background:#1d70b8;width:24px;height:24px;top:2px}
.ss.cur{color:#0b0c0c;font-weight:700}
.dr{display:flex;border-bottom:1px solid #b1b4b6;padding:12px 0}
.dl{flex:0 0 200px;font-weight:700;color:#0b0c0c}
.dv{color:#0b0c0c}
.warn{color:#d4351c;font-weight:700;margin-top:15px;padding:15px;border:3px solid #d4351c;background:#fef7f7}
.info{color:#1d70b8;margin-top:15px;padding:15px;border-left:4px solid #1d70b8;background:#f0f4f9}
.err{color:#d4351c;font-weight:700;margin-top:10px}
.ft{background:#f3f2f1;border-top:1px solid #b1b4b6;padding:20px 0;margin-top:60px}
.ft-c{max-width:960px;margin:0 auto;padding:0 20px;color:#505a5f;font-size:14px}
</style>
</head>
<body>
<header class="gh"><div class="gh-c">
<a href="/" class="gh-t">DEMO - HM Passport Office</a>
</div></header>
<div class="pb"><span class="pb-tag">Demo</span><span class="pb-text">This is a simulated service for demonstration purposes only</span></div>
<main>
<h1>Check your passport application</h1>
<p>Use your application reference number to check the current status of your passport application.</p>
<div style="margin-bottom:20px">
<label for="ri">Application reference number</label>
<div class="hint">This is the reference you received when you submitted your application, for example CIT-AB1234 or CZ-00042</div>
<input type="text" id="ri" placeholder="e.g. CZ-00042" autocomplete="off">
</div>
<button class="btn" id="lb">Check status</button>
<div class="err" id="em"></div>
<div class="rp" id="rp">
<h2 id="rt"></h2>
<div class="st" id="st"></div>
<div id="ds">
<div class="dr"><div class="dl">Reference</div><div class="dv" id="dr"></div></div>
<div class="dr"><div class="dl">Application type</div><div class="dv" id="dt"></div></div>
<div class="dr"><div class="dl">Current status</div><div class="dv" id="dss"></div></div>
<div class="dr"><div class="dl">Date submitted</div><div class="dv" id="dsub"></div></div>
<div class="dr"><div class="dl">Last updated</div><div class="dv" id="dup"></div></div>
</div>
<div id="ww"></div><div id="im"></div>
</div>
<div class="rp nf" id="nfp"><h2>Application not found</h2><p>We could not find an application with reference <strong id="nfr"></strong>.</p><p>Check you have entered it correctly. Contact the support team if this continues.</p></div>
</main>
<footer class="ft"><div class="ft-c">Passport Application Service &mdash; Demo environment &mdash; Not a real government service</div></footer>
<script>
var ri=document.getElementById('ri'),lb=document.getElementById('lb'),em=document.getElementById('em'),rp=document.getElementById('rp'),nfp=document.getElementById('nfp');
function fd(iso){var d=new Date(iso);return d.toLocaleDateString('en-GB',{day:'numeric',month:'long',year:'numeric'})}
async function lk(){var ref=ri.value.trim();if(!ref){em.textContent='Enter your application reference number';return}em.textContent='';rp.classList.remove('vis');nfp.classList.remove('vis');try{var r=await fetch('/api/citizen/lookup?ref='+encodeURIComponent(ref));var d=await r.json();if(d.error){em.textContent=d.error;return}if(!d.found){document.getElementById('nfr').textContent=ref;nfp.classList.add('vis');return}document.getElementById('rt').textContent='Application '+d.ref;document.getElementById('dr').textContent=d.ref;document.getElementById('dt').textContent=d.fee_type;document.getElementById('dss').textContent=d.status;document.getElementById('dsub').textContent=fd(d.submitted);document.getElementById('dup').textContent=fd(d.last_updated);var st=document.getElementById('st');st.innerHTML='';d.steps.forEach(function(s,i){var div=document.createElement('div');div.className='ss';if(i<d.current_step)div.classList.add('done');if(i===d.current_step)div.classList.add('cur');div.textContent=s;st.appendChild(div)});var ww=document.getElementById('ww'),im=document.getElementById('im');ww.innerHTML='';im.innerHTML='';if(d.days_since_update>3&&d.status_raw==='paid_pending_processing'){ww.innerHTML='<div class="warn">Your payment was received '+d.days_since_update+' days ago but your application has not yet progressed. If this continues, please contact the support team.</div>'}else if(d.status_raw==='complete'){im.innerHTML='<div class="info">Your passport has been processed and dispatched. Please allow 5 working days for delivery.</div>'}else if(d.status_raw==='processing'){im.innerHTML='<div class="info">Your application is being processed. We aim to complete standard applications within 3 weeks.</div>'}rp.classList.add('vis')}catch(e){em.textContent='Unable to check your application. Please try again later.'}}
lb.addEventListener('click',lk);ri.addEventListener('keydown',function(e){if(e.key==='Enter')lk()});
</script>
</body></html>
CITIZENEOF

# ---------- Engineering template ----------
cat >/opt/dashboard/templates/engineering.html <<'ENGEOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Platform Operations Dashboard</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif;font-size:14px;color:#e0e0e0;background:#1a1a2e}
.tb{background:#16213e;padding:12px 24px;display:flex;justify-content:space-between;align-items:center;border-bottom:1px solid #0f3460}
.tb h1{font-size:18px;font-weight:600;color:#e0e0e0}
.sb{padding:6px 16px;border-radius:20px;font-weight:700;font-size:13px;text-transform:uppercase;letter-spacing:1px}
.sb.op{background:rgba(0,200,83,.15);color:#00c853;border:1px solid rgba(0,200,83,.3)}
.sb.dg{background:rgba(255,152,0,.15);color:#ff9800;border:1px solid rgba(255,152,0,.3)}
.lr{font-size:12px;color:#666}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(300px,1fr));gap:16px;padding:20px 24px}
.card{background:#16213e;border:1px solid #0f3460;border-radius:8px;padding:20px}
.card h2{font-size:13px;text-transform:uppercase;letter-spacing:1px;color:#888;margin-bottom:16px}
.sr{display:flex;justify-content:space-between;align-items:center;padding:10px 0;border-bottom:1px solid rgba(255,255,255,.05)}
.sr:last-child{border-bottom:none}
.sn{font-weight:600;font-size:15px;color:#e0e0e0}
.sm{font-size:12px;color:#666}
.hd{width:10px;height:10px;border-radius:50%;display:inline-block;margin-right:8px}
.hd.g{background:#00c853;box-shadow:0 0 8px rgba(0,200,83,.5)}
.hd.r{background:#ff1744;box-shadow:0 0 8px rgba(255,23,68,.5)}
.hd.a{background:#ff9800;box-shadow:0 0 8px rgba(255,152,0,.5)}
.hl{font-size:13px;font-weight:600}
.hl.g{color:#00c853}.hl.r{color:#ff1744}.hl.a{color:#ff9800}
.mg{display:grid;grid-template-columns:1fr 1fr;gap:12px}
.mt{background:rgba(255,255,255,.03);border-radius:6px;padding:14px;text-align:center}
.mt .v{font-size:28px;font-weight:700;color:#e0e0e0}
.mt .l{font-size:11px;text-transform:uppercase;letter-spacing:1px;color:#666;margin-top:4px}
.kt{display:flex;justify-content:space-between;align-items:center;padding:8px 0;border-bottom:1px solid rgba(255,255,255,.05)}
.kt:last-child{border-bottom:none}
.tn{font-family:"SF Mono",Monaco,"Cascadia Code",monospace;font-size:13px;color:#b0b0b0}
.tc{font-weight:600;color:#e0e0e0}
.na{text-align:center;padding:30px;color:#444}
.na .ic{font-size:36px;margin-bottom:8px}
.na .tx{font-size:14px}
.rd{padding:10px 0;border-bottom:1px solid rgba(255,255,255,.05)}
.rd:last-child{border-bottom:none}
.rd-t{font-size:11px;color:#555}
.rd-d{font-size:14px;color:#b0b0b0}
.tc-c{width:100%;height:120px;position:relative;margin-top:10px}
.tc-c canvas{width:100%;height:100%}
</style>
</head>
<body>
<div class="tb">
<h1>Passport Application Service &mdash; Platform Operations</h1>
<span class="sb op" id="pb">All Systems Operational</span>
<span class="lr">Last refresh: <span id="rt">--</span> (auto-refreshes every 10s)</span>
</div>
<div class="grid">
<div class="card"><h2>Service Health</h2><div id="sl"><div class="sr"><span class="sn">Loading...</span></div></div></div>
<div class="card"><h2>Database (PostgreSQL)</h2><div class="mg"><div class="mt"><div class="v hl g" id="dbs">--</div><div class="l">Status</div></div><div class="mt"><div class="v" id="dbl">--</div><div class="l">Latency (ms)</div></div></div></div>
<div class="card"><h2>Message Bus (Kafka)</h2><div class="sr" style="margin-bottom:12px"><span class="sn">Broker</span><span><span class="hd g" id="kd"></span><span class="hl g" id="kl">Healthy</span></span></div><div class="mg"><div class="m"><div class="mv" id="kb">1</div><div class="ml">Brokers</div></div><div class="m"><div class="mv" id="ktc">--</div><div class="ml">Topics</div></div></div></div>
<div class="card"><h2>Active Alerts</h2><div class="na"><div class="ic">&#10003;</div><div class="tx">No active alerts</div></div></div>
<div class="card"><h2>Resource Utilisation</h2><div id="res"></div></div>
<div class="card"><h2>Uptime (30 days)</h2><div id="upt"></div></div>
<div class="card"><h2>Traffic &amp; Errors</h2><div id="rates"></div></div>
<div class="card"><h2>On-Call</h2><div style="display:flex;align-items:center;padding:10px 0;border-bottom:1px solid rgba(255,255,255,.05)"><div style="width:32px;height:32px;border-radius:50%;background:#0f3460;display:flex;align-items:center;justify-content:center;font-size:13px;font-weight:600;color:#00c853;margin-right:12px">JC</div><div><div style="font-size:14px;color:#e0e0e0">James Carter</div><div style="font-size:11px;color:#555">Primary &mdash; Service Reliability</div></div></div><div style="display:flex;align-items:center;padding:10px 0"><div style="width:32px;height:32px;border-radius:50%;background:#0f3460;display:flex;align-items:center;justify-content:center;font-size:13px;font-weight:600;color:#00c853;margin-right:12px">SP</div><div><div style="font-size:14px;color:#e0e0e0">Sarah Patel</div><div style="font-size:11px;color:#555">Secondary &mdash; Service Reliability</div></div></div></div>
<div class="card"><h2>Recent Changes</h2><div><div class="rd"><div class="rd-t">18 Apr 2026, 09:30</div><div class="rd-d">payment-svc v1.4.2 &mdash; config update (routing rules)</div></div><div class="rd"><div class="rd-t">15 Apr 2026, 14:15</div><div class="rd-d">app-svc v1.2.0 &mdash; consumer group rebalance fix</div></div><div class="rd"><div class="rd-t">10 Apr 2026, 11:00</div><div class="rd-d">PostgreSQL maintenance &mdash; VACUUM ANALYZE</div></div></div></div>
<div class="card"><h2>Processing Throughput (30 min)</h2><div class="tc-c"><canvas id="cv"></canvas></div></div>
</div>
<script>
function hc(s){return s==='healthy'?'g':s==='degraded'?'a':'r'}
function dc(cv,pts){var ctx=cv.getContext('2d'),dpr=window.devicePixelRatio||1,rect=cv.getBoundingClientRect();cv.width=rect.width*dpr;cv.height=rect.height*dpr;ctx.scale(dpr,dpr);var w=rect.width,h=rect.height;ctx.clearRect(0,0,w,h);if(!pts||pts.length<2){ctx.fillStyle='#444';ctx.font='13px sans-serif';ctx.fillText('Waiting for data...',w/2-50,h/2);return}var vals=pts.map(function(p){return p.count}),mx=Math.max.apply(null,vals.concat([1])),sx=w/(pts.length-1);ctx.strokeStyle='rgba(255,255,255,0.05)';ctx.lineWidth=1;for(var i=0;i<4;i++){var y=(h/4)*i+10;ctx.beginPath();ctx.moveTo(0,y);ctx.lineTo(w,y);ctx.stroke()}ctx.beginPath();ctx.moveTo(0,h);pts.forEach(function(p,i){var x=i*sx,y=h-(p.count/mx)*(h-20);ctx.lineTo(x,y)});ctx.lineTo(w,h);ctx.closePath();var gr=ctx.createLinearGradient(0,0,0,h);gr.addColorStop(0,'rgba(0,200,83,0.3)');gr.addColorStop(1,'rgba(0,200,83,0.02)');ctx.fillStyle=gr;ctx.fill();ctx.beginPath();pts.forEach(function(p,i){var x=i*sx,y=h-(p.count/mx)*(h-20);if(i===0)ctx.moveTo(x,y);else ctx.lineTo(x,y)});ctx.strokeStyle='#00c853';ctx.lineWidth=2;ctx.stroke()}
function fu(s){var d=Math.floor(s/86400),h=Math.floor((s%86400)/3600);return d+'d '+h+'h'}
async function rf(){try{var r=await fetch('/api/engineering/overview');var d=await r.json();var pb=document.getElementById('pb');pb.textContent=d.platform_status;pb.className='sb '+(d.platform_status==='All Systems Operational'?'op':'dg');var sl=document.getElementById('sl');sl.innerHTML='';d.services.forEach(function(s){var c=hc(s.status);var meta=(s.response_ms!==null?s.response_ms+'ms response':'No response')+(s.uptime_s?' &middot; up '+fu(s.uptime_s):'');sl.innerHTML+='<div class="sr"><div><div class="sn">'+s.name+'</div><div class="sm">'+meta+'</div></div><span><span class="hd '+c+'"></span><span class="hl '+c+'">'+s.status.charAt(0).toUpperCase()+s.status.slice(1)+'</span></span></div>'});var kd=document.getElementById('kd'),kl=document.getElementById('kl'),kc=hc(d.kafka.status);kd.className='hd '+kc;kl.className='hl '+kc;kl.textContent=d.kafka.status.charAt(0).toUpperCase()+d.kafka.status.slice(1);if(d.kafka.topic_count!==undefined){document.getElementById('ktc').textContent=d.kafka.topic_count}if(d.database){var ds=document.getElementById('dbs'),dc2=hc(d.database.status);ds.textContent=d.database.status.charAt(0).toUpperCase()+d.database.status.slice(1);ds.className='v hl '+dc2;document.getElementById('dbl').textContent=d.database.latency_ms!==null?d.database.latency_ms:'--'}if(d.resources){var res=document.getElementById('res');res.innerHTML='';d.resources.forEach(function(rv){res.innerHTML+='<div style="display:flex;align-items:center;padding:6px 0;border-bottom:1px solid rgba(255,255,255,0.05)"><div style="flex:0 0 90px;font-size:12px;color:#b0b0b0">'+rv.name+'</div><div style="flex:1;display:flex;gap:10px"><div style="flex:1"><div style="font-size:10px;color:#555;text-transform:uppercase">CPU</div><div style="height:5px;background:rgba(255,255,255,0.05);border-radius:3px;overflow:hidden"><div style="height:100%;width:'+rv.cpu_pct+'%;background:#00c853;border-radius:3px"></div></div><div style="font-size:10px;color:#666">'+rv.cpu_pct+'%</div></div><div style="flex:1"><div style="font-size:10px;color:#555;text-transform:uppercase">MEM</div><div style="height:5px;background:rgba(255,255,255,0.05);border-radius:3px;overflow:hidden"><div style="height:100%;width:'+rv.mem_pct+'%;background:#00c853;border-radius:3px"></div></div><div style="font-size:10px;color:#666">'+rv.mem_pct+'%</div></div></div></div>'})}if(d.uptime){var upt=document.getElementById('upt');upt.innerHTML='';d.uptime.forEach(function(u){var bars='';u.days.forEach(function(dy){bars+='<div style="flex:1;height:18px;border-radius:2px;background:'+(dy===1?'#00c853':dy===0?'#ff1744':'#ff9800')+'"></div>'});upt.innerHTML+='<div style="display:flex;align-items:center;padding:6px 0;border-bottom:1px solid rgba(255,255,255,0.05)"><div style="flex:0 0 90px;font-size:12px;color:#b0b0b0">'+u.name+'</div><div style="flex:1;min-width:0;display:flex;gap:1px">'+bars+'</div><div style="flex:0 0 50px;text-align:right;font-size:12px;font-weight:600;color:#00c853">'+u.pct+'%</div></div>'})}if(d.rates){var rt=document.getElementById('rates');rt.innerHTML='';d.rates.forEach(function(rv){var ec=rv.error_pct>1?'#ff1744':rv.error_pct>0?'#ff9800':'#00c853';rt.innerHTML+='<div style="display:flex;justify-content:space-between;align-items:center;padding:10px 0;border-bottom:1px solid rgba(255,255,255,0.05)"><div style="font-size:13px;color:#b0b0b0">'+rv.name+'</div><div style="display:flex;gap:16px"><div style="text-align:center"><div style="font-size:16px;font-weight:700;color:#e0e0e0">'+rv.req_per_sec+'</div><div style="font-size:10px;text-transform:uppercase;color:#555">req/s</div></div><div style="text-align:center"><div style="font-size:16px;font-weight:700;color:'+ec+'">'+rv.error_pct+'%</div><div style="font-size:10px;text-transform:uppercase;color:#555">errors</div></div></div></div>'})}document.getElementById('rt').textContent=new Date().toLocaleTimeString('en-GB')}catch(e){console.error('Refresh failed:',e)}try{var r2=await fetch('/api/engineering/throughput');var d2=await r2.json();dc(document.getElementById('cv'),d2.throughput||[])}catch(e){console.error('Throughput failed:',e)}}
rf();setInterval(rf,10000);
</script>
</body></html>
ENGEOF

# ---------- systemd ----------
cat >/etc/systemd/system/dashboard.service <<UNIT
[Unit]
Description=AIOps Demo Dashboard
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/dashboard
Environment=PYTHONUNBUFFERED=1
Environment=DATABASE_URL=postgresql://passports_user:passports_pass@${postgres_host}:5432/passports
Environment=KAFKA_ADMIN_URL=http://${kafka_host}:8080
Environment=PAYMENT_SVC_URL=http://${payment_host}:5000
Environment=APP_SVC_URL=http://${app_host}:5001
ExecStart=/usr/bin/python3.11 -m gunicorn -b 0.0.0.0:8080 -w 2 --threads 2 app:app
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now dashboard.service

# -----------------------------------------------------------------------------
# Kafdrop — lightweight Kafka web UI (port 9000)
# -----------------------------------------------------------------------------
dnf install -y java-17-amazon-corretto-headless

KAFDROP_VERSION="4.0.2"
curl -fSL "https://github.com/obsidiandynamics/kafdrop/releases/download/$${KAFDROP_VERSION}/kafdrop-$${KAFDROP_VERSION}.jar" \
  -o /opt/kafdrop.jar

cat >/etc/systemd/system/kafdrop.service <<EOF
[Unit]
Description=Kafdrop Kafka Web UI
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/java -jar /opt/kafdrop.jar --kafka.brokerConnect=${kafka_ip}:9092 --server.port=9000
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now kafdrop.service
log "dashboard user-data completed (including Kafdrop)"
