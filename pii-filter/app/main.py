# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

import asyncio
import hmac
import logging
import os
from contextlib import asynccontextmanager
from pathlib import Path
from typing import AsyncIterator, NoReturn

from fastapi import FastAPI, HTTPException, Request
from fastapi.concurrency import run_in_threadpool

from app.inspector import InspectionUnavailable, InvalidRequest, RuleSet, inspect, parse_json

logger = logging.getLogger("pii-filter")
MAX_BODY_BYTES = 1048576


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    key = os.environ.get("PII_FILTER_KEY", "")
    if len(key) < 32 or not key.isascii():
        logger.error("PII filter requires an ASCII authentication key of at least 32 characters")
        raise RuntimeError("Invalid PII filter configuration")
    try:
        rules_json = os.environ.get("PII_RULES_JSON")
        if rules_json is None:
            rules_json = Path(os.environ.get("PII_RULES_PATH", "/app/rules.json")).read_text("utf-8")
        rules = RuleSet.load(rules_json)
    except (OSError, ValueError) as exc:
        logger.error("PII filter could not load valid rules")
        raise RuntimeError("Invalid PII rules configuration") from exc
    app.state.key = key.encode("ascii")
    app.state.rules = rules
    logger.info("PII filter ready rule_version=%s", rules.version)
    yield


app = FastAPI(lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)


def reject(status: int, code: str) -> NoReturn:
    logger.warning("PII inspection rejected status=%d code=%s", status, code)
    raise HTTPException(status_code=status, detail=code)


@app.get("/healthz")
async def healthz(request: Request) -> dict[str, str]:
    return {"status": "ok", "ruleVersion": request.app.state.rules.version}


@app.post("/inspect")
async def inspection(request: Request) -> dict[str, object]:
    presented = request.headers.get("X-PII-Filter-Key", "").encode("utf-8")
    if not hmac.compare_digest(presented, request.app.state.key):
        reject(401, "UNAUTHORIZED")
    media_type = request.headers.get("Content-Type", "").split(";", 1)[0].strip().lower()
    if media_type != "application/json":
        reject(415, "UNSUPPORTED_CONTENT_TYPE")
    if request.headers.get("Content-Encoding", "identity").lower() != "identity":
        reject(415, "UNSUPPORTED_CONTENT_ENCODING")
    content_length = request.headers.get("Content-Length")
    if content_length is not None:
        if len(content_length) > 20 or not content_length.isascii() or not content_length.isdecimal():
            reject(400, "INVALID_REQUEST")
        if int(content_length) > MAX_BODY_BYTES:
            reject(413, "REQUEST_TOO_LARGE")
    body = bytearray()
    try:
        async with asyncio.timeout(5):
            async for chunk in request.stream():
                if len(body) + len(chunk) > MAX_BODY_BYTES:
                    reject(413, "REQUEST_TOO_LARGE")
                body.extend(chunk)
    except TimeoutError:
        reject(503, "PII_INSPECTION_UNAVAILABLE")
    try:
        document = parse_json(body.decode("utf-8"))
        if not isinstance(document, dict):
            raise InvalidRequest("Request must be a JSON object")
        result = await run_in_threadpool(inspect, document, request.app.state.rules)
    except (UnicodeDecodeError, InvalidRequest):
        reject(400, "INVALID_REQUEST")
    except InspectionUnavailable:
        reject(503, "PII_INSPECTION_UNAVAILABLE")
    logger.info(
        "PII inspection complete allowed=%s matches=%d rule_version=%s duration_ms=%d",
        result["allowed"], result["matchCount"], result["ruleVersion"], result["durationMs"],
    )
    return result
