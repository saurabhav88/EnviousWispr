/**
 * Direct tests for the shared run-log reader (#4353 PR 5). The digest tests
 * cover both sections through runDigest; these cover only what the reader
 * itself promises its callers: an explicit read policy, and nothing silently
 * defaulted.
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { readNewestReceipt } from "../src/run-log.js";

const base = {
  fetchFn: async () => { throw new Error("must not be called"); },
  repo: "saurabhav88/EnviousWispr",
  issue: "1",
  token: undefined,
  login: "writer",
  now: new Date("2026-08-03T13:00:00Z"),
  oldestMs: null,
  pages: { mode: "all", maxPages: 2 },
  parse: () => null,
};

test("the reader refuses a missing or unknown pages policy before any request", async () => {
  for (const pages of [undefined, {}, { mode: "every" }, { mode: "all" }, { mode: "all", maxPages: 0 }, { mode: "all", maxPages: 1.5 }]) {
    await assert.rejects(() => readNewestReceipt({ ...base, pages }), TypeError, JSON.stringify(pages));
  }
});

test("the reader refuses a missing writer, parser, now or window before any request", async () => {
  for (const patch of [{ login: "" }, { login: undefined }, { parse: undefined }, { now: new Date("x") }, { oldestMs: undefined }]) {
    await assert.rejects(() => readNewestReceipt({ ...base, ...patch }), TypeError, JSON.stringify(Object.keys(patch)));
  }
});
