#!/usr/bin/env python3
"""Remove all AIOps demo CIs and relationships from ServiceNow.

Identifies demo records by the [aiops-demo] prefix in the description field.

Usage:
    export SERVICENOW_INSTANCE_URL=https://devXXXXXX.service-now.com
    export SERVICENOW_USERNAME=admin
    export SERVICENOW_PASSWORD=...
    python3 teardown_cmdb.py
"""

import os
import sys

import requests

DEMO_TAG = "[aiops-demo]"

session = requests.Session()


def snow_url(path: str) -> str:
    base = os.environ["SERVICENOW_INSTANCE_URL"].rstrip("/")
    return f"{base}{path}"


def configure_session() -> None:
    session.auth = (os.environ["SERVICENOW_USERNAME"], os.environ["SERVICENOW_PASSWORD"])
    session.headers.update({"Accept": "application/json", "Content-Type": "application/json"})


def find_demo_records(table: str) -> list[dict]:
    """Find all records in `table` whose description contains the demo tag."""
    query = f"descriptionLIKE{DEMO_TAG}"
    url = snow_url(f"/api/now/table/{table}?sysparm_query={query}&sysparm_limit=200")
    r = session.get(url)
    r.raise_for_status()
    return r.json().get("result", [])


def delete_record(table: str, sys_id: str, name: str) -> None:
    url = snow_url(f"/api/now/table/{table}/{sys_id}")
    r = session.delete(url)
    r.raise_for_status()
    print(f"  DELETED {table}/{name}  sys_id={sys_id}")


def main() -> int:
    for var in ("SERVICENOW_INSTANCE_URL", "SERVICENOW_USERNAME", "SERVICENOW_PASSWORD"):
        if not os.environ.get(var):
            print(f"ERROR: {var} environment variable is not set", file=sys.stderr)
            return 1

    configure_session()

    # Delete relationships first (they reference CIs that we'll delete next)
    print("\nRemoving relationships for demo CIs...")
    demo_cis = find_demo_records("cmdb_ci")
    demo_services = find_demo_records("cmdb_ci_service")
    all_demo = demo_cis + demo_services
    demo_sys_ids = {ci["sys_id"] for ci in all_demo}

    if demo_sys_ids:
        query_parts = [f"parent={sid}^ORchild={sid}" for sid in demo_sys_ids]
        # Query relationships involving any demo CI
        for sid in demo_sys_ids:
            url = snow_url(
                f"/api/now/table/cmdb_rel_ci?sysparm_query=parent={sid}^ORchild={sid}&sysparm_limit=200"
            )
            r = session.get(url)
            r.raise_for_status()
            for rel in r.json().get("result", []):
                delete_record("cmdb_rel_ci", rel["sys_id"], f"{rel.get('parent', {}).get('value', '?')}->{rel.get('child', {}).get('value', '?')}")

    # Delete component CIs
    print("\nRemoving component CIs...")
    for ci in demo_cis:
        delete_record("cmdb_ci", ci["sys_id"], ci.get("name", "unnamed"))

    # Delete business services
    print("\nRemoving business services...")
    for svc in demo_services:
        delete_record("cmdb_ci_service", svc["sys_id"], svc.get("name", "unnamed"))

    total = len(all_demo)
    print(f"\nTeardown complete. Removed {total} CI(s) and their relationships.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
