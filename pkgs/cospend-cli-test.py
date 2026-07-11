#!/usr/bin/env python3

import contextlib
import importlib.util
import io
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

    def bill(self, project_id, bill_id):
        return self.created_bill


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

    def invoke(self, fake, extra=None):
        stdout, stderr = io.StringIO(), io.StringIO()
        with (
            mock.patch.object(MODULE, "keychain_password", return_value="secret"),
            mock.patch.object(MODULE, "CospendClient", return_value=fake),
            contextlib.redirect_stdout(stdout),
            contextlib.redirect_stderr(stderr),
        ):
            code = MODULE.main(self.ARGS + (extra or []))
        return code, stdout.getvalue(), stderr.getvalue()

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


if __name__ == "__main__":
    unittest.main()
