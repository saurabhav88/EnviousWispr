#!/usr/bin/env python3
"""Tests for the exact shipped EG-1 evaluation wire contract."""

from __future__ import annotations

import json
import hashlib
import shlex
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest import mock
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
    @staticmethod
    def _swift_environment(developer_dir: Path | None = None) -> dict[str, str]:
        environment = {
            "HOME": "/tmp",
            "LANG": "C",
            "LC_ALL": "C",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": "/tmp",
        }
        if developer_dir is not None:
            environment["DEVELOPER_DIR"] = str(developer_dir.resolve(strict=True))
        return environment

    def _swift_runner_contract(
        self, root: Path, *, fake_nondefault_runtime: bool = False
    ) -> tuple[list[str], dict[str, str], Path | None]:
        marker = None
        if fake_nondefault_runtime:
            developer_dir = root / "non-default-developer"
            developer_dir.mkdir()
            environment = self._swift_environment(developer_dir)
            marker = root / "locked-swift-used"
            executable = root / "locked-swift-target"
            executable.write_text(
                "#!/bin/sh\n"
                f"printf used > {shlex.quote(str(marker))}\n"
                "tab=$(printf '\\t')\n"
                "while IFS=\"$tab\" read -r operation payload; do\n"
                "  case \"$operation\" in\n"
                "    count) printf 'count\\t1\\n' ;;\n"
                "    trim-*) printf '%s\\t%s\\n' \"$operation\" \"$payload\" ;;\n"
                "    *) printf 'error\\n' ;;\n"
                "  esac\n"
                "done\n",
                encoding="utf-8",
            )
            executable.chmod(0o755)
            launcher = root / "locked-swift-launcher"
            launcher.symlink_to(executable)
            fallback_environment = self._swift_environment()
            fallback = Path(
                subprocess.check_output(
                    ["/usr/bin/xcrun", "--find", "swift"],
                    env=fallback_environment,
                    text=True,
                    stderr=subprocess.DEVNULL,
                ).strip()
            ).resolve(strict=True)
            self.assertNotEqual(fallback, executable.resolve(strict=True))
        else:
            environment = self._swift_environment()
            launcher = Path(
                subprocess.check_output(
                    ["/usr/bin/xcrun", "--find", "swift"],
                    env=environment,
                    text=True,
                    stderr=subprocess.DEVNULL,
                ).strip()
            ).absolute()
            executable = launcher.resolve(strict=True)

        environment_sha = hashlib.sha256(
            json.dumps(
                environment,
                ensure_ascii=False,
                sort_keys=True,
                separators=(",", ":"),
            ).encode("utf-8")
        ).hexdigest()
        arguments = [
            "--eg1-swift-launcher",
            str(launcher),
            "--eg1-swift-launcher-path-sha256",
            hashlib.sha256(str(launcher).encode("utf-8")).hexdigest(),
            "--eg1-swift-executable",
            str(executable.resolve(strict=True)),
            "--eg1-swift-executable-path-sha256",
            hashlib.sha256(
                str(executable.resolve(strict=True)).encode("utf-8")
            ).hexdigest(),
            "--eg1-swift-executable-sha256",
            hashlib.sha256(executable.read_bytes()).hexdigest(),
            "--eg1-swift-developer-dir",
            environment.get("DEVELOPER_DIR", "none"),
            "--eg1-swift-environment-sha256",
            environment_sha,
        ]
        return arguments, environment, marker

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
        self.assertEqual(shipped.output_token_budget("é" * 300), 300)
        self.assertEqual(shipped.output_token_budget("e\u0301" * 100), 256)
        self.assertEqual(shipped.output_token_budget("e\u0301" * 200), 256)

    def test_native_swift_character_count_parity_vectors(self) -> None:
        vectors = (
            ("\u0d4e\u0d15", 1),  # Malayalam prepend + base
            ("e\u0301", 1),  # decomposed accent
            ("👩‍💻", 1),  # ZWJ emoji
            ("🇩🇪", 1),  # regional-indicator flag
            ("\r\n", 1),
            ("가", 1),  # Hangul Jamo syllable
            ("English", 7),
            ("Grüße", 5),
            ("français", 8),
            ("español", 7),
            ("Привет", 6),
        )
        for value, expected in vectors:
            with self.subTest(value=value):
                self.assertEqual(shipped.swift_character_count(value), expected)

    def test_native_swift_character_count_fails_closed_without_oracle(self) -> None:
        shipped._stop_swift_oracle_process()
        with (
            mock.patch.object(
                shipped,
                "SWIFT_STRING_COUNT_ORACLE",
                EVAL_DIR / "missing-swift-count-oracle.swift",
            ),
            self.assertRaisesRegex(ValueError, "compiled Swift.*oracle"),
        ):
            shipped.swift_character_count("e\u0301")

    def test_native_swift_question_words_own_new_unicode_punctuation(self) -> None:
        punctuation = "\u1b4e"
        value = f"{punctuation}Um{punctuation} can we keep this"
        self.assertEqual(
            shipped._swift_question_words(value)[:2],
            [(f"{punctuation}um{punctuation}", "um"), ("can", "can")],
        )
        self.assertTrue(shipped.looks_like_question(value))
        uppercase_tje = "\u1c89"
        lowercase_tje = "\u1c8a"
        self.assertEqual(
            shipped._swift_question_words(uppercase_tje + "Can")[0],
            (lowercase_tje + "can", lowercase_tje + "can"),
        )

    def test_swift_whitespace_semantics_do_not_use_python_control_separators(self) -> None:
        value = "oné\u001ctwo three four"
        self.assertEqual(shipped._swift_text_metrics(value)[0], 3)
        self.assertTrue(shipped.input_would_bypass_polish(value, "en"))
        unsegmented = "日" * 9 + "\u001c"
        self.assertEqual(shipped._swift_text_metrics(unsegmented)[1], 10)
        self.assertFalse(shipped.input_would_bypass_polish(unsegmented, "zh"))
        self.assertEqual(
            shipped._swift_string_result(
                "trim-whitespace-newlines", "\u001ckeep controls\u001c"
            ),
            "\u001ckeep controls\u001c",
        )

    def test_native_swift_unicode_classification_fails_closed_without_oracle(self) -> None:
        shipped._stop_swift_oracle_process()
        punctuation = "\u1b4e"
        with (
            mock.patch.object(
                shipped,
                "SWIFT_STRING_COUNT_ORACLE",
                EVAL_DIR / "missing-swift-parity-oracle.swift",
            ),
            self.assertRaisesRegex(ValueError, "compiled Swift.*oracle"),
        ):
            shipped.looks_like_question(
                f"{punctuation}um{punctuation} can we keep this"
            )

    def test_message_output_validation_covers_all_three_shipped_guards(self) -> None:
        expansion_original = "please clean this short sentence now"
        content_drop_original = (
            "one two three four five six seven eight nine ten eleven twelve"
        )
        question_original = "Can you please schedule this meeting for Friday afternoon"
        self.assertEqual(
            shipped.apply_message_output_validation("x" * 300, expansion_original),
            (expansion_original, "expansion"),
        )
        self.assertEqual(
            shipped.apply_message_output_validation("too short", content_drop_original),
            (content_drop_original, "content_drop"),
        )
        self.assertEqual(
            shipped.apply_message_output_validation(
                "The meeting is scheduled for Friday afternoon.", question_original
            ),
            (question_original, "question_to_answer"),
        )

    def test_message_output_validation_counts_multiscalar_grapheme_with_swift(self) -> None:
        value = "please keep this e\u0301 exactly"
        self.assertEqual(shipped.apply_message_output_validation(value, value), (value, None))

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

    def test_preamble_length_thresholds_use_swift_grapheme_count(self) -> None:
        decomposed = "e\u0301"
        long_python_short_swift_line = "Here " + decomposed * 48 + ":"
        self.assertEqual(len(long_python_short_swift_line), 102)
        self.assertEqual(
            shipped.swift_character_count(long_python_short_swift_line), 54
        )
        self.assertEqual(
            shipped.strip_llm_preamble(long_python_short_swift_line + "\nKeep me."),
            "Keep me.",
        )

        long_python_short_swift_sentence = decomposed * 40 + "."
        self.assertEqual(len(long_python_short_swift_sentence), 81)
        self.assertEqual(
            shipped.swift_character_count(long_python_short_swift_sentence), 41
        )
        self.assertEqual(
            shipped.strip_llm_preamble(
                "Sure! " + long_python_short_swift_sentence
            ),
            long_python_short_swift_sentence,
        )

    def test_preamble_lowercase_expansion_fits_swift_protocol_bound(self) -> None:
        first_line = "Here " + ("İ" * 90) + ":"
        self.assertLess(shipped.swift_character_count(first_line), 100)
        self.assertTrue(shipped._first_line_looks_like_preamble(first_line))
        self.assertEqual(
            shipped.strip_llm_preamble(first_line + "\nKeep me."),
            "Keep me.",
        )

    def _run_exact_runner(
        self,
        response_payload: dict,
        *,
        partial_responses: int = 0,
        poison_proxy: bool = False,
        fake_nondefault_swift_runtime: bool = False,
        expected_returncode: int = 0,
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
                swift_arguments, swift_environment, swift_marker = (
                    self._swift_runner_contract(
                        root,
                        fake_nondefault_runtime=fake_nondefault_swift_runtime,
                    )
                )
                env = {
                    "OPENAI_API_KEY": "unit-test-only",
                    "NO_PROXY": "127.0.0.1",
                    "no_proxy": "127.0.0.1",
                    **swift_environment,
                }
                if poison_proxy:
                    env["HTTP_PROXY"] = "http://127.0.0.1:1"
                    env["http_proxy"] = "http://127.0.0.1:1"
                    env["ALL_PROXY"] = "http://127.0.0.1:1"
                    env["all_proxy"] = "http://127.0.0.1:1"
                    env["NO_PROXY"] = ""
                    env["no_proxy"] = ""
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
                        f"http://127.0.0.1:{server.server_port}/v1/chat/completions",
                        "--eg1-shipped-request",
                        *swift_arguments,
                        "--out",
                        str(output),
                    ],
                    env=env,
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(process.returncode, expected_returncode)
                result = json.loads(output.read_text(encoding="utf-8"))
                if swift_marker is not None:
                    self.assertTrue(swift_marker.is_file())
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
            },
            expected_returncode=2,
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

    def test_exact_runner_ignores_environment_proxy(self) -> None:
        result, _ = self._run_exact_runner(
            {
                "choices": [
                    {
                        "finish_reason": "stop",
                        "message": {"content": "Move it Friday."},
                    }
                ]
            },
            poison_proxy=True,
        )
        self.assertEqual(result["candidate"], "Move it Friday.")
        self.assertEqual(result["attempts"], 1)

    def test_exact_runner_uses_pinned_nondefault_swift_not_fallback_xcrun(self) -> None:
        decomposed_sentence = "e\u0301" * 40 + "."
        result, _ = self._run_exact_runner(
            {
                "choices": [
                    {
                        "finish_reason": "stop",
                        "message": {"content": "Sure!" + decomposed_sentence},
                    }
                ]
            },
            fake_nondefault_swift_runtime=True,
        )
        self.assertEqual(result["candidate"], decomposed_sentence)

    def test_exact_runner_rejects_missing_or_drifted_swift_pin_before_io(self) -> None:
        _FakeHandler.response_payload = {
            "choices": [
                {"finish_reason": "stop", "message": {"content": "unused"}}
            ]
        }
        _FakeHandler.request_bodies = []
        _FakeHandler.partial_responses_remaining = 0
        server = ThreadingHTTPServer(("127.0.0.1", 0), _FakeHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                prompts = root / "prompts.jsonl"
                prompts.write_text(
                    json.dumps(
                        {
                            "id": "WIRE-PIN",
                            "system": "copy edit",
                            "user": "<TRANSCRIPT>\nx\n</TRANSCRIPT>",
                            "max_tokens": 256,
                        }
                    )
                    + "\n",
                    encoding="utf-8",
                )
                swift_arguments, swift_environment, _ = self._swift_runner_contract(root)
                base_command = [
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
                ]
                environment = {"OPENAI_API_KEY": "unused", **swift_environment}
                cases: dict[str, list[str]] = {
                    "missing": [],
                    "path hash drift": list(swift_arguments),
                    "tampered executable hash": list(swift_arguments),
                    "developer environment mismatch": list(swift_arguments),
                }
                hash_index = cases["tampered executable hash"].index(
                    "--eg1-swift-executable-sha256"
                ) + 1
                cases["tampered executable hash"][hash_index] = "0" * 64
                path_hash_index = cases["path hash drift"].index(
                    "--eg1-swift-launcher-path-sha256"
                ) + 1
                cases["path hash drift"][path_hash_index] = "0" * 64
                developer_dir = root / "different-developer"
                developer_dir.mkdir()
                developer_index = cases["developer environment mismatch"].index(
                    "--eg1-swift-developer-dir"
                ) + 1
                cases["developer environment mismatch"][developer_index] = str(
                    developer_dir.resolve(strict=True)
                )
                for name, arguments in cases.items():
                    with self.subTest(name=name):
                        output = root / f"{name.replace(' ', '-')}.jsonl"
                        process = subprocess.run(
                            [*base_command, *arguments, "--out", str(output)],
                            env=environment,
                            check=False,
                            capture_output=True,
                            text=True,
                        )
                        self.assertNotEqual(process.returncode, 0)
                        self.assertIn("Swift", process.stdout + process.stderr)
                        self.assertFalse(output.exists())
                self.assertEqual(_FakeHandler.request_bodies, [])
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

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
            swift_arguments, swift_environment, _ = self._swift_runner_contract(root)
            env = dict(swift_environment)
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
                    *swift_arguments,
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

    def test_exact_runner_rejects_duplicate_prompt_ids_before_network(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            prompts = root / "prompts.jsonl"
            output = root / "output.jsonl"
            duplicate = {
                "id": "WIRE-DUPLICATE",
                "system": "copy edit",
                "user": "<TRANSCRIPT>\nx\n</TRANSCRIPT>",
                "max_tokens": 256,
            }
            prompts.write_text(
                json.dumps(duplicate) + "\n" + json.dumps(duplicate) + "\n",
                encoding="utf-8",
            )
            swift_arguments, swift_environment, _ = self._swift_runner_contract(root)
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
                    "http://127.0.0.1:1/v1/chat/completions",
                    "--eg1-shipped-request",
                    *swift_arguments,
                    "--out",
                    str(output),
                ],
                env=swift_environment,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(process.returncode, 0)
            self.assertIn("duplicate prompt id", process.stdout + process.stderr)
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
