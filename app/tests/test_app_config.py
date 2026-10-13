"""The app must refuse unverified sessions unless login is switched off on purpose."""
import importlib

import app


def test_login_required_by_default(monkeypatch):
    monkeypatch.delenv("REQUIRE_LOGIN", raising=False)
    assert importlib.reload(app).REQUIRE_LOGIN is True


def test_login_only_off_when_explicitly_false(monkeypatch):
    monkeypatch.setenv("REQUIRE_LOGIN", "false")
    assert importlib.reload(app).REQUIRE_LOGIN is False
    monkeypatch.setenv("REQUIRE_LOGIN", "0")
    assert importlib.reload(app).REQUIRE_LOGIN is True
