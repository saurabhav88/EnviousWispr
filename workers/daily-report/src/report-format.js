/**
 * Version-scorecard presentation (issue #1838 chunk 5, reshaped by #2621).
 *
 * Sole owner of every scorecard sentence the founder reads, and NOTHING else.
 * It imports no metric authority: row order, units, comparability, values,
 * shares and the polish split all arrive already decided on `ranking.rows`.
 * Importing METRIC_CALCULATIONS or decideComparability here would make this a
 * second authority that could silently disagree with the ranker.
 *
 * The report is a SCORECARD, not an alarm. Defect detection is already owned by
 * the twice-daily Sentry triage routines, and the previous threshold-alarm shape
 * is exactly what made this report useless to its one reader. So: no thresholds,
 * no colours, no healthy/unhealthy states, and no better/worse language. The
 * biggest shifts are named to guide the eye, never to render a verdict.
 *
 * #2621: the page carries NUMBERS and nothing that explains method. The founder
 * read the previous shape as "too much information I can't make heads or tails
 * of": four lines of method before the first number, two versions packed into
 * every row, sub-lines under rows, sample counts and a ranking basis under every
 * mover. Every one of those facts still exists - coverage, the measurement
 * floor, non-additive people, the polish split, the mover basis - and the
 * worker README owns their explanation. The page shows one comparison in plain
 * words. A footnote states coverage in one sentence because it is the one
 * method fact that changes how much the numbers mean.
 */

const ROW_LABELS = {
  people: "People",
  dictations: "Dictations",
  speed_p50: "Typical speed",
  speed_p95: "Slowest 5%",
  autopaste_direct: "Auto-paste worked",
  // Apple Intelligence attempts only (METRIC_CALCULATIONS.polish_kept's
  // population), so the label must not read as every polish provider.
  polish_kept: "Apple polish kept",
  // Never "Transcription failed", and never speech-engine reliability: the app
  // stamps EVERY terminal failure with the transcription stage, including
  // no-microphone and permission failures, so that label would send someone
  // chasing the speech engine for a microphone bug. "Failed dictations" names
  // the outcome the user had, whatever stage produced it.
  transcription_failed: "Failed dictations",
};

const pct = (v) => `${(v * 100).toFixed(1)}%`;
const secs = (v) => `${v.toFixed(2)}s`;
// Explicit locale: a Worker's default locale is not something a reader can
// see, and "9902" against "9,902" is the difference between a glance and a
// count. Counts are integers; a fractional count would be a producer defect
// and prints as-is rather than being rounded into a lie.
const count = (v) => new Intl.NumberFormat("en-US").format(v);
const render = (value, unit) =>
  value === null || value === undefined
    ? "no data"
    : unit === "seconds"
      ? secs(value)
      : unit === "share"
        ? pct(value)
        : count(value);

function requireNumber(value, label) {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    throw new TypeError(`${label} must be a finite number, got ${String(value)}`);
  }
  return value;
}

/** One release's name for the header: the version, plus the one fact about it
 * that changes how to read its column. Under a week old says how many days it
 * has been out; no data yet says so instead of a column of "no data" being the
 * only clue. A release out the whole week is just its version. */
function releaseHeading(release, age) {
  if (!Number.isInteger(age) || age < 0) {
    throw new TypeError(`release age must be a non-negative integer, got ${String(age)}`);
  }
  if (!release.observed) return `${release.version} (no data yet)`;
  if (age === 0) return `${release.version} (out today)`;
  if (age < 7) return `${release.version} (out ${age} ${age === 1 ? "day" : "days"})`;
  return release.version;
}

/** One deterministic scorecard section, as an array of lines. */
export function formatScorecard({ ranking }) {
  if (!ranking || !Array.isArray(ranking.rows) || !(ranking.ages instanceof Map) ||
      !ranking.summary || !Array.isArray(ranking.summary.releases)) {
    throw new TypeError("formatScorecard requires ranking.rows, ranking.ages and ranking.summary");
  }
  // The formatter takes ONLY the ranking. It has no access to the raw selection
  // at all, so a raw tag form, a stale coverage figure or a stale cap flag
  // cannot reach the page - the previous shape merely asked it not to look.
  const { releases, coverage } = ranking.summary;
  requireNumber(coverage, "ranking.summary.coverage");

  const lines = ["Version check, last 7 days"];
  lines.push(
    releases
      .map((r) => {
        if (!ranking.ages.has(r.version)) {
          // Never defaulted to zero: a missing age would print a confident
          // "out 0 days" for a release we simply failed to measure.
          throw new TypeError(`ranking.ages is missing release ${r.version}`);
        }
        return releaseHeading(r, ranking.ages.get(r.version));
      })
      .join(" vs ")
  );
  lines.push("");

  for (const row of ranking.rows) {
    // Cells in header order, so the reader never needs a version prefix on
    // every number: the header names the columns once.
    // A non-comparable row still PRINTS, with the reason in plain words. Hiding
    // it leaves a silent gap; drawing a comparison across it would be a lie -
    // so its cells are separated by a bar, never by "vs".
    const cells = row.cells.map((c) => render(c.value, row.unit)).join(row.comparable ? " vs " : " | ");
    const caveat = row.comparable ? "" : ` (not compared: ${row.reason})`;
    lines.push(`${ROW_LABELS[row.metricKey]}: ${cells}${caveat}`);
  }

  lines.push("");
  lines.push(formatShifts(ranking));
  lines.push(
    `${releases.length === 1 ? "This version covers" : `These ${releases.length} versions cover`} ` +
      `${pct(coverage)} of measured dictations this week.`
  );
  return lines;
}

/** The biggest shifts between the two newest releases, as one sentence. The
 * ranker decided which rows and in what order; this names them "from X to Y",
 * which is the whole fact, with no verdict attached. */
function formatShifts(ranking) {
  if (ranking.movers.length === 0) {
    // Not "nothing changed": with one release, or insufficient history, there
    // was nothing rankable to begin with, which is a different statement.
    return "Biggest shifts: nothing to rank yet.";
  }
  // Every mover the ranker handed over is printed: which rows are movers, and
  // in what order, is the ranker's decision alone (it already drops a measure
  // that did not move).
  const parts = ranking.movers.map((m) => {
    const unit = m.unit === "seconds" ? secs : pct;
    return `${ROW_LABELS[m.metricKey]} ${unit(m.previousValue)} to ${unit(m.newestValue)}`;
  });
  return `Biggest shifts: ${parts.join("; ")}.`;
}

/** Plain-language scorecard-unavailable copy, owned here so the integration
 * chunk never authors new failure wording. Deliberately discloses nothing
 * technical: no error text, URL, status code or response body. */
export function formatScorecardUnavailable() {
  return [
    "Version check, unavailable today.",
    "Version measurements could not be completed, so this is not a report of zero.",
  ];
}

/** The adoption twin of the above. Both unavailable messages live here, in one
 * place, so a failing section can never be described in two different voices
 * depending on which half broke. Says nothing was measured rather than letting
 * a missing section read as a quiet zero.
 *
 * Neither message comments on the OTHER section. Both can fail in the same run,
 * and cross-references then produce a report in which each half calmly reports
 * the other as unaffected. A section describes only itself. */
export function formatAdoptionUnavailable() {
  return [
    "Adoption, unavailable today.",
    "Yesterday's figures could not be measured, so this is not a report of zero.",
  ];
}
