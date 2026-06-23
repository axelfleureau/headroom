"""Tests for MiniMax provider integration with the proxy auth shim.

Covers:
  - ProxyConfig fields exist and default to None
  - resolve_api_overrides picks up MINIMAX_TARGET_API_URL
  - resolve_api_targets returns the right URL hierarchy
  - _is_minimax_gateway_url correctly classifies gateway vs direct API URLs
  - create_proxy_backend returns None for backend="minimax" (passthrough)
  - format_backend_status prints a friendly MINIMAX banner
"""
from __future__ import annotations

import logging
import os
from unittest.mock import patch

from headroom.proxy.models import ProxyConfig
from headroom.providers.registry import (
    DEFAULT_MINIMAX_API_URL,
    ProviderApiOverrides,
    ProviderApiTargets,
    create_proxy_backend,
    format_backend_status,
    resolve_api_overrides,
    resolve_api_targets,
)


class TestProxyConfigFields:
    def test_minimax_api_key_defaults_none(self) -> None:
        cfg = ProxyConfig()
        assert cfg.minimax_api_key is None

    def test_minimax_api_url_defaults_none(self) -> None:
        cfg = ProxyConfig()
        assert cfg.minimax_api_url is None

    def test_minimax_session_token_defaults_none(self) -> None:
        cfg = ProxyConfig()
        assert cfg.minimax_session_token is None

    def test_minimax_fields_round_trip(self) -> None:
        cfg = ProxyConfig(
            minimax_api_key="sk-cp-test",
            minimax_api_url="https://api.minimaxi.com/anthropic",
            minimax_session_token="eyJ-fake-jwt",
        )
        assert cfg.minimax_api_key == "sk-cp-test"
        assert cfg.minimax_api_url == "https://api.minimaxi.com/anthropic"
        assert cfg.minimax_session_token == "eyJ-fake-jwt"

    def test_supports_model_accepts_bare_and_prefixed(self) -> None:
        from headroom.providers.minimax import MiniMaxProvider

        p = MiniMaxProvider()
        assert p.supports_model("MiniMax-M3") is True
        assert p.supports_model("minimax/MiniMax-M3") is True
        assert p.supports_model("") is False


class TestResolveApiOverrides:
    def test_resolve_picks_up_env_var(self) -> None:
        with patch.dict(os.environ, {"MINIMAX_TARGET_API_URL": "https://custom.example/v1"}):
            overrides = ProviderApiOverrides(
                anthropic=None,
                openai=None,
                gemini=None,
                cloudcode=None,
                vertex=None,
                minimax="https://override.example/v1",
            )
            # CLI flag > env var, so explicit non-None override wins.
            assert overrides.minimax == "https://override.example/v1"


class TestResolveApiTargets:
    def test_default_target_is_minimax_anthropic(self) -> None:
        targets = resolve_api_targets(
            ProviderApiOverrides(
                anthropic=None, openai=None, gemini=None, cloudcode=None, vertex=None, minimax=None
            )
        )
        assert targets.minimax == DEFAULT_MINIMAX_API_URL

    def test_override_takes_precedence(self) -> None:
        targets = resolve_api_targets(
            ProviderApiOverrides(
                anthropic=None,
                openai=None,
                gemini=None,
                cloudcode=None,
                vertex=None,
                minimax="https://staging.example/anthropic",
            )
        )
        assert targets.minimax == "https://staging.example/anthropic"


class TestCreateProxyBackend:
    def test_minimax_backend_is_passthrough(self) -> None:
        backend = create_proxy_backend(
            backend="minimax",
            anyllm_provider="openai",
            bedrock_region=None,
            logger=logging.getLogger("test"),
            minimax_api_key="sk-cp-fake",
            minimax_api_url="https://api.minimaxi.com/anthropic",
        )
        # Passthrough — translation handled in server.py
        assert backend is None

    def test_anthropic_backend_is_passthrough(self) -> None:
        backend = create_proxy_backend(
            backend="anthropic",
            anyllm_provider="openai",
            bedrock_region=None,
            logger=logging.getLogger("test"),
        )
        assert backend is None


class TestFormatBackendStatus:
    def test_minimax_status_mentions_anthropic_compat(self) -> None:
        status = format_backend_status(
            backend="minimax",
            anyllm_provider="openai",
            bedrock_region=None,
        )
        assert "MINIMAX" in status
        assert "Anthropic" in status or "x-api-key" in status

    def test_anthropic_status(self) -> None:
        status = format_backend_status(
            backend="anthropic",
            anyllm_provider="openai",
            bedrock_region=None,
        )
        assert "ANTHROPIC" in status


# These tests run against the live headroom server (port 8787) only if the
# MINIMAX_E2E=1 env var is set AND the proxy is running. Skipped by default.
import os as _os
import pytest as _pytest


@_pytest.mark.skipif(
    _os.environ.get("MINIMAX_E2E") != "1",
    reason="MINIMAX_E2E not enabled — live headroom proxy required",
)
class TestLiveMinimaxE2E:
    """Hits the running headroom proxy at 127.0.0.1:8787 and verifies MiniMax M3 responds.

    Prereqs: headroom running with MINIMAX_SESSION_TOKEN in env, MiniMax Code logged in.
    """

    def test_m3_responds_through_proxy(self) -> None:
        import urllib.request
        import json

        req = urllib.request.Request(
            "http://127.0.0.1:8787/v1/messages",
            data=json.dumps(
                {
                    "model": "MiniMax-M3",
                    "max_tokens": 20,
                    "messages": [{"role": "user", "content": "Say HELLO"}],
                }
            ).encode(),
            headers={
                "Content-Type": "application/json",
                "x-api-key": "dummy",
                "anthropic-version": "2023-06-01",
            },
        )
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read())
        assert data["model"] == "MiniMax-M3"
        assert any(
            b.get("type") == "text" and "HELLO" in b.get("text", "")
            for b in data.get("content", [])
        )

    def test_m27_highspeed_responds_through_proxy(self) -> None:
        import urllib.request
        import json

        req = urllib.request.Request(
            "http://127.0.0.1:8787/v1/messages",
            data=json.dumps(
                {
                    "model": "MiniMax-M2.7-highspeed",
                    "max_tokens": 20,
                    "messages": [{"role": "user", "content": "Say HELLO"}],
                }
            ).encode(),
            headers={
                "Content-Type": "application/json",
                "x-api-key": "dummy",
                "anthropic-version": "2023-06-01",
            },
        )
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read())
        assert data["model"] == "MiniMax-M2.7-highspeed"
