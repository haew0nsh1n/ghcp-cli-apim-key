# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

import copy
import json
import os
import unittest
from pathlib import Path
from unittest.mock import patch

from fastapi.testclient import TestClient

from app.inspector import InspectionUnavailable, RuleSet, inspect
from app.main import MAX_BODY_BYTES, app

RULES_JSON = (Path(__file__).parents[1] / "rules.json").read_text("utf-8")
KEY = "synthetic-filter-test-key-not-a-real-secret"


class InspectionTests(unittest.TestCase):
    def setUp(self):
        self.rules = RuleSet.load(RULES_JSON)

    def test_detects_each_category_including_numeric_values_and_keys(self):
        cases = [
            ({"content": "900101-1234567"}, "KOR_RRN"),
            ({"content": "person@example.invalid"}, "EMAIL"),
            ({"content": "070-1234-5678"}, "KOR_PHONE"),
            ({"content": "080-123-4567"}, "KOR_PHONE"),
            ({"content": "+82-10-1234-5678"}, "KOR_PHONE"),
            ({"content": "02-123-4567"}, "KOR_PHONE"),
            ({"content": "4111 1111 1111 1111"}, "PAYMENT_CARD"),
            ({"card": 4111111111111111}, "PAYMENT_CARD"),
            ({"person@example.invalid": None}, "EMAIL"),
        ]
        for payload, category in cases:
            with self.subTest(category=category, payload=payload):
                before = copy.deepcopy(payload)
                result = inspect(payload, self.rules)
                self.assertFalse(result["allowed"])
                self.assertIn(category, result["matches"])
                self.assertEqual(payload, before)
                self.assertNotIn("person@example.invalid", json.dumps(result))

    def test_checks_history_and_escaped_tool_arguments(self):
        arguments = '{"email":"person\\u0040example.invalid"}'
        result = inspect({
            "messages": [
                {"role": "user", "content": "hello"},
                {"role": "assistant", "tool_calls": [{"function": {"arguments": arguments}}]},
                {"role": "tool", "content": "010-1234-5678"},
            ]
        }, self.rules)
        self.assertEqual(result["matches"]["EMAIL"], 1)
        self.assertEqual(result["matches"]["KOR_PHONE"], 1)

    def test_clean_request_and_invalid_luhn_are_not_modified(self):
        document = {"messages": [{"content": "Reply OK. card=4111111111111112"}], "stream": True}
        original = copy.deepcopy(document)
        result = inspect(document, self.rules)
        self.assertTrue(result["allowed"])
        self.assertEqual(document, original)
        self.assertEqual(result["matchCount"], 0)

    def test_external_rules_change_detection_without_code_changes(self):
        document = json.loads(RULES_JSON)
        document["version"] = "custom.1"
        document["rules"].append({
            "id": "INTERNAL_ID", "enabled": True, "pattern": r"EMP-[0-9]{4}", "validator": "none"
        })
        custom = RuleSet.load(json.dumps(document))
        self.assertTrue(inspect({"text": "EMP-1234"}, self.rules)["allowed"])
        self.assertFalse(inspect({"text": "EMP-1234"}, custom)["allowed"])
        document["rules"][-1]["enabled"] = False
        self.assertTrue(inspect({"text": "EMP-1234"}, RuleSet.load(json.dumps(document)))["allowed"])

    def test_invalid_or_empty_rules_are_rejected(self):
        for mutation in ("bad_pattern", "disabled", "duplicate", "unknown_validator"):
            document = json.loads(RULES_JSON)
            if mutation == "bad_pattern":
                document["rules"][0]["pattern"] = "("
            elif mutation == "disabled":
                for rule in document["rules"]:
                    rule["enabled"] = False
            elif mutation == "duplicate":
                document["rules"].append(document["rules"][0])
            else:
                document["rules"][0]["validator"] = "unknown"
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                RuleSet.load(json.dumps(document))

    def test_inspection_budget_exhaustion_is_not_allowed(self):
        with self.assertRaises(InspectionUnavailable):
            inspect({"content": "hello"}, self.rules, budget_seconds=0)

    def conditional_rules(self, **conditions):
        return RuleSet.load(json.dumps({
            "version": "conditions.1",
            "rules": [{
                "id": "CUSTOM", "enabled": True, "pattern": r"EMP-[0-9]{4}",
                "validator": "none", **conditions,
            }],
        }))

    def test_keywords_require_same_string_context_with_exact_window(self):
        rules = self.conditional_rules(keywords=["staff", "직원"], context_window=7)
        for text, blocked in [
            ("STAFF: EMP-1234", True),
            ("EMP-1234: 직원", True),
            ("staff   EMP-1234", False),
            ("EMP-1234", False),
            ("ｓｔａｆｆ: ＥＭＰ-１２３４", True),
        ]:
            with self.subTest(text=text):
                self.assertEqual(inspect({"text": text}, rules)["allowed"], not blocked)
        self.assertTrue(inspect({"label": "staff", "text": "EMP-1234"}, rules)["allowed"])
        self.assertTrue(inspect(
            {"text": "staff EMP-1234"},
            self.conditional_rules(keywords=["staff"], context_window=0),
        )["allowed"])

    def test_fields_follow_arrays_and_decoded_tool_json_but_not_child_objects(self):
        rules = self.conditional_rules(fields=["employeeId"])
        payload = {
            "employeeId": ["EMP-1234", {"other": "EMP-5678"}],
            "other": "EMP-5678",
            "EmployeeId": "EMP-5678",
            "arguments": '{"employeeId":"EMP-9012"}',
            "nested": {"ｅｍｐｌｏｙｅｅＩｄ": "EMP-3456"},
        }
        original = copy.deepcopy(payload)
        self.assertEqual(inspect(payload, rules)["matches"], {"CUSTOM": 3})
        self.assertEqual(payload, original)
        numeric = RuleSet.load(json.dumps({
            "version": "numeric.1",
            "rules": [{
                "id": "NUMERIC", "enabled": True, "pattern": "[0-9]{4}",
                "validator": "none", "fields": ["employeeId"],
            }],
        }))
        self.assertEqual(inspect({"employeeId": [1234], "other": 5678}, numeric)["matches"], {"NUMERIC": 1})

    def test_allowlist_is_exact_normalized_case_sensitive_and_rule_scoped(self):
        rules = self.conditional_rules(allowlist=["EMP-0000"])
        self.assertTrue(inspect({"text": "ＥＭＰ-００００"}, rules)["allowed"])
        self.assertEqual(inspect({"text": "EMP-0000 EMP-0001"}, rules)["matches"], {"CUSTOM": 1})
        self.assertFalse(inspect({"text": "EMP-0000"}, self.conditional_rules(allowlist=["emp-0000"]))["allowed"])
        document = json.loads(RULES_JSON)
        document["rules"].append({
            "id": "EXEMPT_EMAIL", "enabled": True, "pattern": "person@example\\.invalid",
            "validator": "none", "allowlist": ["person@example.invalid"],
        })
        self.assertEqual(
            inspect({"text": "person@example.invalid"}, RuleSet.load(json.dumps(document)))["matches"],
            {"EMAIL": 1},
        )

    def test_keyword_and_field_conditions_are_combined(self):
        rules = self.conditional_rules(fields=["employeeId"], keywords=["staff"])
        for payload, blocked in [
            ({"employeeId": "staff EMP-1234"}, True),
            ({"employeeId": "EMP-1234"}, False),
            ({"other": "staff EMP-1234"}, False),
        ]:
            with self.subTest(payload=payload):
                self.assertEqual(inspect(payload, rules)["allowed"], not blocked)

    def test_invalid_optional_conditions_are_rejected(self):
        for conditions in [
            {"keywords": []}, {"keywords": "staff"}, {"keywords": [1]},
            {"fields": []}, {"fields": [" "]}, {"fields": ["x"] * 33},
            {"allowlist": ["x"] * 129}, {"allowlist": ["x" * 257]},
            {"context_window": 40}, {"keywords": ["x"], "context_window": True},
            {"keywords": ["x"], "context_window": -1},
            {"keywords": ["x"], "context_window": 1025}, {"unknown": []},
        ]:
            with self.subTest(conditions=conditions), self.assertRaises(ValueError):
                self.conditional_rules(**conditions)
        self.assertFalse(inspect({"text": "EMP-1234"}, self.conditional_rules(allowlist=[]))["allowed"])

    def test_pathological_rule_times_out_instead_of_returning_allow(self):
        rules = RuleSet.load(json.dumps({
            "version": "timeout.1",
            "rules": [{"id": "SLOW", "enabled": True, "pattern": "(a|aa)+$", "validator": "none"}],
        }))
        with self.assertRaises(InspectionUnavailable):
            inspect({"content": "a" * 64 + "!"}, rules)

    def test_code_identifiers_templates_and_exact_test_email_are_allowed(self):
        examples = [
            "class Customer:\n    email: str\n    phone: str\n    accountNumber: str",
            'const schema = {password: "string", apiKey: {type: "string"}};',
            'email = "test@example.com"\napi_key = os.environ["OPENAI_API_KEY"]',
            'client = Client(api_key="<YOUR_API_KEY>")',
            'const password = process.env.DB_PASSWORD;',
            'connection = "Server=localhost;Password=${DB_PASSWORD};"',
            'connection = "Server=localhost;Password=YOUR_PASSWORD_HERE;"',
            'const connection = "AccountName=example;AccountKey=YOUR_ACCOUNT_KEY_HERE;"',
            'private_key = "-----BEGIN PRIVATE KEY-----\\n<KEY_DATA>\\n-----END PRIVATE KEY-----"',
            "revision = 9876543210\naccount_count = 42",
        ]
        for code in examples:
            with self.subTest(code=code):
                payload = {"messages": [{"role": "user", "content": code}]}
                original = copy.deepcopy(payload)
                self.assertTrue(inspect(payload, self.rules)["allowed"])
                self.assertEqual(payload, original)
        for email in ["other@example.com", "test@example.com.evil.invalid", "TEST@example.com"]:
            with self.subTest(email=email):
                self.assertIn("EMAIL", inspect({"code": f'email = "{email}"'}, self.rules)["matches"])
        self.assertIn("EMAIL", inspect({
            "code": 'safe = "test@example.com"\ncustomer = "person@example.invalid"'
        }, self.rules)["matches"])
        self.assertIn("EMAIL", inspect({"code": "a" * 64 + "@example.invalid"}, self.rules)["matches"])
        self.assertTrue(inspect({"code": "a" * 65 + "@example.invalid"}, self.rules)["allowed"])

    def test_account_numbers_require_code_context_or_structured_fields(self):
        cases = [
            ('account_number = "9876543210"', "BANK_ACCOUNT_CONTEXT"),
            ('bankAccount = "987-654-3210"', "BANK_ACCOUNT_CONTEXT"),
            ('// 계좌번호: 987-654-3210', "BANK_ACCOUNT_CONTEXT"),
            ("INSERT INTO payments (account_number) VALUES ('9876543210');", "BANK_ACCOUNT_CONTEXT"),
        ]
        for code, category in cases:
            with self.subTest(code=code):
                self.assertIn(category, inspect({"messages": [{"content": code}]}, self.rules)["matches"])
        for payload in [
            {"accountNumber": 9876543210},
            {"arguments": '{"account_number":"987-654-3210"}'},
        ]:
            with self.subTest(payload=payload):
                self.assertIn("BANK_ACCOUNT_FIELD", inspect(payload, self.rules)["matches"])
        self.assertTrue(inspect({"requestId": "9876543210"}, self.rules)["allowed"])
        self.assertTrue(inspect({"text": "account_number " + "." * 41 + "9876543210"}, self.rules)["allowed"])

    def test_exact_copilot_coauthor_address_is_allowed_without_changing_request(self):
        address = "223556219+Copilot@users.noreply.github.com"
        for content in [
            f"Co-authored-by: Copilot <{address}>",
            f"{address} {address}",
            address.translate(str.maketrans("0123456789", "０１２３４５６７８９")),
        ]:
            with self.subTest(content=content):
                payload = {"messages": [{"role": "system", "content": content}]}
                original = copy.deepcopy(payload)
                self.assertTrue(inspect(payload, self.rules)["allowed"])
                self.assertEqual(payload, original)

    def test_copilot_exception_preserves_detection_outside_the_exact_address(self):
        address = "223556219+Copilot@users.noreply.github.com"
        for content, expected in [
            (f"{address} person@example.invalid", {"EMAIL": 1}),
            (f"{address} 010-1234-5678", {"KOR_PHONE": 1}),
            (f"{address} 223556219", {"KOR_PHONE": 1}),
            (f"{address} account_number = 9876543210", {"BANK_ACCOUNT_CONTEXT": 1}),
        ]:
            with self.subTest(content=content):
                result = inspect({"messages": [{"role": "system", "content": content}]}, self.rules)
                self.assertEqual(result["matches"], expected)
        for content in [
            address + ".evil.invalid",
            "x" + address,
            address.replace("Copilot", "Other"),
            address.replace("223556219", "223556218"),
            address.replace("Copilot", "copilot"),
        ]:
            with self.subTest(content=content):
                result = inspect({"text": content}, self.rules)
                self.assertIn("EMAIL", result["matches"])
                self.assertIn("KOR_PHONE", result["matches"])
        self.assertIn("KOR_PHONE", inspect({"id": 223556219}, self.rules)["matches"])

    def test_large_code_is_fully_inspected_without_relaxing_timeouts(self):
        line = 'const schema = {email: "string", phone: "string", apiKey: process.env.API_KEY};\n'
        code = line * (512 * 1024 // len(line))
        self.assertTrue(inspect({"messages": [{"content": code}]}, self.rules)["allowed"])
        result = inspect({"messages": [{"content": code + '\nemail = "person@example.invalid"'}]}, self.rules)
        self.assertIn("EMAIL", result["matches"])

    def test_code_secret_signatures_are_blocked_without_leaking_matches(self):
        # Deliberately nonfunctional fixtures, not issued credentials or key material.
        github_token = "ghp_" + "a" * 36
        fine_grained_token = "github_pat_" + "b" * 60
        aws_key = "AKIA" + "A" * 16
        jwt = "eyJ" + "a" * 20 + "." + "b" * 20 + "." + "c" * 32
        key_body = "A" * 96
        api_key = "Ab3x" * 8
        cases = [
            (f'github_token = "{github_token}"', "GITHUB_TOKEN", github_token),
            (f'Authorization: Bearer {fine_grained_token}', "GITHUB_TOKEN", fine_grained_token),
            (f'aws_access_key_id = "{aws_key}"', "AWS_ACCESS_KEY_ID", aws_key),
            (f'Authorization: Bearer {jwt}', "JWT_TOKEN", jwt),
            (f"-----BEGIN PRIVATE KEY-----\n{key_body}\n-----END PRIVATE KEY-----", "PRIVATE_KEY", key_body),
            (f'key = "-----BEGIN RSA PRIVATE KEY-----\\n{key_body}\\n-----END RSA PRIVATE KEY-----"', "PRIVATE_KEY", key_body),
            (f'OPENAI_API_KEY = "{api_key}"', "API_CREDENTIAL_ASSIGNMENT", api_key),
            (f'const config = {{"apiKey": "{api_key}"}};', "API_CREDENTIAL_ASSIGNMENT", api_key),
            (f'connection = "Server=db;User Id=app;Password={api_key};"', "CONNECTION_STRING_SECRET", api_key),
            (f'connection = "AccountName=storage;AccountKey={api_key};"', "CONNECTION_STRING_SECRET", api_key),
        ]
        for code, category, secret in cases:
            with self.subTest(category=category):
                result = inspect({"messages": [{"content": code}]}, self.rules)
                self.assertFalse(result["allowed"])
                self.assertIn(category, result["matches"])
                self.assertNotIn(secret, json.dumps(result))

    def test_secret_keys_in_tool_json_and_tool_output_are_inspected(self):
        token = "ghp_" + "a" * 36
        result = inspect({"messages": [
            {"role": "assistant", "tool_calls": [{"function": {
                "arguments": json.dumps({"token": token}),
            }}]},
            {"role": "tool", "content": f'token = "{token}"'},
        ]}, self.rules)
        self.assertEqual(result["matches"]["GITHUB_TOKEN"], 2)
        api_key = "Ab3x" * 8
        result = inspect({"arguments": json.dumps({"api_key": api_key})}, self.rules)
        self.assertIn("API_CREDENTIAL_FIELD", result["matches"])
        self.assertTrue(inspect({"checksum": api_key}, self.rules)["allowed"])

    def test_api_allows_code_templates_but_blocks_embedded_sensitive_values(self):
        examples = [
            ('email = "test@example.com"\napi_key = os.getenv("OPENAI_API_KEY")', True),
            ('email = "person@example.invalid"', False),
            ('account_number = "987-654-3210"', False),
            ('api_key = "' + "Ab3x" * 8 + '"', False),
        ]
        with patch.dict(os.environ, {"PII_FILTER_KEY": KEY, "PII_RULES_JSON": RULES_JSON}), TestClient(app) as client:
            for code, allowed in examples:
                with self.subTest(allowed=allowed):
                    response = client.post("/inspect", headers={"X-PII-Filter-Key": KEY},
                                           json={"messages": [{"role": "user", "content": code}]})
                    self.assertEqual(response.status_code, 200)
                    self.assertEqual(response.json()["allowed"], allowed)


class ApiTests(unittest.TestCase):
    def setUp(self):
        self.environment = patch.dict(os.environ, {"PII_FILTER_KEY": KEY, "PII_RULES_JSON": RULES_JSON})
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.client = self.enterContext(TestClient(app))
        self.headers = {"X-PII-Filter-Key": KEY}

    def test_inspection_contract_and_no_body_in_response_or_logs(self):
        with self.assertLogs("pii-filter", level="INFO") as logs:
            response = self.client.post("/inspect", headers=self.headers, json={"text": "person@example.invalid"})
        self.assertEqual(response.status_code, 200)
        result = response.json()
        self.assertTrue(result["inspectionComplete"])
        self.assertFalse(result["allowed"])
        self.assertEqual(result["matchCount"], 1)
        self.assertNotIn("person@example.invalid", response.text + str(logs.output))
        clean = self.client.post("/inspect", headers=self.headers, json={"text": "Reply OK."})
        self.assertTrue(clean.json()["allowed"])

    def test_rejects_bad_auth_format_encoding_and_json(self):
        cases = [
            ({}, b"{}", 401),
            ({"X-PII-Filter-Key": "invalid"}, b"{}", 401),
            ({**self.headers, "Content-Type": "text/plain"}, b"{}", 415),
            ({**self.headers, "Content-Type": "application/json", "Content-Encoding": "gzip"}, b"{}", 415),
            ({**self.headers, "Content-Type": "application/json"}, b'{"value":NaN}', 400),
            ({**self.headers, "Content-Type": "application/json"}, b'{"text":"test@example.com","text":"hello"}', 400),
            ({**self.headers, "Content-Type": "application/json"}, b'{"text":"\xff"}', 400),
            ({**self.headers, "Content-Type": "application/json"}, b"[]", 400),
        ]
        for headers, body, expected in cases:
            with self.subTest(expected=expected):
                response = self.client.post("/inspect", headers=headers, content=body)
                self.assertEqual(response.status_code, expected)

    def test_enforces_size_for_declared_and_streamed_bodies(self):
        headers = {**self.headers, "Content-Type": "application/json"}
        response = self.client.post("/inspect", headers=headers, content=b"x" * (MAX_BODY_BYTES + 1))
        self.assertEqual(response.status_code, 413)
        response = self.client.post(
            "/inspect", headers=headers,
            content=iter([b"x" * MAX_BODY_BYTES, b"x"]),
        )
        self.assertEqual(response.status_code, 413)

    def test_inspection_failure_returns_unavailable_not_allow(self):
        with patch("app.main.inspect", side_effect=InspectionUnavailable("test")):
            response = self.client.post("/inspect", headers=self.headers, json={"text": "hello"})
        self.assertEqual(response.status_code, 503)

    def test_bad_rules_prevent_startup_and_health_success(self):
        with patch.dict(os.environ, {"PII_RULES_JSON": '{"version":"bad","rules":[]}'}):
            with self.assertRaises(RuntimeError), TestClient(app):
                pass


if __name__ == "__main__":
    unittest.main()
