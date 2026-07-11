#!/usr/bin/env python3
"""Preview-first Cospend expense client for a least-privilege bot account."""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import hashlib
import json
import os
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from decimal import Decimal, InvalidOperation, ROUND_DOWN
from typing import Any

DEFAULT_BASE_URL = "https://cloud.vaz.one"
KEYCHAIN_ACCOUNT = "cospend-bot@cloud.vaz.one"
KEYCHAIN_SERVICE = "omp-cospend-api"
IDEMPOTENCY_PREFIX = "cospendctl:"
CENT = Decimal("0.01")


class CospendError(RuntimeError):
    pass


def normalize_text(value: str) -> str:
    return " ".join(value.casefold().split())


def parse_amount(raw: str) -> Decimal:
    try:
        value = Decimal(raw)
    except InvalidOperation as exc:
        raise CospendError(f"Invalid amount: {raw}") from exc
    if not value.is_finite() or value <= 0:
        raise CospendError("Amount must be a positive finite number")
    if value != value.quantize(CENT):
        raise CospendError("Amount must have at most two decimal places")
    return value


def canonical_token(record: dict[str, Any]) -> str:
    canonical = {
        "project": record["project"],
        "date": record["date"],
        "description": normalize_text(record["description"]),
        "amount": format(record["amount"], ".2f"),
        "payer_id": int(record["payer_id"]),
        "ower_ids": sorted(int(value) for value in record["ower_ids"]),
        "category_id": int(record["category_id"]),
        "payment_mode_id": int(record["payment_mode_id"]),
        "user_comment": record.get("user_comment", "").strip(),
    }
    encoded = json.dumps(canonical, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()[:20]


def split_amount(amount: Decimal, members: list[dict[str, Any]]) -> list[Decimal]:
    weights = [Decimal(str(member["weight"])) for member in members]
    total_weight = sum(weights, Decimal("0"))
    if total_weight <= 0:
        raise CospendError("Selected members have no positive split weight")
    shares: list[Decimal] = []
    allocated = Decimal("0")
    for index, weight in enumerate(weights):
        if index == len(weights) - 1:
            share = amount - allocated
        else:
            share = (amount * weight / total_weight).quantize(CENT, rounding=ROUND_DOWN)
            allocated += share
        shares.append(share)
    return shares


def bill_matches(bill: dict[str, Any], record: dict[str, Any]) -> bool:
    try:
        bill_amount = Decimal(str(bill["amount"])).quantize(CENT)
    except (InvalidOperation, KeyError):
        return False
    return (
        normalize_text(str(bill.get("what", ""))) == normalize_text(record["description"])
        and str(bill.get("date", "")) == record["date"]
        and bill_amount == record["amount"]
        and int(bill.get("payer_id", -1)) == int(record["payer_id"])
        and sorted(int(value) for value in bill.get("owerIds", []))
        == sorted(int(value) for value in record["ower_ids"])
    )


def find_existing_bill(
    bills: list[dict[str, Any]], record: dict[str, Any], token: str
) -> tuple[str, dict[str, Any]] | None:
    marker = f"[{IDEMPOTENCY_PREFIX}{token}]"
    for bill in bills:
        if marker in str(bill.get("comment", "")):
            return "same-request", bill
        if bill_matches(bill, record):
            return "duplicate", bill
    return None


def keychain_password(account: str, service: str) -> str:
    security = "/usr/bin/security"
    if not os.path.exists(security):
        raise CospendError("macOS Keychain is required")
    result = subprocess.run(
        [security, "find-generic-password", "-w", "-a", account, "-s", service],
        text=True,
        capture_output=True,
    )
    if result.returncode != 0:
        raise CospendError(
            f"Credential not found in Keychain (account={account}, service={service})"
        )
    return result.stdout.rstrip("\n")


class RejectRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, file_pointer, code, message, headers, new_url):
        return None


class CospendClient:
    def __init__(self, base_url: str, username: str, password: str) -> None:
        self.base_url = base_url.rstrip("/")
        credentials = base64.b64encode(f"{username}:{password}".encode()).decode()
        self.headers = {
            "Authorization": f"Basic {credentials}",
            "OCS-APIRequest": "true",
            "Accept": "application/json",
        }
        self.opener = urllib.request.build_opener(RejectRedirects())

    def request(
        self, method: str, path: str, payload: dict[str, Any] | None = None
    ) -> Any:
        separator = "&" if "?" in path else "?"
        url = (
            f"{self.base_url}/ocs/v2.php/apps/cospend/api/v1{path}"
            f"{separator}format=json"
        )
        body = None
        headers = dict(self.headers)
        if payload is not None:
            body = json.dumps(payload, separators=(",", ":")).encode()
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(url, data=body, headers=headers, method=method)
        try:
            with self.opener.open(request, timeout=20) as response:
                raw = response.read()
        except urllib.error.HTTPError as exc:
            raise CospendError(f"Cospend HTTP {exc.code}") from exc
        except urllib.error.URLError as exc:
            raise CospendError("Cospend network error") from exc
        try:
            decoded = json.loads(raw)
            ocs = decoded["ocs"]
            meta = ocs["meta"]
        except (json.JSONDecodeError, KeyError, TypeError) as exc:
            raise CospendError("Invalid Cospend API response") from exc
        if int(meta.get("statuscode", 500)) >= 400:
            raise CospendError(f"Cospend OCS {meta.get('statuscode')}")
        return ocs["data"]

    def projects(self) -> list[dict[str, Any]]:
        return self.request("GET", "/projects")

    def recent_bills(self, project_id: str) -> list[dict[str, Any]]:
        quoted = urllib.parse.quote(project_id, safe="")
        offset = 0
        collected: list[dict[str, Any]] = []
        seen_ids: set[int] = set()
        while True:
            data = self.request(
                "GET",
                f"/projects/{quoted}/bills?offset={offset}&limit=100&reverse=true",
            )
            if (
                not isinstance(data, dict)
                or not isinstance(data.get("bills"), list)
                or not isinstance(data.get("nb_bills"), int)
            ):
                raise CospendError("Invalid Cospend bills response")
            page = data["bills"]
            previous_count = len(collected)
            for bill in page:
                if not isinstance(bill, dict) or not isinstance(bill.get("id"), int):
                    raise CospendError("Invalid Cospend bill entry")
                if bill["id"] not in seen_ids:
                    seen_ids.add(bill["id"])
                    collected.append(bill)
            if len(collected) >= data["nb_bills"]:
                return collected
            if not page:
                raise CospendError("Cospend bill pagination ended early")
            if len(collected) == previous_count:
                raise CospendError("Cospend bill pagination made no progress")
            offset += len(page)

    def create_bill(self, project_id: str, payload: dict[str, Any]) -> int:
        quoted = urllib.parse.quote(project_id, safe="")
        return int(self.request("POST", f"/projects/{quoted}/bills", payload))

    def bill(self, project_id: str, bill_id: int) -> dict[str, Any]:
        quoted = urllib.parse.quote(project_id, safe="")
        return self.request("GET", f"/projects/{quoted}/bills/{bill_id}")


def values(collection: Any) -> list[dict[str, Any]]:
    if isinstance(collection, dict):
        return list(collection.values())
    if isinstance(collection, list):
        return collection
    return []


def resolve_named(
    candidates: list[dict[str, Any]], query: str, kind: str
) -> dict[str, Any]:
    wanted = normalize_text(query)
    matches = [
        candidate
        for candidate in candidates
        if wanted
        in {
            normalize_text(str(candidate.get("name", ""))),
            normalize_text(str(candidate.get("userid", ""))),
        }
    ]
    if len(matches) != 1:
        available = ", ".join(str(candidate.get("name")) for candidate in candidates)
        raise CospendError(
            f"Could not resolve one {kind} named {query!r}. Available: {available}"
        )
    return matches[0]


def resolve_optional(
    candidates: list[dict[str, Any]], query: str | None, kind: str
) -> int:
    if query is None:
        return 0
    return int(resolve_named(candidates, query, kind)["id"])


def choose_project(projects: list[dict[str, Any]], requested: str | None) -> dict[str, Any]:
    if requested:
        matches = [
            project
            for project in projects
            if requested in {str(project.get("id")), str(project.get("name"))}
        ]
        if len(matches) != 1:
            raise CospendError(f"Project not found or ambiguous: {requested}")
        return matches[0]
    if len(projects) != 1:
        raise CospendError(
            f"Bot must see exactly one project, but API returned {len(projects)}"
        )
    return projects[0]


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Preview and safely add one Cospend expense"
    )
    parser.add_argument("--description", required=True)
    parser.add_argument("--amount", required=True)
    parser.add_argument("--date", required=True, help="YYYY-MM-DD")
    parser.add_argument("--payer", required=True, help="Exact member name or user ID")
    parser.add_argument(
        "--for",
        dest="owers",
        required=True,
        action="append",
        help="Exact member name or user ID; repeat for each participant",
    )
    parser.add_argument("--category")
    parser.add_argument("--payment-mode")
    parser.add_argument("--comment", default="")
    parser.add_argument("--project")
    parser.add_argument("--commit", metavar="PREVIEW_TOKEN")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        amount = parse_amount(args.amount)
        try:
            date = dt.date.fromisoformat(args.date).isoformat()
        except ValueError as exc:
            raise CospendError("Date must be a real ISO date (YYYY-MM-DD)") from exc
        description = " ".join(args.description.split())
        if not description:
            raise CospendError("Description must not be empty")

        password = keychain_password(KEYCHAIN_ACCOUNT, KEYCHAIN_SERVICE)
        client = CospendClient(DEFAULT_BASE_URL, "cospend-bot", password)
        project = choose_project(client.projects(), args.project)
        if int(project.get("myaccesslevel", 0)) != 2:
            raise CospendError(
                "Bot access must be exactly Participant (2); refusing broader or narrower access"
            )

        active_members = [
            member for member in project.get("members", []) if member.get("activated")
        ]
        if {member.get("userid") for member in active_members} != {"carlos", "mafalda"}:
            raise CospendError(
                "Expected exactly active financial members carlos and mafalda"
            )
        payer = resolve_named(active_members, args.payer, "payer")
        selected: list[dict[str, Any]] = []
        for query in args.owers:
            member = resolve_named(active_members, query, "participant")
            if member["id"] not in {item["id"] for item in selected}:
                selected.append(member)
        if not selected:
            raise CospendError("At least one participant is required")

        category_id = resolve_optional(
            values(project.get("categories")), args.category, "category"
        )
        payment_mode_id = resolve_optional(
            values(project.get("paymentmodes")), args.payment_mode, "payment mode"
        )
        record = {
            "project": project["id"],
            "date": date,
            "description": description,
            "amount": amount,
            "payer_id": int(payer["id"]),
            "ower_ids": sorted(int(member["id"]) for member in selected),
            "category_id": category_id,
            "payment_mode_id": payment_mode_id,
            "user_comment": args.comment,
        }
        token = canonical_token(record)
        marker = f"[{IDEMPOTENCY_PREFIX}{token}]"
        comment = " ".join(part for part in [args.comment.strip(), marker] if part)
        shares = split_amount(amount, selected)
        if len(shares) != len(selected):
            raise CospendError("Internal split/member length mismatch")
        preview = {
            "status": "preview" if args.commit is None else "ready-to-commit",
            "confirmation_token": token,
            "project": project["name"],
            "date": date,
            "description": description,
            "amount": format(amount, ".2f"),
            "payer": payer["name"],
            "split": [
                {"member": member["name"], "amount": format(share, ".2f")}
                for member, share in zip(selected, shares)
            ],
            "category": args.category,
            "payment_mode": args.payment_mode,
            "comment": args.comment or None,
        }

        existing = find_existing_bill(client.recent_bills(project["id"]), record, token)
        if existing:
            kind, bill = existing
            if kind == "same-request":
                print(json.dumps({"status": "already-committed", "bill_id": bill["id"]}))
                return 0
            raise CospendError(
                f"Duplicate guard: matching bill already exists (id={bill['id']})"
            )

        if args.commit is None:
            print(json.dumps(preview, indent=2, ensure_ascii=False))
            return 0
        if args.commit != token:
            raise CospendError("Commit token does not match the current canonical payload")

        payload = {
            "date": date,
            "what": description,
            "payer": int(payer["id"]),
            "payedFor": ",".join(str(member_id) for member_id in record["ower_ids"]),
            "amount": float(amount),
            "repeat": "n",
            "repeatAllActive": 0,
            "categoryId": category_id,
            "paymentModeId": payment_mode_id,
            "comment": comment,
        }
        try:
            bill_id = client.create_bill(project["id"], payload)
        except CospendError:
            recovered = find_existing_bill(
                client.recent_bills(project["id"]), record, token
            )
            if recovered and recovered[0] == "same-request":
                print(
                    json.dumps(
                        {
                            "status": "committed-after-ambiguous-response",
                            "bill_id": recovered[1]["id"],
                        }
                    )
                )
                return 0
            raise
        created = client.bill(project["id"], bill_id)
        if not bill_matches(created, record) or marker not in str(created.get("comment", "")):
            raise CospendError(f"Created bill {bill_id} failed post-write verification")
        print(json.dumps({"status": "committed", "bill_id": bill_id}))
        return 0
    except CospendError as exc:
        print(f"cospendctl: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
