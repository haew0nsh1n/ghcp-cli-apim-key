# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

import json
import math
import time
import unicodedata
from dataclasses import dataclass

import regex


class InvalidRequest(ValueError):
    pass


class InspectionUnavailable(RuntimeError):
    pass


def _reject_constant(value: str) -> None:
    raise InvalidRequest("Non-standard JSON constant")


def _unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise InvalidRequest("Duplicate JSON key")
        result[key] = value
    return result


def parse_json(value: str) -> object:
    try:
        return json.loads(value, parse_constant=_reject_constant, object_pairs_hook=_unique_object)
    except (json.JSONDecodeError, RecursionError, ValueError) as exc:
        raise InvalidRequest("Invalid JSON") from exc


@dataclass(frozen=True)
class Rule:
    id: str
    pattern: regex.Pattern[str]
    validator: str
    keywords: tuple[str, ...] = ()
    context_window: int = 80
    fields: tuple[str, ...] = ()
    allowlist: frozenset[str] = frozenset()


def _rule_strings(definition: dict[str, object], name: str, limit: int) -> tuple[str, ...]:
    values = definition.get(name, [])
    if not isinstance(values, list) or len(values) > limit:
        raise ValueError(f"Invalid rule {name}")
    if name in definition and name != "allowlist" and not values:
        raise ValueError(f"Rule {name} cannot be empty")
    if any(not isinstance(value, str) or not value.strip() or len(value) > 256 for value in values):
        raise ValueError(f"Invalid rule {name} entry")
    return tuple(unicodedata.normalize("NFKC", value) for value in values)


@dataclass(frozen=True)
class RuleSet:
    version: str
    rules: tuple[Rule, ...]

    @classmethod
    def load(cls, value: str) -> "RuleSet":
        document = parse_json(value)
        if not isinstance(document, dict) or set(document) != {"version", "rules"}:
            raise ValueError("Rules must contain version and rules")
        version = document["version"]
        definitions = document["rules"]
        if not isinstance(version, str) or not regex.fullmatch(r"[A-Za-z0-9._-]{1,64}", version):
            raise ValueError("Invalid rule version")
        if not isinstance(definitions, list) or not 1 <= len(definitions) <= 32:
            raise ValueError("Rules must contain between 1 and 32 definitions")
        rules: list[Rule] = []
        ids: set[str] = set()
        for definition in definitions:
            required = {"id", "enabled", "pattern", "validator"}
            optional = {"keywords", "context_window", "fields", "allowlist"}
            if (
                not isinstance(definition, dict)
                or not required <= set(definition)
                or set(definition) - required - optional
            ):
                raise ValueError("Invalid rule definition")
            rule_id = definition["id"]
            if not isinstance(rule_id, str) or not regex.fullmatch(r"[A-Z][A-Z0-9_]{0,63}", rule_id):
                raise ValueError("Invalid rule id")
            if rule_id in ids or not isinstance(definition["enabled"], bool):
                raise ValueError("Duplicate rule id or invalid enabled flag")
            ids.add(rule_id)
            pattern = definition["pattern"]
            validator = definition["validator"]
            if not isinstance(pattern, str) or not 1 <= len(pattern) <= 4096:
                raise ValueError("Invalid rule pattern")
            if validator not in ("none", "luhn"):
                raise ValueError("Unsupported rule validator")
            keywords = tuple(word.casefold() for word in _rule_strings(definition, "keywords", 32))
            fields = _rule_strings(definition, "fields", 32)
            allowlist = frozenset(_rule_strings(definition, "allowlist", 128))
            context_window = definition.get("context_window", 80)
            if (
                type(context_window) is not int
                or not 0 <= context_window <= 1024
                or ("context_window" in definition and not keywords)
            ):
                raise ValueError("Invalid rule context_window")
            try:
                compiled = regex.compile(pattern)
            except regex.error as exc:
                raise ValueError("Invalid rule expression") from exc
            if compiled.search(""):
                raise ValueError("Rules cannot match empty input")
            if definition["enabled"]:
                rules.append(Rule(rule_id, compiled, validator, keywords, context_window, fields, allowlist))
        if not rules:
            raise ValueError("At least one rule must be enabled")
        return cls(version, tuple(rules))


def _luhn_valid(value: str) -> bool:
    digits = [int(character) for character in value if character in "0123456789"]
    if not 13 <= len(digits) <= 19 or not any(digits):
        return False
    total = 0
    for index, digit in enumerate(reversed(digits)):
        if index % 2:
            digit *= 2
            if digit > 9:
                digit -= 9
        total += digit
    return total % 10 == 0


def inspect(document: object, rules: RuleSet, budget_seconds: float = 3.0) -> dict[str, object]:
    started = time.monotonic()
    deadline = started + budget_seconds
    counts: dict[str, int] = {}

    def scan(value: str, field: str | None) -> None:
        normalized = unicodedata.normalize("NFKC", value)
        for rule in rules.rules:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise InspectionUnavailable("Inspection deadline exceeded")
            if rule.fields and field not in rule.fields:
                continue
            try:
                for match in rule.pattern.finditer(normalized, timeout=min(0.05, remaining)):
                    if time.monotonic() >= deadline:
                        raise InspectionUnavailable("Inspection deadline exceeded")
                    if match.group() in rule.allowlist:
                        continue
                    if rule.keywords:
                        context = normalized[
                            max(0, match.start() - rule.context_window):
                            match.end() + rule.context_window
                        ].casefold()
                        if not any(keyword in context for keyword in rule.keywords):
                            continue
                    if rule.validator == "none" or _luhn_valid(match.group()):
                        counts[rule.id] = counts.get(rule.id, 0) + 1
            except TimeoutError as exc:
                raise InspectionUnavailable("Rule evaluation timed out") from exc

    def visit(value: object, depth: int, field: str | None = None) -> None:
        if depth > 64:
            raise InvalidRequest("JSON nesting limit exceeded")
        if time.monotonic() >= deadline:
            raise InspectionUnavailable("Inspection deadline exceeded")
        if isinstance(value, dict):
            for key, item in value.items():
                visit(key, depth + 1)
                visit(item, depth + 1, unicodedata.normalize("NFKC", key))
        elif isinstance(value, list):
            for item in value:
                visit(item, depth + 1, field)
        elif isinstance(value, str):
            # Tool arguments can themselves contain JSON-encoded strings.
            stripped = value.strip()
            if stripped.startswith(("{", "[", '"')):
                try:
                    nested = json.loads(
                        stripped, parse_constant=_reject_constant, object_pairs_hook=_unique_object
                    )
                except json.JSONDecodeError:
                    nested = None
                except (RecursionError, ValueError) as exc:
                    raise InvalidRequest("Invalid encoded JSON") from exc
                if isinstance(nested, (dict, list, str)) and nested != value:
                    visit(nested, depth + 1, field)
                    return
            scan(value, field)
        elif isinstance(value, bool) or value is None:
            return
        elif isinstance(value, (int, float)):
            if isinstance(value, float) and not math.isfinite(value):
                raise InvalidRequest("Non-finite number")
            scan(str(int(value)) if isinstance(value, float) and value.is_integer() else str(value), field)
        else:
            raise InvalidRequest("Unsupported JSON value")

    visit(document, 0)
    if time.monotonic() >= deadline:
        raise InspectionUnavailable("Inspection deadline exceeded")
    total = sum(counts.values())
    return {
        "inspectionComplete": True,
        "allowed": total == 0,
        "ruleVersion": rules.version,
        "matchCount": total,
        "matches": counts,
        "durationMs": int((time.monotonic() - started) * 1000),
    }
