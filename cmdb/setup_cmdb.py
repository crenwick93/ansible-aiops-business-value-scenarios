#!/usr/bin/env python3
"""Create the AIOps demo business service, component CIs, and relationships
in a ServiceNow instance.

Reads ci_definitions.yml for the graph structure.  Idempotent — running twice
does not create duplicates (uses the [aiops-demo] description prefix to detect
existing records).

Usage:
    export SERVICENOW_INSTANCE_URL=https://devXXXXXX.service-now.com
    export SERVICENOW_USERNAME=admin
    export SERVICENOW_PASSWORD=...
    python3 setup_cmdb.py [--ip-file terraform-outputs.json]
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

import requests
import yaml

DEMO_TAG = "[aiops-demo]"
SCRIPT_DIR = Path(__file__).resolve().parent
CI_DEFS_PATH = SCRIPT_DIR / "ci_definitions.yml"

session = requests.Session()


def snow_url(path: str) -> str:
    base = os.environ["SERVICENOW_INSTANCE_URL"].rstrip("/")
    return f"{base}{path}"


def configure_session() -> None:
    session.auth = (os.environ["SERVICENOW_USERNAME"], os.environ["SERVICENOW_PASSWORD"])
    session.headers.update({"Accept": "application/json", "Content-Type": "application/json"})


def find_existing(table: str, query: str) -> dict | None:
    """Return the first record matching `query`, or None."""
    url = snow_url(f"/api/now/table/{table}?sysparm_query={query}&sysparm_limit=1")
    r = session.get(url)
    r.raise_for_status()
    results = r.json().get("result", [])
    return results[0] if results else None


def create_or_update(table: str, name: str, ci_class: str, data: dict) -> str:
    """Create a CI or return its sys_id if it already exists."""
    query = f"name={name}^descriptionLIKE{DEMO_TAG}"
    existing = find_existing(table, query)
    if existing:
        sys_id = existing["sys_id"]
        print(f"  EXISTS  {ci_class}/{name}  sys_id={sys_id}")
        r = session.patch(snow_url(f"/api/now/table/{table}/{sys_id}"), json=data)
        r.raise_for_status()
        return sys_id

    r = session.post(snow_url(f"/api/now/table/{table}"), json=data)
    r.raise_for_status()
    sys_id = r.json()["result"]["sys_id"]
    print(f"  CREATED {ci_class}/{name}  sys_id={sys_id}")
    return sys_id


def create_relationship(parent_id: str, child_id: str, rel_type: str) -> str:
    """Create a CMDB relationship, skipping if one already exists."""
    rel_type_id = resolve_rel_type(rel_type)
    query = f"parent={parent_id}^child={child_id}^type={rel_type_id}"
    existing = find_existing("cmdb_rel_ci", query)
    if existing:
        print(f"  EXISTS  relationship {rel_type} (sys_id={existing['sys_id']})")
        return existing["sys_id"]

    data = {"parent": parent_id, "child": child_id, "type": rel_type_id}
    r = session.post(snow_url("/api/now/table/cmdb_rel_ci"), json=data)
    r.raise_for_status()
    sys_id = r.json()["result"]["sys_id"]
    print(f"  CREATED relationship {rel_type} (sys_id={sys_id})")
    return sys_id


def resolve_rel_type(name: str) -> str:
    """Look up a relationship type sys_id by its name (e.g. 'Contains::Used by').
    Creates the relationship type if it doesn't exist."""
    parts = name.split("::")
    parent_descriptor = parts[0].strip()
    child_descriptor = parts[1].strip() if len(parts) > 1 else parent_descriptor

    query = f"parent_descriptor={parent_descriptor}"
    existing = find_existing("cmdb_rel_type", query)
    if existing:
        return existing["sys_id"]

    data = {"parent_descriptor": parent_descriptor, "child_descriptor": child_descriptor}
    r = session.post(snow_url("/api/now/table/cmdb_rel_type"), json=data)
    r.raise_for_status()
    sys_id = r.json()["result"]["sys_id"]
    print(f"  CREATED relationship type '{name}' (sys_id={sys_id})")
    return sys_id


def load_ip_overrides(ip_file: str | None) -> dict:
    """Load Terraform output JSON to populate CI IP addresses."""
    if not ip_file:
        return {}
    path = Path(ip_file)
    if not path.exists():
        print(f"WARNING: IP file '{ip_file}' not found; IPs will not be populated")
        return {}
    with open(path) as f:
        data = json.load(f)
    mapping = {}
    for key in ("kafka", "postgres", "payment_svc", "app_svc"):
        if key in data:
            val = data[key].get("value", data[key]) if isinstance(data[key], dict) else data[key]
            if isinstance(val, dict):
                mapping[key] = val.get("private_ip", "")
    return mapping


IP_KEY_MAP = {
    "payment-svc": "payment_svc",
    "payment-queue": "kafka",
    "app-svc": "app_svc",
    "app-db": "postgres",
}


def main() -> int:
    parser = argparse.ArgumentParser(description="Set up AIOps demo CMDB in ServiceNow")
    parser.add_argument(
        "--ip-file",
        help="Path to Terraform outputs JSON (terraform output -json > file.json)",
    )
    args = parser.parse_args()

    for var in ("SERVICENOW_INSTANCE_URL", "SERVICENOW_USERNAME", "SERVICENOW_PASSWORD"):
        if not os.environ.get(var):
            print(f"ERROR: {var} environment variable is not set", file=sys.stderr)
            return 1

    configure_session()
    ip_overrides = load_ip_overrides(args.ip_file)

    with open(CI_DEFS_PATH) as f:
        defs = yaml.safe_load(f)

    # --- Business service ---
    bs = defs["business_service"]
    print(f"\nBusiness service: {bs['name']}")
    bs_data = {
        "name": bs["name"],
        "sys_class_name": bs["ci_class"],
        "description": bs["description"],
        **bs.get("attributes", {}),
    }
    bs_sys_id = create_or_update(bs["ci_class"], bs["name"], bs["ci_class"], bs_data)

    # --- Component CIs ---
    ci_sys_ids = {"business_service": bs_sys_id}
    print(f"\nComponent CIs:")
    for comp in defs["components"]:
        attrs = dict(comp.get("attributes", {}))
        tf_key = IP_KEY_MAP.get(comp["name"])
        if tf_key and tf_key in ip_overrides:
            attrs["ip_address"] = ip_overrides[tf_key]

        ci_data = {
            "name": comp["name"],
            "sys_class_name": comp["ci_class"],
            "description": comp["description"],
            **attrs,
        }
        sid = create_or_update("cmdb_ci", comp["name"], comp["ci_class"], ci_data)
        ci_sys_ids[comp["name"]] = sid

    # --- Relationships ---
    print(f"\nRelationships:")
    for rel in defs["relationships"]:
        parent_id = ci_sys_ids.get(rel["parent"])
        child_id = ci_sys_ids.get(rel["child"])
        if not parent_id:
            print(f"  WARNING: parent '{rel['parent']}' not found, skipping")
            continue
        if not child_id:
            print(f"  WARNING: child '{rel['child']}' not found, skipping")
            continue
        create_relationship(parent_id, child_id, rel["type"])

    print(f"\nCMDB setup complete. {len(ci_sys_ids)} CIs created/verified.")
    print("\nSys IDs:")
    for name, sid in ci_sys_ids.items():
        print(f"  {name}: {sid}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
