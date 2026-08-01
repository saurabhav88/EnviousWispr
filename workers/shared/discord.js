/**
 * Discord delivery, shared by every worker that posts a report (issues #1838,
 * #1589).
 *
 * CONSUMERS: workers/daily-report, workers/weekly-digest.
 *
 * DEPLOY RULE: each worker bundles its own copy at deploy time, so editing this
 * file changes nothing in production until EVERY consumer is redeployed. See
 * workers/shared/README.md.
 *
 * Infrastructure only. It owns Discord's transport limits and the SUPPORTED
 * SUBSET of its payload protocol, and knows nothing about adoption, releases,
 * digests or metrics. It must never refuse a field Discord accepts merely
 * because one consumer does not use it (#1589).
 *
 * ONE function validates and sends the SAME object, deliberately. A separate
 * `validate()` returning a boolean would let a caller check one payload and
 * send another, which is the accepted-form-versus-consumed-form defect this
 * issue reproduced five times in one chunk. There is no exported validator.
 *
 * The report is sent whole or not at all. Discord's caps are hard limits, so a
 * payload that will not fit is a defect in what we built, not a reason to
 * truncate: a silently shortened report reads as complete, which is worse than
 * a missing one. Over-budget therefore throws BEFORE any request.
 *
 * Privacy: never logs or returns a payload, a webhook URL, or a Discord
 * response body.
 */

/** Rejected before any network request: the payload could not be sent as-is. */
export class DiscordPayloadError extends Error {
  constructor(message) {
    super(message);
    this.name = "DiscordPayloadError";
  }
}

/** The one attempted request failed. There is no retry: a daily digest that
 * arrives twice is worse than one that arrives tomorrow. */
export class DiscordDeliveryError extends Error {
  constructor(message) {
    super(message);
    this.name = "DiscordDeliveryError";
  }
}

/** Discord's documented caps. `combinedText` is the sum across ALL embeds. */
export const DISCORD_LIMITS = Object.freeze({
  content: 2000,
  embedTitle: 256,
  embedDescription: 4096,
  embedFooterText: 2048,
  embeds: 10,
  combinedText: 6000,
});

/** The SUPPORTED SUBSET of Discord's embed fields. Not all of them: this module
 * does not implement `fields`, `author`, `image`, or `thumbnail`, and does not
 * claim to.
 *
 * Any own key outside this set is refused rather than passed through, because
 * `combinedText` must count every TEXTUAL field actually sent, and a field this
 * module does not know about is a field it cannot count. Refusing is the only
 * way that arithmetic stays true.
 *
 * WHY THIS SET IS NOT JUST {title, description} (#1589): it was, and that made
 * the shared validator impose the daily report's LAYOUT CHOICE on every other
 * worker. Discord permits `color`, `footer` and `timestamp`; refusing them was
 * never a protocol limit, and it would have forced the weekly digest to drop its
 * brand colour to reuse this transport. A shared module owns the protocol, not
 * the presentation. Adding a field here means teaching `embedTextLength` to
 * count it, or proving it costs nothing against the budget. */
const ALLOWED_EMBED_FIELDS = new Set(["title", "description", "color", "footer", "timestamp"]);
const ALLOWED_PAYLOAD_FIELDS = new Set(["content", "embeds"]);

/** Fields Discord counts toward the 6000-character combined budget: embed
 * titles, descriptions, field names/values, footer text, and author name. Colour
 * and timestamp are NOT text and cost nothing against it. */
const ALLOWED_FOOTER_FIELDS = new Set(["text"]);

/** ISO 8601 with a required date and time, and either `Z` or an explicit
 * offset. Discord documents `timestamp` as ISO 8601; anything else is a payload
 * it may reject, so it is refused here rather than sent. */
const ISO_8601 = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,9})?(Z|[+-]\d{2}:\d{2})$/;

/** THE RULE THIS FILE EXISTS TO ENFORCE: validation must observe exactly what
 * `JSON.stringify` will observe.
 *
 * A plain property read and a serialization are two DIFFERENT consumption
 * mechanisms. `JSON.stringify` calls `toJSON` if one exists, and it invokes
 * getters - so a payload can pass every check here and put entirely different
 * bytes on the wire. A `toJSON` returning 3,000 characters of content and no
 * embeds passed the previous version of this validator.
 *
 * So every read below demands an own DATA property (never an accessor), every
 * container must have an ordinary prototype (so no inherited `toJSON`), and
 * every own key must be one this module knows how to count. Anything else is
 * refused rather than sent. */
function assertAllowedOwnFields(object, allowed, label) {
  // Reflect.ownKeys, not Object.keys: a non-enumerable or symbol-keyed field is
  // invisible to Object.keys and can still change what is serialized.
  for (const key of Reflect.ownKeys(object)) {
    if (typeof key !== "string" || !allowed.has(key)) {
      throw new DiscordPayloadError(`${label}: unsupported field ${String(key)}`);
    }
  }
}

function ownDataValue(object, field, label) {
  const descriptor = Object.getOwnPropertyDescriptor(object, field);
  if (!descriptor) {
    throw new DiscordPayloadError(`${label}: missing own property ${field}`);
  }
  if (!Object.hasOwn(descriptor, "value")) {
    // An accessor can return one value to the validator and another to
    // JSON.stringify. There is no way to check such a property once.
    throw new DiscordPayloadError(`${label}: ${field} must be a data property`);
  }
  if (descriptor.enumerable !== true) {
    // JSON.stringify serializes only ENUMERABLE own properties of an object, so
    // a non-enumerable `content` validates perfectly and is then simply absent
    // from the body - the report silently loses a field it was checked to have.
    throw new DiscordPayloadError(`${label}: ${field} must be enumerable`);
  }
  return descriptor.value;
}

function ownString(object, field, label, max) {
  const value = ownDataValue(object, field, label);
  if (typeof value !== "string") {
    throw new DiscordPayloadError(`${label}: ${field} must be a string`);
  }
  if (value.length === 0) {
    throw new DiscordPayloadError(`${label}: ${field} must not be empty`);
  }
  if (value.length > max) {
    throw new DiscordPayloadError(`${label}: ${field} is ${value.length} characters, over the ${max} limit`);
  }
  return value;
}

function isPlainObject(value) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    return false;
  }
  // An exotic prototype can supply toJSON or accessors that this module would
  // never see through own-property checks alone. And knowing WHICH prototype is
  // in use is not the same as knowing it is clean: `Object.prototype.toJSON` is
  // writable, so an ordinary object can inherit a serialization hook that
  // replaces the whole payload. `in` walks the chain, which is the point.
  const prototype = Object.getPrototypeOf(value);
  return (prototype === Object.prototype || prototype === null) && !("toJSON" in value);
}

function assertOrdinaryDenseArray(value, label) {
  if (!Array.isArray(value) || Object.getPrototypeOf(value) !== Array.prototype) {
    throw new DiscordPayloadError(`${label} must be an ordinary array`);
  }
  // Array.prototype is writable too: a toJSON there turns the validated embed
  // list into whatever it returns, with every own-property check still passing.
  if ("toJSON" in value) {
    throw new DiscordPayloadError(`${label} must not inherit or own toJSON`);
  }
  const allowed = new Set(["length"]);
  for (let i = 0; i < value.length; i += 1) {
    const key = String(i);
    allowed.add(key);
    const descriptor = Object.getOwnPropertyDescriptor(value, key);
    if (!descriptor || !Object.hasOwn(descriptor, "value")) {
      throw new DiscordPayloadError(`${label}: index ${i} must be an own data property`);
    }
  }
  assertAllowedOwnFields(value, allowed, label);
}

/** Throws unless `payload` can be sent exactly as it stands. No coercion, no
 * defaulting, no trimming: every rejection below is a case where sending
 * something OTHER than what the caller built would have been the alternative. */
function assertDeliverable(payload) {
  if (!isPlainObject(payload)) {
    throw new DiscordPayloadError("payload must be a plain object");
  }
  assertAllowedOwnFields(payload, ALLOWED_PAYLOAD_FIELDS, "payload");

  const content = ownString(payload, "content", "payload", DISCORD_LIMITS.content);

  if (!Object.hasOwn(payload, "embeds")) {
    // Content-only is the fixed failure notice, not the daily report. The
    // report's own two-embed shape is the caller's contract to keep.
    return content;
  }

  const embeds = ownDataValue(payload, "embeds", "payload");
  assertOrdinaryDenseArray(embeds, "payload: embeds");

  if (embeds.length === 0) {
    throw new DiscordPayloadError("payload: embeds must not be empty when present");
  }
  if (embeds.length > DISCORD_LIMITS.embeds) {
    throw new DiscordPayloadError(
      `payload: ${embeds.length} embeds exceeds the ${DISCORD_LIMITS.embeds} limit`
    );
  }

  let combined = 0;
  for (let i = 0; i < embeds.length; i += 1) {
    const embed = ownDataValue(embeds, String(i), "payload: embeds");
    if (!isPlainObject(embed)) {
      throw new DiscordPayloadError(`embed ${i} must be a plain object`);
    }
    assertAllowedOwnFields(embed, ALLOWED_EMBED_FIELDS, `embed ${i}`);

    const title = ownString(embed, "title", `embed ${i}`, DISCORD_LIMITS.embedTitle);
    const description = ownString(embed, "description", `embed ${i}`, DISCORD_LIMITS.embedDescription);
    combined += title.length + description.length;

    // Optional fields. Each is read EXACTLY ONCE through the same own-data-
    // property discipline as the required ones, so a getter cannot answer one
    // value here and another to JSON.stringify.
    if (Object.hasOwn(embed, "color")) {
      const color = ownDataValue(embed, "color", `embed ${i}`);
      // Discord rejects a non-integer or out-of-range colour outright, so this
      // refuses before the request rather than after.
      if (!Number.isInteger(color) || color < 0 || color > 0xffffff) {
        throw new DiscordPayloadError(`embed ${i}: color must be an integer between 0 and 16777215`);
      }
    }
    if (Object.hasOwn(embed, "timestamp")) {
      const timestamp = ownDataValue(embed, "timestamp", `embed ${i}`);
      // `Date.parse` alone is far too permissive to be a format check: it
      // accepts "1" (as the year 2001), "Dec 25", and other shapes Discord
      // rejects. Discord wants ISO 8601, so the SHAPE is checked first and
      // Date.parse only then confirms the values are a real instant.
      if (
        typeof timestamp !== "string" ||
        !ISO_8601.test(timestamp) ||
        Number.isNaN(Date.parse(timestamp))
      ) {
        throw new DiscordPayloadError(`embed ${i}: timestamp must be an ISO 8601 string`);
      }
    }
    if (Object.hasOwn(embed, "footer")) {
      const footer = ownDataValue(embed, "footer", `embed ${i}`);
      if (!isPlainObject(footer)) {
        throw new DiscordPayloadError(`embed ${i}: footer must be a plain object`);
      }
      assertAllowedOwnFields(footer, ALLOWED_FOOTER_FIELDS, `embed ${i}: footer`);
      // Counted, because Discord counts it. This is the whole reason the
      // allowlist exists: a permitted textual field that went uncounted would
      // silently break the 6000-character arithmetic.
      combined += ownString(footer, "text", `embed ${i}: footer`, DISCORD_LIMITS.embedFooterText).length;
    }
  }

  if (combined > DISCORD_LIMITS.combinedText) {
    throw new DiscordPayloadError(
      `payload: ${combined} characters of embed text exceeds the ${DISCORD_LIMITS.combinedText} limit`
    );
  }
  return content;
}

/**
 * Validates and sends `payload` in exactly ONE request, one attempt.
 *
 * The object validated above is the object serialized below - there is no
 * intermediate copy, and no way for a caller to reach the validator without
 * also reaching the request.
 */
export async function deliverReport(webhookUrl, payload, { fetchFn = fetch } = {}) {
  if (typeof webhookUrl !== "string" || webhookUrl.length === 0) {
    throw new DiscordPayloadError("webhook URL is missing");
  }
  assertDeliverable(payload);

  const res = await fetchFn(webhookUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });

  // Discord answers a webhook with 204, or 200 when `wait` is requested.
  // Anything else - including a redirect or a 2xx we do not recognise - is a
  // failure, never an assumed success.
  const status = res?.status;
  if (status !== 200 && status !== 204) {
    throw new DiscordDeliveryError(`Discord rejected the report: HTTP ${String(status)}`);
  }
}
