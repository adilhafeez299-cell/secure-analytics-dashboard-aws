"""Who is the user? Read and verify the load balancer's OIDC header.

After sign-in, the AWS Application Load Balancer adds x-amzn-oidc-data to
every request. It is a JWT signed by the load balancer with ES256. We:
  1. read the key id (kid) and signer from the JWT header,
  2. check the signer is OUR load balancer (ALB_ARN env var),
  3. fetch the public key for that kid from the regional AWS endpoint,
  4. verify the signature and expiry,
before trusting the name inside it. If anything fails, the user is
recorded as unverified, so the audit trail never trusts a forged header.

Reference: "Authenticate users using an Application Load Balancer",
section "User claims encoding and signature verification" (AWS docs).
"""

import base64
import json
import os
import time
import urllib.request
from dataclasses import dataclass
from functools import lru_cache

import jwt

REGION = os.environ.get("AWS_REGION", "eu-west-2")
ALB_ARN = os.environ.get("ALB_ARN", "")
KEY_URL = "https://public-keys.auth.elb.{region}.amazonaws.com/{kid}"


@dataclass(frozen=True)
class Identity:
    name: str
    sub: str
    verified: bool


ANONYMOUS = Identity(name="anonymous", sub="", verified=False)


def _b64url_json(segment: str) -> dict:
    segment = segment.rstrip("=")
    padded = segment + "=" * (-len(segment) % 4)
    return json.loads(base64.urlsafe_b64decode(padded))


@lru_cache(maxsize=16)
def _public_key(kid: str) -> str:
    url = KEY_URL.format(region=REGION, kid=kid)
    with urllib.request.urlopen(url, timeout=5) as resp:  # noqa: S310 (fixed AWS host)
        return resp.read().decode()


def _b64url_bytes(segment: str) -> bytes:
    segment = segment.rstrip("=")
    return base64.urlsafe_b64decode(segment + "=" * (-len(segment) % 4))


def verify(token: str, key_fetcher=_public_key, expected_signer: str | None = None) -> dict:
    """Return verified claims or raise ValueError.

    The ALB signs "header.payload" exactly as it sends them, WITH base64 padding.
    The signature must therefore be checked over that exact text. Stripping the
    padding first (as an earlier version did) changes the signed text, and the
    check then fails for any user whose token happens to need padding. We check
    the ES256 signature directly so no JWT library can re-format the text.
    """
    expected_signer = ALB_ARN if expected_signer is None else expected_signer
    try:
        head, body, sig = token.split(".")
    except ValueError as exc:
        raise ValueError("malformed token") from exc
    header = _b64url_json(head)
    if header.get("alg") != "ES256":
        raise ValueError("unexpected algorithm")
    if not expected_signer or header.get("signer") != expected_signer:
        raise ValueError("token not signed by this load balancer")
    algorithm = jwt.algorithms.ECAlgorithm(jwt.algorithms.ECAlgorithm.SHA256)
    try:
        key = algorithm.prepare_key(key_fetcher(header["kid"]))
        valid = algorithm.verify(f"{head}.{body}".encode(), key, _b64url_bytes(sig))
    except Exception as exc:  # noqa: BLE001
        raise ValueError(f"invalid token: {exc!r}") from exc
    if not valid:
        raise ValueError("invalid token: signature verification failed")
    claims = _b64url_json(body)
    exp = claims.get("exp")
    if not isinstance(exp, (int, float)) or exp < time.time():
        raise ValueError("invalid token: expired")
    return claims


def identity_from_headers(headers, key_fetcher=_public_key, expected_signer: str | None = None) -> Identity:
    token = headers.get("x-amzn-oidc-data")
    if not token:
        return ANONYMOUS
    try:
        claims = verify(token, key_fetcher=key_fetcher, expected_signer=expected_signer)
    except Exception as exc:  # noqa: BLE001 - any failure means "do not trust"
        # Log the reason (never the token) so a refused session can be diagnosed.
        print(json.dumps({"type": "verify_failed", "reason": repr(exc)}), flush=True)
        sub = headers.get("x-amzn-oidc-identity", "")
        return Identity(name="unverified", sub=sub, verified=False)
    name = claims.get("name") or claims.get("email") or claims.get("preferred_username") or claims.get("sub", "")
    return Identity(name=name, sub=claims.get("sub", ""), verified=True)
