// Independent literal wire fixtures shared by policy and endpoint checks.
const ENV = { SENTRY_AUTH_TOKEN: "fixture-token", SENTRY_ORG: "envious-labs-llc", SENTRY_PROJECT_ID: "4511097112428544", SENTRY_PROJECT_SLUG: "enviouswispr" };
const WINDOW = { startISO: "2026-10-07T04:00:00", endISO: "2026-10-08T04:00:00", priorStartISO: "2026-10-06T04:00:00" };
const ISSUE_META = { "issue.id": "integer", environment: "string", "app.build_type": "string", "count()": "integer", "count_unique(user)": "integer" };
const HEAD_META = { environment: "string", "app.build_type": "string", "count()": "integer", "count_unique(user)": "integer" };
const MATRIX_META = { "issue.id": "integer", environment: "string", "app.build_type": "string", release: "string", "error.category": "string", level: "string", "count()": "integer" };
const problem = (id, n, u, environment = "production", build = "release") => ({
  "issue.id": id, issue: "ENVIOUSWISPR-" + id, environment, "app.build_type": build, "count()": n, "count_unique(user)": u,
});
const head = (n, u, environment = "production", build = "release") => ({ environment, "app.build_type": build, "count()": n, "count_unique(user)": u });
const detail = (id, n, environment = "production", build = "release", release = "com.enviouswispr.app@2.5.3") => ({
  "issue.id": id, issue: "ENVIOUSWISPR-" + id, environment, "app.build_type": build,
  "count()": n, "error.category": "asr_failed", level: "error", release,
});

function rig(overrides = {}) {
  const data = {
    current: [problem(1, 5, 2)], prior: [problem(1, 2, 1)], matrix: [detail(1, 5)],
    currentHead: [head(5, 2)], priorHead: [head(2, 1)], firstSeen: [], ...overrides,
  };
  const requests = [];
  let active = 0;
  let peak = 0;
  const fetchFn = async (target) => {
    const url = new URL(target); requests.push(url);
    active += 1; peak = Math.max(peak, active);
    await Promise.resolve(); active -= 1;
    const prior = url.searchParams.get("start") === WINDOW.priorStartISO;
    const fields = url.searchParams.getAll("field");
    const kind = url.pathname.includes("/projects/") ? "firstSeen"
      : fields.includes("release") ? "matrix"
        : fields.includes("issue") ? (prior ? "prior" : "current")
          : prior ? "priorHead" : "currentHead";
    const key = kind + (url.searchParams.has("cursor") ? "Page2" : "");
    const rows = data[key] ?? data[kind];
    const meta = kind === "matrix" ? MATRIX_META : kind.endsWith("Head") ? HEAD_META : ISSUE_META;
    const headers = {};
    if (data[key + "Link"]) {
      headers.Link = typeof data[key + "Link"] === "function" ? data[key + "Link"](url) : data[key + "Link"];
    }
    if (data[key + "Status"]) return new Response("failure", { status: data[key + "Status"] });
    return new Response(JSON.stringify(kind === "firstSeen" ? rows : { data: rows, meta: { fields: data[key + "Meta"] ?? meta } }), { headers });
  };
  return { data, requests, opts: { workerLabel: "writeup_test", fetchFn, sleepFn: async () => {} }, peak: () => peak };
}

export { ENV, WINDOW, problem, head, detail, rig };
