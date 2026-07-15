#!/usr/bin/env python3
"""Pure-Python mirror of the shipped EG-1 request and response contract.

The live connector remains the product authority. These helpers let controlled
evaluation runs send the same JSON fields and fail closed on the same response
shapes without exposing the app's per-launch bearer token.
"""

from __future__ import annotations

import atexit
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import subprocess
import threading
import time
from typing import Any


TRANSCRIPT_OPEN = "<TRANSCRIPT>"
TRANSCRIPT_CLOSE = "</TRANSCRIPT>"
MIN_OUTPUT_TOKENS = 256
UNSEGMENTED_LANGUAGE_CODES = {"ja", "zh", "yue", "th", "lo", "my", "km"}
# Swift/Foundation owns all Unicode-sensitive count, whitespace, lowercase, and
# punctuation decisions. Remaining len() uses are ASCII fast paths,
# byte-protocol bounds, list/token arity, and Python slice/index bounds.
_ASCII_SWIFT_WHITESPACE = " \t\n\v\f\r"
_ASCII_SWIFT_WHITESPACES = " \t"
_ASCII_SWIFT_PUNCTUATION = "!\"#%&'()*,-./:;?@[\\]_{}"
SWIFT_STRING_COUNT_ORACLE = Path(__file__).with_name(
    "eg1_swift_string_count_oracle.swift"
)
_SWIFT_ORACLE_PROCESS: subprocess.Popen[bytes] | None = None
_SWIFT_ORACLE_LOCK = threading.Lock()
_SWIFT_LAUNCHER_PATH: Path | None = None
_SWIFT_EXECUTABLE: Path | None = None
_SWIFT_EXECUTABLE_SHA256: str | None = None
_SWIFT_TOOL_ENVIRONMENT: dict[str, str] | None = None


class EG1ShippedResponseError(ValueError):
    """A response the shipped connector would silently bypass."""


def neutralize_transcript_tags(transcript: str) -> str:
    replacements = (
        ("</TRANSCRIPT>", "<\u200c/TRANSCRIPT>"),
        ("<TRANSCRIPT>", "<\u200cTRANSCRIPT>"),
        ("</transcript>", "<\u200c/transcript>"),
        ("<transcript>", "<\u200ctranscript>"),
    )
    result = transcript
    for old, new in replacements:
        result = result.replace(old, new)
    return result


def build_user_message(transcript: str) -> str:
    safe = neutralize_transcript_tags(transcript)
    return f"{TRANSCRIPT_OPEN}\n{safe}\n{TRANSCRIPT_CLOSE}"


def output_token_budget(transcript: str) -> int:
    # The lock-pinned native Swift oracle owns every character-length decision.
    return max(swift_character_count(transcript), MIN_OUTPUT_TOKENS)


def swift_character_count(value: str) -> int:
    """Use native Swift grapheme rules; ASCII without CRLF is provably direct."""

    if value.isascii() and "\r\n" not in value:
        return len(value)
    return _query_swift_character_count(value)


def _start_swift_oracle_process() -> subprocess.Popen[bytes]:
    global _SWIFT_LAUNCHER_PATH, _SWIFT_EXECUTABLE, _SWIFT_EXECUTABLE_SHA256
    if not SWIFT_STRING_COUNT_ORACLE.is_file() or SWIFT_STRING_COUNT_ORACLE.is_symlink():
        raise ValueError("trusted compiled Swift parity oracle is unavailable")
    if (
        _SWIFT_LAUNCHER_PATH is None
        or _SWIFT_EXECUTABLE is None
        or _SWIFT_EXECUTABLE_SHA256 is None
    ):
        try:
            launcher = Path(
                subprocess.check_output(
                    ["/usr/bin/xcrun", "--find", "swift"],
                    env={
                        "HOME": "/tmp",
                        "LANG": "C",
                        "LC_ALL": "C",
                        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                        "TMPDIR": "/tmp",
                    },
                    text=True,
                    stderr=subprocess.DEVNULL,
                ).strip()
            ).absolute()
            executable = launcher.resolve(strict=True)
        except (OSError, subprocess.CalledProcessError) as error:
            raise ValueError(
                "trusted compiled Swift parity oracle is unavailable"
            ) from error
        configure_swift_count_executable(
            launcher, executable, _sha256_file(executable)
        )
    swift_launcher = _SWIFT_LAUNCHER_PATH
    swift_executable = _SWIFT_EXECUTABLE
    expected_sha = _SWIFT_EXECUTABLE_SHA256
    try:
        launcher_target = (
            swift_launcher.resolve(strict=True) if swift_launcher is not None else None
        )
    except OSError as error:
        raise ValueError("trusted compiled Swift parity executable has drifted") from error
    if (
        swift_launcher is None
        or swift_executable is None
        or expected_sha is None
        or launcher_target != swift_executable
        or _sha256_file(swift_executable) != expected_sha
    ):
        raise ValueError("trusted compiled Swift parity executable has drifted")
    environment = _SWIFT_TOOL_ENVIRONMENT or {
        "HOME": "/tmp",
        "LANG": "C",
        "LC_ALL": "C",
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "TMPDIR": "/tmp",
    }
    try:
        return subprocess.Popen(
            [str(swift_launcher), str(SWIFT_STRING_COUNT_ORACLE)],
            executable=str(swift_executable),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=environment,
        )
    except OSError as error:
        raise ValueError(
            "trusted compiled Swift parity oracle is unavailable"
        ) from error


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError as error:
        raise ValueError("trusted compiled Swift parity executable is unavailable") from error
    return digest.hexdigest()


def configure_swift_count_executable(
    launcher_path: Path,
    executable_path: Path,
    expected_sha256: str,
    environment: dict[str, str] | None = None,
) -> None:
    """Bind future Unicode-parity oracle launches to the lock-hashed executable."""

    global _SWIFT_LAUNCHER_PATH, _SWIFT_EXECUTABLE, _SWIFT_EXECUTABLE_SHA256
    global _SWIFT_TOOL_ENVIRONMENT
    try:
        launcher = launcher_path.absolute()
        executable = executable_path.resolve(strict=True)
        launcher_target = launcher.resolve(strict=True)
    except OSError as error:
        raise ValueError("trusted compiled Swift parity executable is unavailable") from error
    if (
        not launcher.is_file()
        or not executable.is_file()
        or launcher_target != executable
        or not re.fullmatch(r"[0-9a-f]{64}", expected_sha256)
        or _sha256_file(executable) != expected_sha256
    ):
        raise ValueError("trusted compiled Swift parity executable has drifted")
    _stop_swift_oracle_process()
    _SWIFT_LAUNCHER_PATH = launcher
    _SWIFT_EXECUTABLE = executable
    _SWIFT_EXECUTABLE_SHA256 = expected_sha256
    _SWIFT_TOOL_ENVIRONMENT = dict(environment) if environment is not None else None


def _query_swift_oracle(
    operation: str, value: str, *, maximum_payload_bytes: int
) -> bytes:
    global _SWIFT_ORACLE_PROCESS
    try:
        encoded = base64.b64encode(value.encode("utf-8")).decode("ascii")
    except UnicodeEncodeError as error:
        raise ValueError("trusted compiled Swift parity oracle rejected input") from error
    with _SWIFT_ORACLE_LOCK:
        if _SWIFT_ORACLE_PROCESS is None or _SWIFT_ORACLE_PROCESS.poll() is not None:
            _SWIFT_ORACLE_PROCESS = _start_swift_oracle_process()
        process = _SWIFT_ORACLE_PROCESS
        if process.stdin is None or process.stdout is None:
            raise ValueError("trusted compiled Swift parity oracle is unavailable")
        try:
            process.stdin.write((operation + "\t" + encoded + "\n").encode("ascii"))
            process.stdin.flush()
            selector = selectors.DefaultSelector()
            try:
                selector.register(process.stdout, selectors.EVENT_READ)
                deadline = time.monotonic() + 10
                response = bytearray()
                while b"\n" not in response:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0 or not selector.select(timeout=remaining):
                        raise TimeoutError
                    chunk = os.read(process.stdout.fileno(), 4096)
                    if not chunk:
                        raise BrokenPipeError
                    response.extend(chunk)
                    if len(response) > maximum_payload_bytes + len(operation) + 2:
                        raise ValueError
            finally:
                selector.close()
            line, separator, remainder = response.partition(b"\n")
            if separator != b"\n" or remainder:
                raise ValueError
            response_operation, delimiter, payload = line.partition(b"\t")
            if delimiter != b"\t" or response_operation != operation.encode("ascii"):
                raise ValueError
        except (BrokenPipeError, OSError, TimeoutError, ValueError) as error:
            _stop_swift_oracle_process()
            raise ValueError(
                "trusted compiled Swift parity oracle failed closed"
            ) from error
        return payload


def _query_swift_character_count(value: str) -> int:
    try:
        count = int(
            _query_swift_oracle("count", value, maximum_payload_bytes=64)
        )
    except ValueError as error:
        _stop_swift_oracle_process()
        raise ValueError("trusted compiled Swift parity oracle failed closed") from error
    if count < 0:
        _stop_swift_oracle_process()
        raise ValueError("trusted compiled Swift parity oracle failed closed")
    return count


def _decode_swift_json(operation: str, value: str) -> Any:
    encoded = base64.b64encode(value.encode("utf-8"))
    payload = _query_swift_oracle(
        operation,
        value,
        maximum_payload_bytes=max(4096, len(encoded) * 4 + 4096),
    )
    try:
        return json.loads(base64.b64decode(payload, validate=True).decode("utf-8"))
    except (UnicodeDecodeError, ValueError, json.JSONDecodeError) as error:
        _stop_swift_oracle_process()
        raise ValueError("trusted compiled Swift parity oracle failed closed") from error


def _ascii_words(value: str) -> list[str]:
    return [
        word
        for word in re.split(f"[{re.escape(_ASCII_SWIFT_WHITESPACE)}]+", value)
        if word
    ]


def _swift_text_metrics(value: str) -> tuple[int, int]:
    if value.isascii():
        return (
            len(_ascii_words(value)),
            sum(character not in _ASCII_SWIFT_WHITESPACE for character in value),
        )
    result = _decode_swift_json("text-metrics", value)
    if (
        not isinstance(result, dict)
        or set(result) != {"wordCount", "nonWhitespaceScalarCount"}
        or type(result["wordCount"]) is not int
        or type(result["nonWhitespaceScalarCount"]) is not int
        or result["wordCount"] < 0
        or result["nonWhitespaceScalarCount"] < 0
    ):
        _stop_swift_oracle_process()
        raise ValueError("trusted compiled Swift parity oracle failed closed")
    return result["wordCount"], result["nonWhitespaceScalarCount"]


def _swift_question_words(value: str) -> list[tuple[str, str]]:
    if value.isascii():
        words = _ascii_words(value.lower().strip(_ASCII_SWIFT_WHITESPACE))
        return [(word, word.strip(_ASCII_SWIFT_PUNCTUATION)) for word in words]
    result = _decode_swift_json("question-words", value)
    if not isinstance(result, list) or any(
        not isinstance(record, list)
        or len(record) != 2
        or any(not isinstance(item, str) for item in record)
        for record in result
    ):
        _stop_swift_oracle_process()
        raise ValueError("trusted compiled Swift parity oracle failed closed")
    return [(record[0], record[1]) for record in result]


def _swift_string_result(operation: str, value: str) -> str:
    if value.isascii():
        if operation == "trim-whitespace-newlines":
            return value.strip(_ASCII_SWIFT_WHITESPACE)
        if operation == "trim-whitespace-lowercase":
            return value.strip(_ASCII_SWIFT_WHITESPACES).lower()
        raise ValueError("unsupported Swift string operation")
    encoded = base64.b64encode(value.encode("utf-8"))
    if operation == "trim-whitespace-newlines":
        maximum_payload_bytes = max(64, len(encoded) + 64)
    elif operation == "trim-whitespace-lowercase":
        maximum_payload_bytes = max(4096, len(encoded) * 4 + 4096)
    else:
        raise ValueError("unsupported Swift string operation")
    payload = _query_swift_oracle(
        operation,
        value,
        maximum_payload_bytes=maximum_payload_bytes,
    )
    try:
        return base64.b64decode(payload, validate=True).decode("utf-8")
    except (UnicodeDecodeError, ValueError) as error:
        _stop_swift_oracle_process()
        raise ValueError("trusted compiled Swift parity oracle failed closed") from error


def _stop_swift_oracle_process() -> None:
    global _SWIFT_ORACLE_PROCESS
    process = _SWIFT_ORACLE_PROCESS
    _SWIFT_ORACLE_PROCESS = None
    if process is not None:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        if process.stdin is not None:
            process.stdin.close()
        if process.stdout is not None:
            process.stdout.close()


atexit.register(_stop_swift_oracle_process)


def input_would_bypass_polish(transcript: str, language: str) -> bool:
    """Mirror LLMPolishStep's language-aware ultra-short input bypass."""

    if language.lower() in UNSEGMENTED_LANGUAGE_CODES:
        return _swift_text_metrics(transcript)[1] < 10
    return _swift_text_metrics(transcript)[0] <= 3


def input_would_bypass_context(transcript: str, max_tokens: int) -> bool:
    return swift_character_count(transcript) + max_tokens + 256 > 16384


def looks_like_question(value: str) -> bool:
    if "?" in value:
        return True
    fillers = {"um", "uh", "so", "like", "well", "okay", "ok"}
    word_records = _swift_question_words(value)
    while word_records and word_records[0][1] in fillers:
        word_records.pop(0)
    if not word_records:
        return False
    words = [record[0] for record in word_records]
    auxiliary = {
        "should",
        "can",
        "do",
        "does",
        "did",
        "is",
        "are",
        "could",
        "would",
        "has",
        "have",
        "will",
    }
    if words[0] in auxiliary:
        return True
    if words[0] in {"how", "what", "where", "when", "who", "why"}:
        second = words[1] if len(words) > 1 else ""
        if second in auxiliary or second in {"many", "much", "long", "often"}:
            return True
    joined = " ".join(words[:5])
    return any(
        joined.startswith(prefix)
        for prefix in (
            "i was wondering if",
            "i'm wondering if",
            "wondering if",
            "whether we should",
            "do you know if",
            "is there a",
            "are we",
        )
    )


def apply_message_output_validation(polished: str, original: str) -> tuple[str, str | None]:
    """Mirror LLMPolishStep.validatePolishOutput for EG-1's message mode."""

    if not original:
        return polished, None
    expansion_threshold = max(swift_character_count(original) * 3, 200)
    if swift_character_count(polished) > expansion_threshold:
        return original, "expansion"
    original_word_count = _swift_text_metrics(original)[0]
    polished_word_count = _swift_text_metrics(polished)[0]
    drop_threshold = (original_word_count * 2 + 4) // 5
    if original_word_count >= 10 and polished_word_count < drop_threshold:
        return original, "content_drop"
    if looks_like_question(original) and not looks_like_question(polished):
        return original, "question_to_answer"
    return polished, None


def build_request_body(
    *, model: str, system: str, user: str, max_tokens: int
) -> dict[str, Any]:
    if type(max_tokens) is not int or max_tokens < MIN_OUTPUT_TOKENS:
        raise ValueError(f"max_tokens must be an integer >= {MIN_OUTPUT_TOKENS}")
    return {
        "model": model,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "max_tokens": max_tokens,
        "temperature": 0,
    }


def _first_line_looks_like_preamble(text: str) -> bool:
    first_line = text.split("\n", 1)[0]
    if (
        not first_line
        or swift_character_count(first_line) >= 100
        or not first_line.endswith(":")
    ):
        return False
    lowered = _swift_string_result("trim-whitespace-lowercase", first_line)
    return lowered.startswith(
        (
            "here",
            "below",
            "the corrected",
            "the cleaned",
            "the polished",
            "the rewritten",
            "corrected version",
            "cleaned",
            "polished",
        )
    )


def _first_sentence_is_standalone_reply(text: str) -> bool:
    if not text:
        return False
    first_sentence = ""
    for character in text:
        first_sentence += character
        if character in ".!?\n":
            break
    return (
        swift_character_count(first_sentence) <= 60
        and first_sentence.count(",") <= 1
    )


def strip_llm_preamble(content: str, *, strip_transcript_tags: bool = True) -> str:
    """Mirror String.strippingLLMPreamble v30 for EGOneConnector."""

    result = _swift_string_result("trim-whitespace-newlines", content)
    acknowledgments = (
        "Certainly!",
        "Sure!",
        "Sure,",
        "Of course!",
        "Got it.",
        "Got it!",
        "Absolutely!",
        "Here you go:",
    )
    for acknowledgment in acknowledgments:
        if result.startswith(acknowledgment):
            after = _swift_string_result(
                "trim-whitespace-newlines", result[len(acknowledgment) :]
            )
            if _first_line_looks_like_preamble(after) or _first_sentence_is_standalone_reply(
                after
            ):
                result = after
            break

    if _first_line_looks_like_preamble(result):
        result = _swift_string_result(
            "trim-whitespace-newlines", result.partition("\n")[2]
        )

    if strip_transcript_tags:
        result = _swift_string_result(
            "trim-whitespace-newlines",
            re.sub(r"</?transcript>", "", result, flags=re.IGNORECASE),
        )
    return result


def parse_success(payload: Any) -> tuple[str, str | None]:
    """Return cleaned content and finish reason or fail as the connector would."""

    if not isinstance(payload, dict):
        raise EG1ShippedResponseError("malformed_response")
    choices = payload.get("choices")
    if (
        not isinstance(choices, list)
        or not choices
        or any(not isinstance(choice, dict) for choice in choices)
    ):
        raise EG1ShippedResponseError("malformed_response")
    choice = choices[0]
    finish_reason = choice.get("finish_reason")
    if finish_reason == "length":
        raise EG1ShippedResponseError("output_truncated")
    message = choice.get("message")
    if not isinstance(message, dict):
        raise EG1ShippedResponseError("malformed_response")
    content = message.get("content")
    if not isinstance(content, str) or not content:
        raise EG1ShippedResponseError("empty_response")
    cleaned = strip_llm_preamble(content, strip_transcript_tags=True)
    if not cleaned:
        raise EG1ShippedResponseError("empty_after_cleanup")
    return cleaned, finish_reason if isinstance(finish_reason, str) else None
