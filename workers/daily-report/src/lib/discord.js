/**
 * Discord delivery for the daily report (issue #1838 chunk 6).
 *
 * Infrastructure only. It knows Discord's transport limits and nothing about
 * adoption, releases or metrics.
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
  embeds: 10,
  combinedText: 6000,
});

/** Embeds may carry only these two textual fields. Any other own key is
 * refused rather than passed through: `combinedText` must count every textual
 * field ACTUALLY SENT, and a field this module does not know about is a field
 * it cannot count. Refusing is the only way that arithmetic stays true. */
const ALLOWED_EMBED_FIELDS = new Set(["title", "description"]);
const ALLOWED_PAYLOAD_FIELDS = new Set(["content", "embeds"]);

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
