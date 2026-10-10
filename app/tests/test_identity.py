"""Unit tests for load balancer token verification (no network)."""
import base64
import json
import time

import jwt
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

import identity

SIGNER = "arn:aws:elasticloadbalancing:eu-west-2:111122223333:loadbalancer/app/pharma-dash/abc"
KEY = ec.generate_private_key(ec.SECP256R1())
PUB = KEY.public_key().public_bytes(serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo).decode()
OTHER = ec.generate_private_key(ec.SECP256R1())


def token(signer=SIGNER, key=KEY, exp_offset=600, claims=None, name="Test Analyst"):
    """Build a token the way the real ALB does: padded base64url, signed over the PADDED text."""
    def b64(obj):
        return base64.urlsafe_b64encode(json.dumps(obj, separators=(",", ":")).encode()).decode()

    head = b64({"alg": "ES256", "kid": "k1", "signer": signer, "iss": "x", "client": "c", "typ": "JWT"})
    body_claims = {"sub": "abc-123", "name": name, "exp": int(time.time()) + exp_offset}
    body_claims.update(claims or {})
    body = b64(body_claims)
    sig = jwt.algorithms.ECAlgorithm(jwt.algorithms.ECAlgorithm.SHA256).sign(f"{head}.{body}".encode(), key)
    return f"{head}.{body}.{base64.urlsafe_b64encode(sig).decode()}"


def fetch(kid):
    assert kid == "k1"
    return PUB


def ident(tok):
    return identity.identity_from_headers({"x-amzn-oidc-data": tok, "x-amzn-oidc-identity": "abc-123"}, key_fetcher=fetch, expected_signer=SIGNER)


def test_valid_token_is_verified():
    who = ident(token())
    assert who.verified and who.name == "Test Analyst" and who.sub == "abc-123"


def test_wrong_signer_rejected():
    assert not ident(token(signer=SIGNER + "x")).verified


def test_forged_signature_rejected():
    assert not ident(token(key=OTHER)).verified


def test_expired_rejected():
    assert not ident(token(exp_offset=-60)).verified


def test_no_header_is_anonymous():
    assert identity.identity_from_headers({}, key_fetcher=fetch, expected_signer=SIGNER) == identity.ANONYMOUS


def test_every_padding_length_verifies():
    # Payload length mod 3 decides how much padding the ALB adds. Cover all cases.
    seen = set()
    for n in range(1, 7):
        tok = token(name="N" * n)
        seen.add(tok.split(".")[1].count("="))
        assert ident(tok).verified, f"name length {n} failed"
    assert seen == {0, 1, 2}, seen
