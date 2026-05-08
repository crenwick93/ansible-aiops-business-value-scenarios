#!/usr/bin/env python3
import argparse
import json
import random
import string
import sys
import time
import urllib.error
import urllib.request

FEE_CHOICES = [
    "fee.standard.adult",
    "fee.standard.child",
    "fee.priority.adult",
    "fee.priority.child",
]
FEE_WEIGHTS = [50, 20, 20, 10]

BACKOFF_S = 2.0


def random_citizen_ref() -> str:
    suffix = "".join(
        random.choices(string.ascii_uppercase + string.digits, k=6)
    )
    return f"CIT-{suffix}"


def post_pay(base_url: str) -> None:
    fee = random.choices(FEE_CHOICES, weights=FEE_WEIGHTS, k=1)[0]
    body = {
        "citizen_ref": random_citizen_ref(),
        "fee_type": fee,
    }
    data = json.dumps(body).encode("utf-8")
    url = base_url.rstrip("/") + "/pay"
    req = urllib.request.Request(
        url,
        data=data,
        method="POST",
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
            print(
                f"POST {url} {body!s} -> {resp.status} {raw}",
                flush=True,
            )
    except urllib.error.HTTPError as e:
        err_body = e.read().decode("utf-8", errors="replace")
        print(
            f"POST {url} {body!s} -> HTTP {e.code} {e.reason!s} {err_body}",
            file=sys.stderr,
            flush=True,
        )
    except (urllib.error.URLError, OSError) as e:
        print(
            f"POST {url} failed: {type(e).__name__}: {e}",
            file=sys.stderr,
            flush=True,
        )
        time.sleep(BACKOFF_S)


def main() -> int:
    p = argparse.ArgumentParser(description="Send synthetic /pay traffic to the payment service.")
    p.add_argument(
        "--target-url",
        required=True,
        help="Base URL of the payment service (e.g. http://10.0.1.5:5000)",
    )
    p.add_argument(
        "--interval",
        type=float,
        default=3.0,
        help="Seconds between requests (default: 3)",
    )
    args = p.parse_args()
    base = args.target_url
    try:
        while True:
            post_pay(base)
            time.sleep(args.interval)
    except KeyboardInterrupt:
        print("Stopped.", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
