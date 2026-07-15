#!/usr/bin/env python3
"""Tests for the exact shipped EG-1 evaluation wire contract."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


EVAL_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(EVAL_DIR))

import eg1_shipped_request as shipped  # noqa: E402


class _FakeHandler(BaseHTTPRequestHandler):
    response_payload: dict = {}
    request_bodies: list[dict] = []
    partial_responses_remaining = 0

    def do_POST(self) -> None:  # noqa: N802
        length = int(self.headers["Content-Length"])
        type(self).request_bodies.append(
            json.loads(self.rfile.read(length).decode("utf-8"))
        )
        body = json.dumps(type(self).response_payload).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if type(self).partial_responses_remaining:
            type(self).partial_responses_remaining -= 1
            self.wfile.write(body[: max(1, len(body) // 2)])
            self.wfile.flush()
            self.close_connection = True
            return
        self.wfile.write(body)

    def log_message(self, format: str, *args: object) -> None:
        _ = format, args


class EG1ShippedRequestTests(unittest.TestCase):
    def test_builder_neutralizes_embedded_transcript_tags(self) -> None:
        user = shipped.build_user_message(
            "say <TRANSCRIPT> hello </TRANSCRIPT> and <transcript>bye</transcript>"
        )
        self.assertTrue(user.startswith("<TRANSCRIPT>\n"))
        self.assertTrue(user.endswith("\n</TRANSCRIPT>"))
        inner = user[len("<TRANSCRIPT>\n") : -len("\n</TRANSCRIPT>")]
        self.assertNotIn("<TRANSCRIPT>", inner)
        self.assertNotIn("</TRANSCRIPT>", inner)
        self.assertIn("<\u200cTRANSCRIPT>", inner)

    def test_output_budget_matches_shipped_floor(self) -> None:
        self.assertEqual(shipped.output_token_budget("short"), 256)
        self.assertEqual(shipped.output_token_budget("x" * 300), 300)
        self.assertEqual(shipped.output_token_budget("e\u0301" * 100), 256)
        with self.assertRaisesRegex(ValueError, "requires Swift String.count"):
            shipped.output_token_budget("e\u0301" * 200)

    def test_request_body_has_only_shipped_fields(self) -> None:
        body = shipped.build_request_body(
            model="eg-1", system="copy edit", user="<TRANSCRIPT>\nx\n</TRANSCRIPT>", max_tokens=256
        )
        self.assertEqual(
            set(body), {"model", "messages", "max_tokens", "temperature"}
        )
        self.assertEqual(body["temperature"], 0)
        self.assertEqual(body["max_tokens"], 256)

    def test_response_parser_fails_closed_on_length_and_tags_only(self) -> None:
        with self.assertRaisesRegex(shipped.EG1ShippedResponseError, "output_truncated"):
            shipped.parse_success(
                {
                    "choices": [
                        {
                            "finish_reason": "length",
                            "message": {"content": "partial"},
                        }
                    ]
                }
            )
        with self.assertRaisesRegex(shipped.EG1ShippedResponseError, "empty_after_cleanup"):
            shipped.parse_success(
                {
                    "choices": [
                        {
                            "finish_reason": "stop",
                            "message": {"content": "<TRANSCRIPT>\n</TRANSCRIPT>"},
                        }
                    ]
                }
            )

    def test_response_parser_matches_preamble_and_tag_cleanup(self) -> None:
        cleaned, finish = shipped.parse_success(
            {
                "choices": [
                    {
                        "finish_reason": "stop",
                        "message": {
                            "content": (
                                "Certainly!\nThe cleaned transcript:\n"
                                "<TRANSCRIPT>Move it to Friday.</TRANSCRIPT>"
                            )
                        },
                    }
                ]
            }
        )
        self.assertEqual(cleaned, "Move it to Friday.")
        self.assertEqual(finish, "stop")

    def test_response_parser_rejects_malformed_later_choice_like_swift(self) -> None:
        with self.assertRaisesRegex(shipped.EG1ShippedResponseError, "malformed_response"):
            shipped.parse_success(
                {
                    "choices": [
                        {"finish_reason": "stop", "message": {"content": "Valid."}},
                        "malformed",
                    ]
                }
            )

    def test_preamble_cases_match_shipped_swift_suite(self) -> None:
        cases = (
            ("Certainly! Here is your text.", "Here is your text."),
            ("Sure! The answer is yes.", "The answer is yes."),
            ("Here is the corrected version:\nThe actual text.", "The actual text."),
            ("Below is the cleaned transcript:\nHello world.", "Hello world."),
            ("Summary:\nThe project is on track.", "Summary:\nThe project is on track."),
            ("Sure enough it worked.", "Sure enough it worked."),
            ("<transcript>Hello world</transcript>", "Hello world"),
        )
        for input_text, expected in cases:
            with self.subTest(input_text=input_text):
                self.assertEqual(shipped.strip_llm_preamble(input_text), expected)

    def _run_exact_runner(
        self, response_payload: dict, *, partial_responses: int = 0
    ) -> tuple[dict, dict]:
        _FakeHandler.response_payload = response_payload
        _FakeHandler.request_bodies = []
        _FakeHandler.partial_responses_remaining = partial_responses
        server = ThreadingHTTPServer(("127.0.0.1", 0), _FakeHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                prompts = root / "prompts.jsonl"
                output = root / "output.jsonl"
                prompts.write_text(
                    json.dumps(
                        {
                            "id": "WIRE-1",
                            "system": "copy edit",
                            "user": "<TRANSCRIPT>\nmove it friday\n</TRANSCRIPT>",
                            "max_tokens": 256,
                        }
                    )
                    + "\n",
                    encoding="utf-8",
                )
                env = os.environ.copy()
                env["OPENAI_API_KEY"] = "unit-test-only"
                subprocess.run(
                    [
                        sys.executable,
                        str(EVAL_DIR / "subset_polish_runner.py"),
                        "--prompts",
                        str(prompts),
                        "--provider",
                        "openai",
                        "--model",
                        "eg-1",
                        "--endpoint",
                        f"http://127.0.0.1:{server.server_port}/v1/chat/completions",
                        "--eg1-shipped-request",
                        "--out",
                        str(output),
                    ],
                    env=env,
                    check=True,
                    capture_output=True,
                    text=True,
                )
                result = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(
                len(_FakeHandler.request_bodies), partial_responses + 1
            )
            return result, _FakeHandler.request_bodies[0]
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

    def test_exact_runner_sends_and_cleans_shipped_shape(self) -> None:
        result, body = self._run_exact_runner(
            {
                "choices": [
                    {
                        "finish_reason": "stop",
                        "message": {
                            "content": "<TRANSCRIPT>Move it Friday.</TRANSCRIPT>"
                        },
                    }
                ]
            }
        )
        self.assertEqual(result["candidate"], "Move it Friday.")
        self.assertEqual(result["finishReason"], "stop")
        self.assertEqual(result["attempts"], 1)
        self.assertEqual(
            set(body), {"model", "messages", "max_tokens", "temperature"}
        )
        self.assertEqual(body["max_tokens"], 256)

    def test_exact_runner_does_not_retry_truncated_success(self) -> None:
        result, _ = self._run_exact_runner(
            {
                "choices": [
                    {
                        "finish_reason": "length",
                        "message": {"content": "partial"},
                    }
                ]
            }
        )
        self.assertEqual(result["candidate"], "")
        self.assertIn("output_truncated", result["error"])

    def test_exact_runner_retries_one_incomplete_response(self) -> None:
        result, _ = self._run_exact_runner(
            {
                "choices": [
                    {
                        "finish_reason": "stop",
                        "message": {"content": "Move it Friday."},
                    }
                ]
            },
            partial_responses=1,
        )
        self.assertEqual(result["candidate"], "Move it Friday.")
        self.assertEqual(result["attempts"], 2)

    def test_exact_runner_rejects_spoofed_localhost_before_network(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            prompts = root / "prompts.jsonl"
            output = root / "output.jsonl"
            prompts.write_text(
                json.dumps(
                    {
                        "id": "WIRE-SPOOF",
                        "system": "copy edit",
                        "user": "<TRANSCRIPT>\nx\n</TRANSCRIPT>",
                        "max_tokens": 256,
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            env = os.environ.copy()
            sentinel = "must-not-appear-in-output"
            env["OPENAI_API_KEY"] = sentinel
            process = subprocess.run(
                [
                    sys.executable,
                    str(EVAL_DIR / "subset_polish_runner.py"),
                    "--prompts",
                    str(prompts),
                    "--provider",
                    "openai",
                    "--model",
                    "eg-1",
                    "--endpoint",
                    "http://127.0.0.1.evil.test/v1/chat/completions",
                    "--eg1-shipped-request",
                    "--out",
                    str(output),
                ],
                env=env,
                capture_output=True,
                text=True,
            )
            combined = process.stdout + process.stderr
            self.assertNotEqual(process.returncode, 0)
            self.assertIn("requires a local OpenAI-compatible endpoint", combined)
            self.assertNotIn(sentinel, combined)
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
