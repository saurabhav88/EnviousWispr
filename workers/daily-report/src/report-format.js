/**
 * Version-scorecard presentation (issue #1838 chunk 5).
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
 * no colours, no healthy/unhealthy states, and no better/worse language. Movers
 * are ranked changes, explicitly labelled as not alerts; their job is to guide
 * the eye, not to render a verdict.
 */

const ROW_LABELS = {
  people: "People",
  dictations: "Dictations",
  speed_p50: "Typical speed",
  speed_p95: "Slowest 5%",
  autopaste_direct: "Auto-paste landed directly",
  polish_kept: "Polish kept",
  // Never "Transcription failed", and never speech-engine reliability: the app
  // stamps EVERY terminal failure with the transcription stage, including
  // no-microphone and permission failures, so that label would send someone
  // chasing the speech engine for a microphone bug.
  transcription_failed: "Dictations ending without a completed transcript",
};

const pct = (v) => `${(v * 100).toFixed(1)}%`;
const secs = (v) => `${v.toFixed(2)}s`;
const render = (value, unit) =>
  value === null || value === undefined
    ? "not enough data"
    : unit === "seconds"
      ? secs(value)
      : unit === "share"
        ? pct(value)
        : String(value);

function requireNumber(value, label) {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    throw new TypeError(`${label} must be a finite number, got ${String(value)}`);
  }
  return value;
}

/** One deterministic scorecard section, as an array of lines. */
export function formatScorecard({ ranking }) {
  if (!ranking || !Array.isArray(ranking.rows) || !(ranking.ages instanceof Map) ||
      !ranking.summary || !Array.isArray(ranking.summary.releases)) {
    throw new TypeError("formatScorecard requires ranking.rows, ranking.ages and ranking.summary");
  }
  const lines = [];
  // The formatter takes ONLY the ranking. It has no access to the raw selection
  // at all, so a raw tag form, a stale coverage figure or a stale cap flag
  // cannot reach the page - the previous shape merely asked it not to look.
  const { releases, coverage, capReached, minVersion } = ranking.summary;
  requireNumber(coverage, "ranking.summary.coverage");
  if (typeof minVersion !== "string" || minVersion.length === 0) {
    throw new TypeError(`ranking.summary.minVersion must be a version string, got ${String(minVersion)}`);
  }

  lines.push("Version scorecard, last 7 complete Eastern days");
  lines.push(
    `Covering ${pct(coverage)} of measured dictations across ` +
      `${releases.length} release${releases.length === 1 ? "" : "s"}.`
  );
  lines.push("The newest release is always included, whatever its share.");
  lines.push(
    `Builds before ${minVersion} are not measured: they did not record every reason ` +
      "polished text was rejected, so their score would read a false 100%."
  );
  if (capReached) lines.push("4-version cap reached before the coverage target.");
  lines.push("People counts are non-additive: one person can appear under more than one release.");

  for (const r of releases) {
    if (!ranking.ages.has(r.version)) {
      // Never defaulted to zero: a missing age would print a confident
      // "0/7 days publicly available" for a release we simply failed to measure.
      throw new TypeError(`ranking.ages is missing release ${r.version}`);
    }
    lines.push(
      `${r.version}: ${ranking.ages.get(r.version)}/7 days publicly available` +
        (r.observed ? "" : ", no production data yet")
    );
  }
  lines.push("");

  for (const row of ranking.rows) {
    const cells = row.cells.map((c) => `${c.version} ${render(c.value, row.unit)}`);
    lines.push(`${ROW_LABELS[row.metricKey]}: ${cells.join("  |  ")}`);

    if (row.metricKey === "dictations") {
      lines.push(
        "  " +
          row.cells
            .map((c) =>
              c.shareOfWindow === null
                ? `${c.version} share unavailable`
                : `${c.version} ${pct(c.shareOfWindow)} of the measured week`
            )
            .join("  |  ")
      );
    }
    if (row.metricKey === "polish_kept") {
      lines.push(
        "  " +
          row.cells
            .map((c) =>
              c.classifierDiscards === null
                ? `${c.version} breakdown unavailable`
                : `${c.version} ${c.classifierDiscards} by the safety classifier, ` +
                  `${c.otherDiscards} by other checks`
            )
            .join("  |  ")
      );
    }
    // A non-comparable row still PRINTS, with the reason in plain words. Hiding
    // it leaves a silent gap; drawing a comparison across it would be a lie.
    if (!row.comparable) lines.push(`  not compared, ${row.reason}`);
  }

  lines.push("");
  lines.push(...formatMovers(ranking));
  return lines;
}

function formatMovers(ranking) {
  const lines = ["Ranked changes (these are ranked changes, not alerts):"];
  if (ranking.movers.length === 0) {
    // Not "nothing changed": with one release, or insufficient history, there
    // was nothing rankable to begin with, which is a different statement.
    lines.push("  No comparable ranked changes were available.");
    return lines;
  }
  for (const m of ranking.movers) {
    const unit = m.unit === "seconds" ? secs : pct;
    const sign = m.signedDifference >= 0 ? "up" : "down";
    lines.push(
      `  ${ROW_LABELS[m.metricKey]}: ${m.newestVersion} ${unit(m.newestValue)} ` +
        `vs ${m.previousVersion} ${unit(m.previousValue)}, ${sign} ` +
        `${unit(Math.abs(m.signedDifference))} ` +
        `(${m.newestSamples} and ${m.previousSamples} samples).`
    );
    lines.push(
      m.basis === "median-historical-movement"
        ? "    Ranked against this measure's median week-to-week movement."
        : `    Ranked by size of change only, ${m.fallbackReason}.`
    );
  }
  return lines;
}

/** Plain-language scorecard-unavailable copy, owned here so the integration
 * chunk never authors new failure wording. Deliberately discloses nothing
 * technical: no error text, URL, status code or response body. */
export function formatScorecardUnavailable() {
  return [
    "Version scorecard, unavailable today.",
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
