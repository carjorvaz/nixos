#!/usr/bin/env python3

import contextlib
import copy
import importlib.util
import io
import json
import unittest
from decimal import Decimal
from pathlib import Path
from unittest import mock

MODULE_PATH = Path(__file__).with_name("cospend-cli.py")
SPEC = importlib.util.spec_from_file_location("cospend_cli", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class FakeClient:
    def __init__(self):
        self.project_data = [
            {
                "id": "china-2026",
                "name": "China 2026",
                "myaccesslevel": 2,
                "members": [
                    {"id": 18, "name": "Carlos Vaz", "userid": "carlos", "weight": 1, "activated": True},
                    {"id": 19, "name": "Mafalda Ribeiro", "userid": "mafalda", "weight": 1, "activated": True},
                ],
                "categories": [],
                "paymentmodes": [],
            }
        ]
        self.bills_responses = [[]]
        self.created_bill = None
        self.create_calls = []
        self.bill_data = {}
        self.update_calls = []
        self.create_category_calls = []
        self.category_exception = None
        self.next_category_id = 900

    def projects(self):
        return self.project_data

    def recent_bills(self, project_id):
        if len(self.bills_responses) > 1:
            return self.bills_responses.pop(0)
        return self.bills_responses[0]

    def create_bill(self, project_id, payload):
        self.create_calls.append((project_id, payload))
        if isinstance(self.created_bill, Exception):
            raise self.created_bill
        return 77

    def update_bill(self, project_id, bill_id, payload):
        self.update_calls.append((project_id, bill_id, payload))
        stored = copy.deepcopy(self.bill_data.get(bill_id, self.created_bill))
        if stored is None:
            raise MODULE.CospendError(f"No bill {bill_id}")
        stored["date"] = payload["date"]
        stored["what"] = payload["what"]
        stored["payer_id"] = payload["payer"]
        stored["owerIds"] = [int(value) for value in payload["payedFor"].split(",")]
        stored["amount"] = payload["amount"]
        stored["categoryid"] = payload["categoryId"]
        stored["paymentmodeid"] = payload["paymentModeId"]
        stored["comment"] = payload["comment"]
        self.bill_data[bill_id] = stored
        return bill_id

    def bill(self, project_id, bill_id):
        if bill_id in self.bill_data:
            return self.bill_data[bill_id]
        return self.created_bill

    def create_category(self, project_id, payload):
        self.create_category_calls.append((project_id, payload))
        if isinstance(self.category_exception, Exception):
            raise self.category_exception
        project = next(
            project for project in self.project_data if project["id"] == project_id
        )
        categories = project.setdefault("categories", [])
        category_id = self.next_category_id
        self.next_category_id += 1
        entry = {
            "id": category_id,
            "name": payload["name"],
            "icon": payload.get("icon"),
            "color": payload.get("color"),
            "order": payload.get("order", 0),
        }
        if isinstance(categories, dict):
            categories[str(category_id)] = entry
        else:
            categories.append(entry)
        return category_id


class CospendCliTests(unittest.TestCase):
    ARGS = [
        "--description", "China flights",
        "--amount", "2133.48",
        "--date", "2026-07-11",
        "--payer", "carlos",
        "--for", "carlos",
        "--for", "mafalda",
    ]

    def record(self):
        return {
            "project": "china-2026",
            "date": "2026-07-11",
            "description": "China flights",
            "amount": Decimal("2133.48"),
            "payer_id": 18,
            "ower_ids": [18, 19],
            "category_id": 0,
            "payment_mode_id": 0,
            "user_comment": "",
        }

    def invoke_with(self, fake, argv):
        stdout, stderr = io.StringIO(), io.StringIO()
        with (
            mock.patch.object(MODULE, "keychain_password", return_value="secret"),
            mock.patch.object(MODULE, "CospendClient", return_value=fake),
            contextlib.redirect_stdout(stdout),
            contextlib.redirect_stderr(stderr),
        ):
            code = MODULE.main(argv)
        return code, stdout.getvalue(), stderr.getvalue()

    def invoke(self, fake, extra=None):
        return self.invoke_with(fake, self.ARGS + (extra or []))

    def matching_bill(self, token, marker=True):
        return {
            "id": 77,
            "amount": 2133.48,
            "what": "China flights",
            "date": "2026-07-11",
            "payer_id": 18,
            "owerIds": [18, 19],
            "comment": f"[{MODULE.IDEMPOTENCY_PREFIX}{token}]" if marker else "",
        }

    def test_token_is_stable_for_spacing_and_participant_order(self):
        first = self.record()
        second = self.record()
        second["description"] = "  CHINA   flights "
        second["ower_ids"] = [19, 18]
        self.assertEqual(MODULE.canonical_token(first), MODULE.canonical_token(second))

    def test_equal_split_is_exact(self):
        members = [{"weight": 1}, {"weight": 1}]
        self.assertEqual(
            MODULE.split_amount(Decimal("2133.48"), members),
            [Decimal("1066.74"), Decimal("1066.74")],
        )

    def test_weighted_split_preserves_cent_residue(self):
        shares = MODULE.split_amount(
            Decimal("10.00"), [{"weight": 1}, {"weight": 2}]
        )
        self.assertEqual(shares, [Decimal("3.33"), Decimal("6.67")])
        self.assertEqual(sum(shares), Decimal("10.00"))

    def test_bills_envelope_is_unwrapped(self):
        client = MODULE.CospendClient("https://example.invalid", "user", "pass")
        with mock.patch.object(
            client,
            "request",
            return_value={"nb_bills": 0, "bills": [], "allBillIds": [], "timestamp": 1},
        ):
            self.assertEqual(client.recent_bills("china-2026"), [])

    def test_bill_history_is_fully_paginated(self):
        client = MODULE.CospendClient("https://example.invalid", "user", "pass")
        first_page = [{"id": bill_id} for bill_id in range(1, 101)]
        second_page = [{"id": 101}]
        with mock.patch.object(
            client,
            "request",
            side_effect=[
                {"nb_bills": 101, "bills": first_page},
                {"nb_bills": 101, "bills": second_page},
            ],
        ) as request:
            bills = client.recent_bills("china-2026")
        self.assertEqual([bill["id"] for bill in bills], list(range(1, 102)))
        self.assertIn("offset=100", request.call_args_list[1].args[1])

    def test_repeated_pagination_page_fails_closed(self):
        client = MODULE.CospendClient("https://example.invalid", "user", "pass")
        page = [{"id": bill_id} for bill_id in range(1, 101)]
        with mock.patch.object(
            client,
            "request",
            side_effect=[
                {"nb_bills": 101, "bills": page},
                {"nb_bills": 101, "bills": page},
            ],
        ):
            with self.assertRaises(MODULE.CospendError):
                client.recent_bills("china-2026")

    def test_production_parser_has_no_base_url_override(self):
        self.assertNotIn(
            "--base-url", MODULE.build_parser()._option_string_actions
        )

    def test_redirects_are_rejected_before_credentials_can_be_forwarded(self):
        handler = MODULE.RejectRedirects()
        self.assertIsNone(
            handler.redirect_request(
                mock.sentinel.request,
                mock.sentinel.file_pointer,
                302,
                "Found",
                {},
                "https://attacker.invalid/",
            )
        )

    def test_ambiguous_project_and_member_names_fail_closed(self):
        projects = [{"id": "a", "name": "Same"}, {"id": "b", "name": "Same"}]
        with self.assertRaises(MODULE.CospendError):
            MODULE.choose_project(projects, "Same")
        members = [{"id": 1, "name": "Same"}, {"id": 2, "name": "Same"}]
        with self.assertRaises(MODULE.CospendError):
            MODULE.resolve_named(members, "Same", "member")

    def test_preview_never_posts(self):
        fake = FakeClient()
        code, stdout, _ = self.invoke(fake)
        self.assertEqual(code, 0)
        self.assertIn('"status": "preview"', stdout)
        self.assertEqual(fake.create_calls, [])

    def test_wrong_commit_token_never_posts(self):
        fake = FakeClient()
        code, _, stderr = self.invoke(fake, ["--commit", "wrong"])
        self.assertEqual(code, 2)
        self.assertIn("does not match", stderr)
        self.assertEqual(fake.create_calls, [])

    def test_existing_marker_returns_idempotent_success_without_post(self):
        fake = FakeClient()
        token = MODULE.canonical_token(self.record())
        fake.bills_responses = [[self.matching_bill(token)]]
        code, stdout, _ = self.invoke(fake, ["--commit", token])
        self.assertEqual(code, 0)
        self.assertIn("already-committed", stdout)
        self.assertEqual(fake.create_calls, [])

    def test_matching_bill_without_marker_is_rejected_as_duplicate(self):
        fake = FakeClient()
        token = MODULE.canonical_token(self.record())
        fake.bills_responses = [[self.matching_bill(token, marker=False)]]
        code, _, stderr = self.invoke(fake)
        self.assertEqual(code, 2)
        self.assertIn("Duplicate guard", stderr)
        self.assertEqual(fake.create_calls, [])

    def test_ambiguous_post_error_recovers_by_marker(self):
        fake = FakeClient()
        token = MODULE.canonical_token(self.record())
        fake.created_bill = MODULE.CospendError("network")
        fake.bills_responses = [[], [self.matching_bill(token)]]
        code, stdout, _ = self.invoke(fake, ["--commit", token])
        self.assertEqual(code, 0)
        self.assertIn("committed-after-ambiguous-response", stdout)
        self.assertEqual(len(fake.create_calls), 1)

    def test_post_write_response_without_marker_fails_closed(self):
        fake = FakeClient()
        token = MODULE.canonical_token(self.record())
        fake.created_bill = self.matching_bill(token, marker=False)
        code, _, stderr = self.invoke(fake, ["--commit", token])
        self.assertEqual(code, 2)
        self.assertIn("failed post-write verification", stderr)
        self.assertEqual(len(fake.create_calls), 1)

    def test_amount_rejects_fractional_cents(self):
        with self.assertRaises(MODULE.CospendError):
            MODULE.parse_amount("12.345")

    def test_add_mode_requires_expense_fields(self):
        fake = FakeClient()
        code, _, stderr = self.invoke_with(fake, [])
        self.assertEqual(code, 2)
        self.assertIn("Add mode requires", stderr)
        self.assertEqual(fake.create_calls, [])

    def test_weighted_bill_split_truncates_then_assigns_residue(self):
        members = {18: {"weight": 1}, 19: {"weight": 2}}
        bill = {"id": 1, "amount": 10.00, "payer_id": 18, "owerIds": [18, 19]}
        self.assertEqual(MODULE.bill_ower_cents(bill, members), {18: 333, 19: 667})

    def test_custom_ower_amounts_are_honoured(self):
        members = {18: {"weight": 1}, 19: {"weight": 1}}
        bill = {
            "id": 1,
            "amount": 10.00,
            "payer_id": 18,
            "owerIds": [18, 19],
            "ower_amounts": [{"ower_id": 19, "amount": "7.25"}],
        }
        self.assertEqual(MODULE.bill_ower_cents(bill, members), {19: 725})

    def test_unknown_bill_member_fails_closed(self):
        members = {18: {"weight": 1}}
        bill = {"id": 1, "amount": 10.00, "payer_id": 18, "owerIds": [99]}
        with self.assertRaises(MODULE.CospendError):
            MODULE.bill_ower_cents(bill, members)

    def test_balance_computation_matches_paid_minus_owed(self):
        members = {
            18: {"id": 18, "name": "Carlos Vaz", "weight": 1},
            19: {"id": 19, "name": "Mafalda Ribeiro", "weight": 1},
        }
        bills = [
            {"id": 1, "amount": 100.00, "payer_id": 18, "owerIds": [18, 19]},
            {"id": 2, "amount": 372.00, "payer_id": 19, "owerIds": [18, 19]},
        ]
        balances = MODULE.compute_balances(members, bills)
        self.assertEqual(balances, {18: -13600, 19: 13600})
        self.assertEqual(MODULE.settlement_plan(balances), [(18, 19, 13600)])

    def test_three_member_settlement_plan_matches_greedily(self):
        plan = MODULE.settlement_plan({1: -3000, 2: -1000, 3: 4000})
        self.assertEqual(plan, [(1, 3, 3000), (2, 3, 1000)])

    def test_balance_mode_is_read_only_and_reports_zeroed_books(self):
        fake = FakeClient()
        fake.bills_responses = [
            [
                {"id": 1, "amount": 720.67, "payer_id": 18, "owerIds": [19], "date": "2026-09-29"},
                {"id": 2, "amount": 720.67, "payer_id": 19, "owerIds": [18], "date": "2026-09-29"},
            ]
        ]
        code, stdout, _ = self.invoke_with(fake, ["balance", "--project", "china-2026"])
        self.assertEqual(code, 0)
        self.assertEqual(fake.create_calls, [])
        self.assertIn('"status": "balance"', stdout)
        self.assertIn('"suggested_transfers": []', stdout)
        self.assertIn('"books_balanced": true', stdout)

    def stored_bill(self):
        return {
            "id": 217,
            "date": "2026-10-20",
            "what": "Didi",
            "amount": 1.95,
            "payer_id": 18,
            "owerIds": [18, 19],
            "comment": "Estimativa [cospendctl:aaaaaaaaaaaaaaaaaaaa]",
            "repeat": "n",
            "deleted": 0,
            "categoryid": 0,
            "paymentmodeid": 0,
        }

    def edit_invoke(self, fake, extra):
        return self.invoke_with(fake, ["edit", "--bill", "217", *extra])

    def edit_preview(self, fake, extra):
        code, stdout, stderr = self.edit_invoke(fake, extra)
        self.assertEqual(code, 0, stderr)
        return json.loads(stdout)

    def test_edit_preview_shows_before_and_after_without_put(self):
        fake = FakeClient()
        fake.bill_data[217] = self.stored_bill()
        preview = self.edit_preview(fake, ["--amount", "1.94"])
        self.assertEqual(preview["status"], "preview")
        self.assertEqual(preview["before"]["amount"], "1.95")
        self.assertEqual(preview["after"]["amount"], "1.94")
        self.assertEqual(preview["changed"], ["amount"])
        self.assertEqual(fake.update_calls, [])
        self.assertEqual(fake.bill_data[217]["amount"], 1.95)

    def test_edit_commit_updates_bill_and_replaces_marker(self):
        fake = FakeClient()
        fake.bill_data[217] = self.stored_bill()
        token = self.edit_preview(fake, ["--amount", "1.94"])[
            "confirmation_token"
        ]
        code, stdout, stderr = self.edit_invoke(
            fake, ["--amount", "1.94", "--commit", token]
        )
        self.assertEqual(code, 0, stderr)
        self.assertIn('"status": "committed"', stdout)
        payload = fake.update_calls[0][2]
        self.assertEqual(payload["amount"], 1.94)
        self.assertIn(f"[{MODULE.IDEMPOTENCY_PREFIX}{token}]", payload["comment"])
        self.assertNotIn("aaaaaaaaaaaaaaaaaaaa", payload["comment"])
        self.assertEqual(fake.bill_data[217]["amount"], 1.94)
        self.assertEqual(fake.bill_data[217]["owerIds"], [18, 19])

    def test_edit_wrong_commit_token_never_puts(self):
        fake = FakeClient()
        fake.bill_data[217] = self.stored_bill()
        code, _, stderr = self.edit_invoke(
            fake, ["--amount", "1.94", "--commit", "wrong"]
        )
        self.assertEqual(code, 2)
        self.assertIn("does not match", stderr)
        self.assertEqual(fake.update_calls, [])

    def test_edit_after_external_change_fails_closed(self):
        fake = FakeClient()
        fake.bill_data[217] = self.stored_bill()
        token = self.edit_preview(fake, ["--amount", "1.94"])[
            "confirmation_token"
        ]
        fake.bill_data[217]["amount"] = 2.00
        code, _, stderr = self.edit_invoke(
            fake, ["--amount", "1.94", "--commit", token]
        )
        self.assertEqual(code, 2)
        self.assertIn("does not match", stderr)
        self.assertEqual(fake.update_calls, [])

    def test_edit_retry_after_success_reports_already_applied(self):
        fake = FakeClient()
        fake.bill_data[217] = self.stored_bill()
        token = self.edit_preview(fake, ["--amount", "1.94"])[
            "confirmation_token"
        ]
        args = ["--amount", "1.94", "--commit", token]
        code, _, _ = self.edit_invoke(fake, args)
        self.assertEqual(code, 0)
        code, stdout, _ = self.edit_invoke(fake, args)
        self.assertEqual(code, 0)
        self.assertIn('"status": "already-applied"', stdout)
        self.assertEqual(len(fake.update_calls), 1)

    def test_edit_noop_is_rejected(self):
        fake = FakeClient()
        fake.bill_data[217] = self.stored_bill()
        code, _, stderr = self.edit_invoke(fake, ["--amount", "1.95"])
        self.assertEqual(code, 2)
        self.assertIn("no changes", stderr)

    def test_edit_rejects_custom_ower_amounts(self):
        fake = FakeClient()
        bill = self.stored_bill()
        bill["ower_amounts"] = [{"ower_id": 19, "amount": "1.00"}]
        fake.bill_data[217] = bill
        code, _, stderr = self.edit_invoke(fake, ["--amount", "1.94"])
        self.assertEqual(code, 2)
        self.assertIn("custom ower amounts", stderr)
        self.assertEqual(fake.update_calls, [])

    def test_edit_requires_bill_and_a_change_flag(self):
        fake = FakeClient()
        code, _, stderr = self.invoke_with(fake, ["edit"])
        self.assertEqual(code, 2)
        self.assertIn("requires --bill", stderr)
        code, _, stderr = self.invoke_with(fake, ["edit", "--bill", "217"])
        self.assertEqual(code, 2)
        self.assertIn("at least one change flag", stderr)

    def test_edit_can_clear_comment(self):
        fake = FakeClient()
        fake.bill_data[217] = self.stored_bill()
        token = self.edit_preview(fake, ["--comment", ""])["confirmation_token"]
        code, _, stderr = self.edit_invoke(
            fake, ["--comment", "", "--commit", token]
        )
        self.assertEqual(code, 0, stderr)
        comment = fake.update_calls[0][2]["comment"]
        self.assertEqual(comment, f"[{MODULE.IDEMPOTENCY_PREFIX}{token}]")

    def test_unbalanced_books_omit_transfers(self):
        fake = FakeClient()
        fake.bills_responses = [
            [
                {
                    "id": 1,
                    "amount": 10.00,
                    "payer_id": 18,
                    "owerIds": [18, 19],
                    "date": "2026-09-29",
                    "ower_amounts": [{"ower_id": 19, "amount": "4.00"}],
                }
            ]
        ]
        code, stdout, _ = self.invoke_with(fake, ["balance", "--project", "china-2026"])
        self.assertEqual(code, 0)
        self.assertIn('"books_balanced": false', stdout)
        self.assertIn('"suggested_transfers": null', stdout)

    SOURCE_CATEGORIES = [
        {"id": 12, "name": "Alojamento", "icon": "🏨", "color": "#000000", "order": 0},
        {"id": 13, "name": "Transportes", "icon": "🚇", "color": "#000000", "order": 1},
        {"id": 14, "name": "Voos", "icon": "✈️", "color": "#000000", "order": 2},
    ]

    def category_project(self, project_id, name, access_level, categories):
        return {
            "id": project_id,
            "name": name,
            "myaccesslevel": access_level,
            "members": [
                {
                    "id": 18,
                    "name": "Carlos Vaz",
                    "userid": "carlos",
                    "weight": 1,
                    "activated": True,
                },
                {
                    "id": 19,
                    "name": "Mafalda Ribeiro",
                    "userid": "mafalda",
                    "weight": 1,
                    "activated": True,
                },
            ],
            "categories": copy.deepcopy(categories),
            "paymentmodes": [],
        }

    def categories_fake(
        self, target_access=2, target_categories=None, source_categories=None
    ):
        fake = FakeClient()
        fake.project_data = [
            self.category_project(
                "china-2026",
                "China 2026",
                2,
                self.SOURCE_CATEGORIES
                if source_categories is None
                else source_categories,
            ),
            self.category_project(
                "nyc-2026",
                "NYC Dec 2026",
                target_access,
                [] if target_categories is None else target_categories,
            ),
        ]
        return fake

    def categories_invoke(self, fake, extra):
        return self.invoke_with(fake, ["categories", *extra])

    def copy_argv(self, project="nyc-2026", source="china-2026", commit=None):
        argv = ["--project", project, "--copy-from", source]
        if commit is not None:
            argv += ["--commit", commit]
        return argv

    def copy_preview(self, fake, project="nyc-2026", source="china-2026"):
        code, stdout, stderr = self.categories_invoke(
            fake, self.copy_argv(project, source)
        )
        self.assertEqual(code, 0, stderr)
        return json.loads(stdout)

    def test_categories_list_is_read_only_and_handles_dict_payload(self):
        fake = self.categories_fake()
        fake.project_data[1]["categories"] = {
            str(category["id"]): category for category in self.SOURCE_CATEGORIES
        }
        code, stdout, stderr = self.categories_invoke(fake, ["--project", "nyc-2026"])
        self.assertEqual(code, 0, stderr)
        report = json.loads(stdout)
        self.assertEqual(report["status"], "categories")
        self.assertEqual(report["access_level"], 2)
        self.assertEqual(report["count"], 3)
        self.assertEqual(
            [category["name"] for category in report["categories"]],
            ["Alojamento", "Transportes", "Voos"],
        )
        self.assertEqual(fake.create_category_calls, [])

    def test_categories_list_allows_temporary_maintainer_access(self):
        fake = self.categories_fake(target_access=3)
        code, stdout, stderr = self.categories_invoke(fake, ["--project", "nyc-2026"])
        self.assertEqual(code, 0, stderr)
        self.assertEqual(json.loads(stdout)["access_level"], 3)

    def test_categories_mode_rejects_admin_access(self):
        fake = self.categories_fake(target_access=4)
        code, _, stderr = self.categories_invoke(fake, ["--project", "nyc-2026"])
        self.assertEqual(code, 2)
        self.assertIn("Participant (2) or Maintainer (3)", stderr)

    def test_categories_list_rejects_commit_without_copy_from(self):
        fake = self.categories_fake()
        code, _, stderr = self.categories_invoke(
            fake, ["--project", "nyc-2026", "--commit", "abc"]
        )
        self.assertEqual(code, 2)
        self.assertIn("--commit requires --copy-from", stderr)
        self.assertEqual(fake.create_category_calls, [])

    def test_categories_copy_preview_never_posts(self):
        fake = self.categories_fake()
        preview = self.copy_preview(fake)
        self.assertEqual(preview["status"], "preview")
        self.assertFalse(preview["in_sync"])
        self.assertEqual(
            [category["name"] for category in preview["to_add"]],
            ["Alojamento", "Transportes", "Voos"],
        )
        self.assertEqual(
            [category["order"] for category in preview["to_add"]], [0, 1, 2]
        )
        self.assertTrue(preview["confirmation_token"])
        self.assertEqual(fake.create_category_calls, [])

    def test_categories_copy_commit_requires_maintainer_access(self):
        fake = self.categories_fake(target_access=2)
        preview = self.copy_preview(fake)
        code, _, stderr = self.categories_invoke(
            fake, self.copy_argv(commit=preview["confirmation_token"])
        )
        self.assertEqual(code, 2)
        self.assertIn("Maintainer", stderr)
        self.assertEqual(fake.create_category_calls, [])

    def test_categories_copy_commit_adds_only_missing_categories(self):
        fake = self.categories_fake(target_access=3)
        preview = self.copy_preview(fake)
        code, stdout, stderr = self.categories_invoke(
            fake, self.copy_argv(commit=preview["confirmation_token"])
        )
        self.assertEqual(code, 0, stderr)
        self.assertIn('"status": "committed"', stdout)
        self.assertEqual(
            [payload["name"] for _, payload in fake.create_category_calls],
            ["Alojamento", "Transportes", "Voos"],
        )
        self.assertEqual(
            [payload["order"] for _, payload in fake.create_category_calls],
            [0, 1, 2],
        )
        self.assertEqual(len(fake.project_data[1]["categories"]), 3)

    def test_categories_copy_retry_reports_already_in_sync(self):
        fake = self.categories_fake(target_access=3)
        preview = self.copy_preview(fake)
        argv = self.copy_argv(commit=preview["confirmation_token"])
        code, _, stderr = self.categories_invoke(fake, argv)
        self.assertEqual(code, 0, stderr)
        code, stdout, _ = self.categories_invoke(fake, argv)
        self.assertEqual(code, 0)
        self.assertIn('"status": "already-in-sync"', stdout)
        self.assertEqual(len(fake.create_category_calls), 3)

    def test_categories_copy_wrong_token_never_posts(self):
        fake = self.categories_fake(target_access=3)
        code, _, stderr = self.categories_invoke(fake, self.copy_argv(commit="wrong"))
        self.assertEqual(code, 2)
        self.assertIn("does not match", stderr)
        self.assertEqual(fake.create_category_calls, [])

    def test_categories_copy_conflicts_fail_closed(self):
        target = [
            {"id": 901, "name": "Voos", "icon": "🛫", "color": "#000000", "order": 2}
        ]
        fake = self.categories_fake(target_access=3, target_categories=target)
        preview = self.copy_preview(fake)
        self.assertFalse(preview["in_sync"])
        self.assertEqual(len(preview["conflicts"]), 1)
        self.assertEqual(preview["conflicts"][0]["name"], "Voos")
        self.assertEqual(
            [category["name"] for category in preview["to_add"]],
            ["Alojamento", "Transportes"],
        )
        code, _, stderr = self.categories_invoke(
            fake, self.copy_argv(commit=preview["confirmation_token"])
        )
        self.assertEqual(code, 2)
        self.assertIn("resolved manually", stderr)
        self.assertEqual(fake.create_category_calls, [])

    def test_categories_copy_never_removes_target_extras(self):
        target = [
            {
                "id": 901,
                "name": "Restaurantes",
                "icon": "🍴",
                "color": "#111111",
                "order": 5,
            }
        ]
        fake = self.categories_fake(target_access=3, target_categories=target)
        preview = self.copy_preview(fake)
        self.assertEqual(preview["extra_in_target"], ["Restaurantes"])
        code, _, stderr = self.categories_invoke(
            fake, self.copy_argv(commit=preview["confirmation_token"])
        )
        self.assertEqual(code, 0, stderr)
        names = [category["name"] for category in fake.project_data[1]["categories"]]
        self.assertIn("Restaurantes", names)
        self.assertEqual(len(names), 4)

    def test_categories_copy_rejects_same_source_and_target(self):
        fake = self.categories_fake()
        code, _, stderr = self.categories_invoke(
            fake, ["--project", "nyc-2026", "--copy-from", "nyc-2026"]
        )
        self.assertEqual(code, 2)
        self.assertIn("must be different", stderr)
        self.assertEqual(fake.create_category_calls, [])

    def test_categories_copy_in_sync_commit_needs_no_elevation(self):
        source = copy.deepcopy(self.SOURCE_CATEGORIES)
        fake = self.categories_fake(
            target_access=2, target_categories=source, source_categories=source
        )
        code, stdout, stderr = self.categories_invoke(
            fake, self.copy_argv(commit="not-a-real-token")
        )
        self.assertEqual(code, 0, stderr)
        self.assertIn('"status": "already-in-sync"', stdout)
        self.assertEqual(fake.create_category_calls, [])

    def test_categories_copy_duplicate_source_names_fail_closed(self):
        duplicate = [
            {"id": 1, "name": "Voos", "icon": "✈️", "color": "#000000", "order": 0},
            {"id": 2, "name": " voos ", "icon": "✈️", "color": "#000000", "order": 1},
        ]
        fake = self.categories_fake(source_categories=duplicate)
        code, _, stderr = self.categories_invoke(fake, self.copy_argv())
        self.assertEqual(code, 2)
        self.assertIn("duplicate category name", stderr)
        self.assertEqual(fake.create_category_calls, [])

    def test_categories_copy_interrupted_write_fails_closed(self):
        fake = self.categories_fake(target_access=3)
        preview = self.copy_preview(fake)
        fake.category_exception = MODULE.CospendError("network")
        code, _, stderr = self.categories_invoke(
            fake, self.copy_argv(commit=preview["confirmation_token"])
        )
        self.assertEqual(code, 2)
        self.assertIn("interrupted", stderr)
        self.assertEqual(len(fake.create_category_calls), 1)

    def test_add_mode_rejects_maintainer_access(self):
        fake = FakeClient()
        fake.project_data[0]["myaccesslevel"] = 3
        code, _, stderr = self.invoke(fake)
        self.assertEqual(code, 2)
        self.assertIn("exactly Participant", stderr)
        self.assertEqual(fake.create_calls, [])


if __name__ == "__main__":
    unittest.main()
