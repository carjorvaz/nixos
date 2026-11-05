#!/usr/bin/env python3
"""Preview-first Cospend client for a least-privilege expense bot.

Expenses (add/edit), balance reports, and category listing/copying are all
preview-first. Category commits fail closed unless the bot holds temporary
Maintainer access; the permanent bot contract stays Participant.
"""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import hashlib
import json
import os
import re
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
ACCESS_LEVEL_PARTICIPANT = 2
ACCESS_LEVEL_MAINTAINER = 3


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


def canonical_payload(record: dict[str, Any]) -> dict[str, Any]:
    return {
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


def canonical_token(record: dict[str, Any]) -> str:
    encoded = json.dumps(
        canonical_payload(record), sort_keys=True, separators=(",", ":")
    ).encode()
    return hashlib.sha256(encoded).hexdigest()[:20]


def strip_idempotency_markers(comment: str) -> str:
    pattern = rf"\[{re.escape(IDEMPOTENCY_PREFIX)}[0-9a-f]+\]"
    return re.sub(pattern, "", comment).strip()


def bill_record(project_id: str, bill: dict[str, Any]) -> dict[str, Any]:
    """Normalize a stored bill to the same shape as an add record."""
    try:
        amount = Decimal(str(bill["amount"])).quantize(CENT)
        payer_id = int(bill["payer_id"])
    except (InvalidOperation, KeyError, TypeError, ValueError) as exc:
        raise CospendError(f"Bill {bill.get('id')} is malformed") from exc
    if bill.get("ower_amounts") or bill.get("owerAmounts"):
        raise CospendError(
            f"Bill {bill.get('id')} uses custom ower amounts; edit is unsupported"
        )
    ower_ids = [int(value) for value in (bill.get("owerIds") or [])]
    if not ower_ids:
        ower_ids = [int(ower["id"]) for ower in bill.get("owers", [])]
    if not ower_ids:
        raise CospendError(f"Bill {bill.get('id')} has no participants")
    return {
        "project": project_id,
        "date": str(bill.get("date") or ""),
        "description": str(bill.get("what") or ""),
        "amount": amount,
        "payer_id": payer_id,
        "ower_ids": sorted(ower_ids),
        "category_id": int(bill.get("categoryid", bill.get("category_id", 0)) or 0),
        "payment_mode_id": int(
            bill.get("paymentmodeid", bill.get("payment_mode_id", 0)) or 0
        ),
        "user_comment": strip_idempotency_markers(str(bill.get("comment") or "")),
    }


def edit_token(bill_id: int, before: dict[str, Any], after: dict[str, Any]) -> str:
    payload = {
        "bill_id": int(bill_id),
        "before": canonical_payload(before),
        "after": canonical_payload(after),
    }
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()[:20]


def changed_fields(before: dict[str, Any], after: dict[str, Any]) -> list[str]:
    labels = (
        ("date", "date"),
        ("description", "description"),
        ("amount", "amount"),
        ("payer_id", "payer"),
        ("ower_ids", "participants"),
        ("category_id", "category"),
        ("payment_mode_id", "payment_mode"),
        ("user_comment", "comment"),
    )
    old, new = canonical_payload(before), canonical_payload(after)
    return [label for key, label in labels if old[key] != new[key]]


def parse_date(raw: str) -> str:
    try:
        return dt.date.fromisoformat(raw).isoformat()
    except (TypeError, ValueError) as exc:
        raise CospendError("Date must be a real ISO date (YYYY-MM-DD)") from exc


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


def bill_cents(bill: dict[str, Any]) -> int:
    return int(Decimal(str(bill["amount"])).quantize(CENT) * 100)


def bill_ower_cents(
    bill: dict[str, Any], members: dict[int, dict[str, Any]]
) -> dict[int, int]:
    """Owed cents per member id for one bill (custom amounts or weighted split)."""
    custom = bill.get("ower_amounts") or bill.get("owerAmounts")
    if custom:
        owed: dict[int, int] = {}
        for entry in custom:
            ower_id = int(entry.get("ower_id", entry.get("owerId")))
            if ower_id not in members:
                raise CospendError(
                    f"Bill {bill.get('id')} references unknown custom ower {ower_id}"
                )
            owed[ower_id] = owed.get(ower_id, 0) + int(
                Decimal(str(entry["amount"])).quantize(CENT) * 100
            )
        return owed
    ower_ids = [int(value) for value in (bill.get("owerIds") or [])]
    if not ower_ids:
        ower_ids = [int(ower["id"]) for ower in bill.get("owers", [])]
    if not ower_ids:
        return {}
    weights: list[Decimal] = []
    for ower_id in ower_ids:
        if ower_id not in members:
            raise CospendError(f"Bill {bill.get('id')} references unknown ower {ower_id}")
        weight = Decimal(str(members[ower_id].get("weight", 1)))
        if weight <= 0:
            raise CospendError(
                f"Bill {bill.get('id')} has non-positive split weight for member {ower_id}"
            )
        weights.append(weight)
    total_weight = sum(weights, Decimal("0"))
    total = bill_cents(bill)
    owed = {}
    allocated = 0
    for index, ower_id in enumerate(ower_ids):
        if index == len(ower_ids) - 1:
            share = total - allocated
        else:
            share = int(Decimal(total) * weights[index] / total_weight)
            allocated += share
        owed[ower_id] = owed.get(ower_id, 0) + share
    return owed


def compute_balances(
    members: dict[int, dict[str, Any]], bills: list[dict[str, Any]]
) -> dict[int, int]:
    """Reconstruct every member balance in cents from raw bills (paid minus owed)."""
    balances = {member_id: 0 for member_id in members}
    for bill in bills:
        payer_id = int(bill["payer_id"])
        if payer_id not in balances:
            raise CospendError(f"Bill {bill.get('id')} has unknown payer {payer_id}")
        balances[payer_id] += bill_cents(bill)
        for ower_id, cents in bill_ower_cents(bill, members).items():
            balances[ower_id] -= cents
    return balances


def settlement_plan(balances: dict[int, int]) -> list[tuple[int, int, int]]:
    """Greedy debtor-creditor matching; caller must ensure balances sum to zero."""
    debtors = sorted(
        ((member_id, cents) for member_id, cents in balances.items() if cents < 0),
        key=lambda item: (item[1], item[0]),
    )
    creditors = sorted(
        ((member_id, cents) for member_id, cents in balances.items() if cents > 0),
        key=lambda item: (-item[1], item[0]),
    )
    plan: list[tuple[int, int, int]] = []
    debtor_index = creditor_index = 0
    while debtor_index < len(debtors) and creditor_index < len(creditors):
        debtor_id, debtor_cents = debtors[debtor_index]
        creditor_id, creditor_cents = creditors[creditor_index]
        transfer = min(-debtor_cents, creditor_cents)
        plan.append((debtor_id, creditor_id, transfer))
        debtor_cents += transfer
        creditor_cents -= transfer
        if debtor_cents == 0:
            debtor_index += 1
        else:
            debtors[debtor_index] = (debtor_id, debtor_cents)
        if creditor_cents == 0:
            creditor_index += 1
        else:
            creditors[creditor_index] = (creditor_id, creditor_cents)
    return plan


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

    def create_category(self, project_id: str, payload: dict[str, Any]) -> int:
        quoted = urllib.parse.quote(project_id, safe="")
        return int(self.request("POST", f"/projects/{quoted}/category", payload))

    def update_bill(
        self, project_id: str, bill_id: int, payload: dict[str, Any]
    ) -> int:
        quoted = urllib.parse.quote(project_id, safe="")
        return int(
            self.request(
                "PUT", f"/projects/{quoted}/bills/{int(bill_id)}", payload
            )
        )

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


def project_access_level(project: dict[str, Any]) -> int:
    return int(project.get("myaccesslevel", 0))


def project_categories(project: dict[str, Any]) -> list[dict[str, Any]]:
    """Canonical, order-stable view of a project's categories."""
    categories: list[dict[str, Any]] = []
    for category in values(project.get("categories")):
        try:
            category_id = int(category["id"])
        except (KeyError, TypeError, ValueError) as exc:
            raise CospendError("Project category entry is malformed") from exc
        categories.append(
            {
                "id": category_id,
                "name": str(category.get("name") or ""),
                "icon": category.get("icon"),
                "color": category.get("color"),
                "order": int(category.get("order") or 0),
            }
        )
    return sorted(categories, key=lambda category: (category["order"], category["id"]))


def category_pair(category: dict[str, Any]) -> tuple[str, str]:
    """Display fields that must match for two categories to be equivalent."""
    icon = "" if category.get("icon") is None else str(category["icon"])
    color = "" if category.get("color") is None else str(category["color"]).casefold()
    return (icon, color)


def categories_by_name(
    categories: list[dict[str, Any]], kind: str
) -> dict[str, dict[str, Any]]:
    indexed: dict[str, dict[str, Any]] = {}
    for category in categories:
        key = normalize_text(category["name"])
        if key in indexed:
            raise CospendError(
                f"{kind.capitalize()} project has duplicate category name "
                f"{category['name']!r}; refusing ambiguous copy"
            )
        indexed[key] = category
    return indexed


def category_diff(
    source_categories: list[dict[str, Any]],
    target_categories: list[dict[str, Any]],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], list[dict[str, Any]]]:
    """Return (additions, conflicts, target extras); never edits or deletes."""
    source = categories_by_name(source_categories, "source")
    target = categories_by_name(target_categories, "target")
    additions = [
        category
        for category in source_categories
        if normalize_text(category["name"]) not in target
    ]
    conflicts = [
        {
            "name": source[key]["name"],
            "source": category_pair(source[key]),
            "target": category_pair(target[key]),
        }
        for key in source
        if key in target and category_pair(source[key]) != category_pair(target[key])
    ]
    extras = [
        category
        for category in target_categories
        if normalize_text(category["name"]) not in source
    ]
    return additions, conflicts, extras


def categories_token(
    target_project_id: str,
    source_project_id: str,
    additions: list[dict[str, Any]],
) -> str:
    payload = {
        "target": target_project_id,
        "source": source_project_id,
        "additions": [
            [normalize_text(category["name"]), category_pair(category), category["order"]]
            for category in additions
        ],
    }
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()[:20]


def ensure_categories_readable(project: dict[str, Any]) -> None:
    level = project_access_level(project)
    if level not in (ACCESS_LEVEL_PARTICIPANT, ACCESS_LEVEL_MAINTAINER):
        raise CospendError(
            "Category operations require bot access Participant (2) or Maintainer "
            f"(3); project has {level}"
        )


def ensure_categories_writable(project: dict[str, Any]) -> None:
    level = project_access_level(project)
    if level != ACCESS_LEVEL_MAINTAINER:
        raise CospendError(
            "Category changes require bot access exactly Maintainer (3); "
            f"project has {level}. Temporarily raise the cospend-bot share to "
            "Maintainer, re-run the commit, then revert it to Participant"
        )


def check_bot_contract(project: dict[str, Any]) -> list[dict[str, Any]]:
    if project_access_level(project) != ACCESS_LEVEL_PARTICIPANT:
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
    return active_members


def connect(
    args: argparse.Namespace,
) -> tuple[CospendClient, list[dict[str, Any]], dict[str, Any]]:
    password = keychain_password(KEYCHAIN_ACCOUNT, KEYCHAIN_SERVICE)
    client = CospendClient(DEFAULT_BASE_URL, "cospend-bot", password)
    projects = client.projects()
    return client, projects, choose_project(projects, args.project)


def record_view(
    record: dict[str, Any], members_by_id: dict[int, dict[str, Any]]
) -> dict[str, Any]:
    missing = {
        member_id
        for member_id in [record["payer_id"], *record["ower_ids"]]
        if member_id not in members_by_id
    }
    if missing:
        raise CospendError(f"Bill references unknown members: {sorted(missing)}")
    selected = [members_by_id[member_id] for member_id in record["ower_ids"]]
    shares = split_amount(record["amount"], selected)
    return {
        "date": record["date"],
        "description": record["description"],
        "amount": format(record["amount"], ".2f"),
        "payer": members_by_id[record["payer_id"]]["name"],
        "split": [
            {"member": member["name"], "amount": format(share, ".2f")}
            for member, share in zip(selected, shares)
        ],
        "comment": record["user_comment"] or None,
    }


def run_balance(args: argparse.Namespace) -> int:
    client, _, project = connect(args)
    check_bot_contract(project)
    members_by_id = {int(member["id"]): member for member in project.get("members", [])}
    bills = client.recent_bills(project["id"])
    balances = compute_balances(members_by_id, bills)
    total = sum(balances.values())

    paid: dict[int, int] = {}
    counts: dict[int, int] = {}
    dates = [str(bill["date"]) for bill in bills if bill.get("date")]
    for bill in bills:
        payer_id = int(bill["payer_id"])
        paid[payer_id] = paid.get(payer_id, 0) + bill_cents(bill)
        counts[payer_id] = counts.get(payer_id, 0) + 1

    def money(cents: int) -> str:
        return format(Decimal(cents) / 100, ".2f")

    def name(member_id: int) -> str:
        return str(members_by_id.get(member_id, {}).get("name", f"id:{member_id}"))

    plan = settlement_plan(balances) if total == 0 else None
    report = {
        "status": "balance",
        "project": project["name"],
        "project_id": project["id"],
        "bills_counted": len(bills),
        "date_range": [min(dates), max(dates)] if dates else None,
        "paid_totals": [
            {
                "member": name(member_id),
                "bills_as_payer": counts.get(member_id, 0),
                "amount": money(paid.get(member_id, 0)),
            }
            for member_id in sorted(members_by_id)
        ],
        "balances": [
            {"member": name(member_id), "balance": money(balances[member_id])}
            for member_id in sorted(members_by_id)
        ],
        "sum_check": money(total),
        "books_balanced": total == 0,
        "suggested_transfers": (
            [
                {
                    "from": name(debtor_id),
                    "to": name(creditor_id),
                    "amount": money(cents),
                }
                for debtor_id, creditor_id, cents in plan
            ]
            if plan is not None
            else None
        ),
    }
    print(json.dumps(report, indent=2, ensure_ascii=False))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Preview-first Cospend client: add or edit one expense, report "
            "balances, or inspect/copy project categories"
        )
    )
    parser.add_argument(
        "mode",
        nargs="?",
        choices=("add", "edit", "balance", "categories"),
        default="add",
        help=(
            "add (default): record one expense; edit: change one bill; "
            "balance: read-only who-owes-whom report; categories: list a "
            "project's categories or copy missing ones from another project"
        ),
    )
    parser.add_argument("--description")
    parser.add_argument("--amount")
    parser.add_argument("--date", help="YYYY-MM-DD")
    parser.add_argument("--payer", help="Exact member name or user ID")
    parser.add_argument(
        "--for",
        dest="owers",
        action="append",
        help=(
            "Exact member name or user ID; repeat for each participant. "
            "In edit mode the provided set replaces the current participants"
        ),
    )
    parser.add_argument("--category")
    parser.add_argument("--payment-mode")
    parser.add_argument(
        "--comment",
        default=None,
        help="Omit to keep (edit) or leave empty (add); pass an empty string to clear",
    )
    parser.add_argument("--bill", type=int, help="Bill id to edit")
    parser.add_argument(
        "--copy-from",
        metavar="PROJECT",
        help=(
            "categories mode: source project id or name. Only categories "
            "missing from the target are added; existing target categories "
            "are never edited or deleted. Preview is read-only; the commit "
            "requires temporary Maintainer access for the bot"
        ),
    )
    parser.add_argument("--project")
    parser.add_argument(
        "--commit",
        metavar="PREVIEW_TOKEN",
        help=(
            "Apply a previewed change; categories commits also require the "
            "bot to hold temporary Maintainer access"
        ),
    )
    return parser


def run_add(args: argparse.Namespace) -> int:
    missing = [
        flag
        for flag, value in (
            ("--description", args.description),
            ("--amount", args.amount),
            ("--date", args.date),
            ("--payer", args.payer),
            ("--for", args.owers),
        )
        if value is None
    ]
    if missing:
        raise CospendError("Add mode requires " + ", ".join(missing))
    amount = parse_amount(args.amount)
    date = parse_date(args.date)
    description = " ".join(args.description.split())
    if not description:
        raise CospendError("Description must not be empty")

    client, _, project = connect(args)
    active_members = check_bot_contract(project)
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
    user_comment = args.comment or ""
    record = {
        "project": project["id"],
        "date": date,
        "description": description,
        "amount": amount,
        "payer_id": int(payer["id"]),
        "ower_ids": sorted(int(member["id"]) for member in selected),
        "category_id": category_id,
        "payment_mode_id": payment_mode_id,
        "user_comment": user_comment,
    }
    token = canonical_token(record)
    marker = f"[{IDEMPOTENCY_PREFIX}{token}]"
    comment = " ".join(part for part in [user_comment.strip(), marker] if part)
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
        "comment": user_comment or None,
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


def run_edit(args: argparse.Namespace) -> int:
    if args.bill is None:
        raise CospendError("Edit mode requires --bill")
    change_flags = (
        args.description,
        args.amount,
        args.date,
        args.payer,
        args.owers,
        args.category,
        args.payment_mode,
        args.comment,
    )
    if all(value is None for value in change_flags):
        raise CospendError("Edit mode requires at least one change flag")

    client, _, project = connect(args)
    active_members = check_bot_contract(project)
    members_by_id = {
        int(member["id"]): member for member in project.get("members", [])
    }
    bill = client.bill(project["id"], args.bill)
    if int(bill.get("deleted") or 0) != 0:
        raise CospendError(f"Bill {args.bill} is deleted")
    if str(bill.get("repeat") or "n") not in ("", "n"):
        raise CospendError(f"Bill {args.bill} is recurring; edit is unsupported")

    before = bill_record(project["id"], bill)
    after = dict(before)
    if args.description is not None:
        description = " ".join(args.description.split())
        if not description:
            raise CospendError("Description must not be empty")
        after["description"] = description
    if args.amount is not None:
        after["amount"] = parse_amount(args.amount)
    if args.date is not None:
        after["date"] = parse_date(args.date)
    if args.payer is not None:
        after["payer_id"] = int(
            resolve_named(active_members, args.payer, "payer")["id"]
        )
    if args.owers:
        selected: list[dict[str, Any]] = []
        for query in args.owers:
            member = resolve_named(active_members, query, "participant")
            if member["id"] not in {item["id"] for item in selected}:
                selected.append(member)
        if not selected:
            raise CospendError("At least one participant is required")
        after["ower_ids"] = sorted(int(member["id"]) for member in selected)
    if args.category is not None:
        after["category_id"] = resolve_optional(
            values(project.get("categories")), args.category, "category"
        )
    if args.payment_mode is not None:
        after["payment_mode_id"] = resolve_optional(
            values(project.get("paymentmodes")), args.payment_mode, "payment mode"
        )
    if args.comment is not None:
        after["user_comment"] = args.comment.strip()

    if canonical_payload(before) == canonical_payload(after):
        applied_marker = f"[{IDEMPOTENCY_PREFIX}{args.commit}]" if args.commit else ""
        if applied_marker and applied_marker in str(bill.get("comment") or ""):
            print(json.dumps({"status": "already-applied", "bill_id": args.bill}))
            return 0
        raise CospendError("Edit makes no changes")

    token = edit_token(args.bill, before, after)
    marker = f"[{IDEMPOTENCY_PREFIX}{token}]"
    comment = " ".join(
        part for part in [after["user_comment"].strip(), marker] if part
    )
    preview = {
        "status": "preview" if args.commit is None else "ready-to-commit",
        "confirmation_token": token,
        "project": project["name"],
        "bill_id": args.bill,
        "changed": changed_fields(before, after),
        "before": record_view(before, members_by_id),
        "after": record_view(after, members_by_id),
    }

    if args.commit is None:
        print(json.dumps(preview, indent=2, ensure_ascii=False))
        return 0
    if args.commit != token:
        raise CospendError("Commit token does not match the current canonical payload")

    current_raw = client.bill(project["id"], args.bill)
    current = bill_record(project["id"], current_raw)
    if canonical_payload(current) == canonical_payload(after) and marker in str(
        current_raw.get("comment") or ""
    ):
        print(json.dumps({"status": "already-applied", "bill_id": args.bill}))
        return 0
    if canonical_payload(current) != canonical_payload(before):
        raise CospendError("Bill changed since preview; re-run the preview")

    payload = {
        "date": after["date"],
        "what": after["description"],
        "payer": after["payer_id"],
        "payedFor": ",".join(str(member_id) for member_id in after["ower_ids"]),
        "amount": float(after["amount"]),
        "categoryId": after["category_id"],
        "paymentModeId": after["payment_mode_id"],
        "comment": comment,
    }
    try:
        updated_id = client.update_bill(project["id"], args.bill, payload)
    except CospendError:
        recovered_raw = client.bill(project["id"], args.bill)
        recovered = bill_record(project["id"], recovered_raw)
        if canonical_payload(recovered) == canonical_payload(after) and marker in str(
            recovered_raw.get("comment") or ""
        ):
            print(
                json.dumps(
                    {
                        "status": "committed-after-ambiguous-response",
                        "bill_id": args.bill,
                    }
                )
            )
            return 0
        raise
    if int(updated_id) != int(args.bill):
        raise CospendError(f"Edit returned unexpected bill id {updated_id}")
    verified_raw = client.bill(project["id"], args.bill)
    verified = bill_record(project["id"], verified_raw)
    if canonical_payload(verified) != canonical_payload(after) or marker not in str(
        verified_raw.get("comment") or ""
    ):
        raise CospendError(f"Updated bill {args.bill} failed post-write verification")
    print(json.dumps({"status": "committed", "bill_id": args.bill}))
    return 0


def run_categories(args: argparse.Namespace) -> int:
    client, projects, project = connect(args)
    ensure_categories_readable(project)
    target_categories = project_categories(project)

    if args.copy_from is None:
        if args.commit is not None:
            raise CospendError("--commit requires --copy-from")
        report = {
            "status": "categories",
            "project": project["name"],
            "project_id": project["id"],
            "access_level": project_access_level(project),
            "count": len(target_categories),
            "categories": target_categories,
        }
        print(json.dumps(report, indent=2, ensure_ascii=False))
        return 0

    source = choose_project(projects, args.copy_from)
    if source["id"] == project["id"]:
        raise CospendError("Source and target project must be different")
    source_categories = project_categories(source)
    additions, conflicts, extras = category_diff(source_categories, target_categories)
    in_sync = not additions and not conflicts
    token = categories_token(project["id"], source["id"], additions)
    preview = {
        "status": "preview" if args.commit is None else "ready-to-commit",
        "confirmation_token": token,
        "project": project["name"],
        "project_id": project["id"],
        "source_project": source["name"],
        "source_project_id": source["id"],
        "access_level": project_access_level(project),
        "in_sync": in_sync,
        "to_add": [
            {
                "name": category["name"],
                "icon": category["icon"],
                "color": category["color"],
                "order": category["order"],
            }
            for category in additions
        ],
        "conflicts": [
            {
                "name": conflict["name"],
                "source_icon": conflict["source"][0],
                "source_color": conflict["source"][1],
                "target_icon": conflict["target"][0],
                "target_color": conflict["target"][1],
            }
            for conflict in conflicts
        ],
        "extra_in_target": [category["name"] for category in extras],
    }

    if args.commit is None:
        print(json.dumps(preview, indent=2, ensure_ascii=False))
        return 0
    if in_sync:
        print(
            json.dumps(
                {
                    "status": "already-in-sync",
                    "project": project["name"],
                    "project_id": project["id"],
                    "count": len(target_categories),
                }
            )
        )
        return 0
    if conflicts:
        raise CospendError(
            "Category conflicts must be resolved manually: "
            + ", ".join(conflict["name"] for conflict in conflicts)
        )
    ensure_categories_writable(project)
    if args.commit != token:
        raise CospendError(
            "Commit token does not match the current canonical payload"
        )

    added: list[dict[str, Any]] = []
    try:
        for category in additions:
            payload = {
                "name": category["name"],
                "icon": category["icon"],
                "color": category["color"],
                "order": category["order"],
            }
            added.append(
                {
                    "id": client.create_category(project["id"], payload),
                    "name": category["name"],
                }
            )
    except CospendError:
        current = project_categories(choose_project(client.projects(), project["id"]))
        present = {normalize_text(category["name"]) for category in current}
        missing = [
            category["name"]
            for category in additions
            if normalize_text(category["name"]) not in present
        ]
        if not missing:
            print(
                json.dumps(
                    {
                        "status": "committed-after-ambiguous-response",
                        "project": project["name"],
                        "added": added,
                    }
                )
            )
            return 0
        raise CospendError(
            "Category copy interrupted; still missing: "
            + ", ".join(missing)
            + ". Re-run the preview to resume"
        )

    current = project_categories(choose_project(client.projects(), project["id"]))
    current_by_name = {
        normalize_text(category["name"]): category for category in current
    }
    broken = []
    for category in additions:
        stored = current_by_name.get(normalize_text(category["name"]))
        if (
            stored is None
            or category_pair(stored) != category_pair(category)
            or stored["order"] != category["order"]
        ):
            broken.append(category["name"])
    if broken:
        raise CospendError(
            "Post-write verification failed for: " + ", ".join(broken)
        )
    print(
        json.dumps(
            {
                "status": "committed",
                "project": project["name"],
                "project_id": project["id"],
                "added": added,
                "count": len(current),
            }
        )
    )
    return 0


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        if args.mode == "balance":
            return run_balance(args)
        if args.mode == "edit":
            return run_edit(args)
        if args.mode == "categories":
            return run_categories(args)
        return run_add(args)
    except CospendError as exc:
        print(f"cospendctl: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
