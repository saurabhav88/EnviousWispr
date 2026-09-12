// Recording cases for the File Transcription deck (#2816). The five case
// records and their transcript JSON are the approved measured data, copied
// verbatim from the mock (data/recording-cases.json, dist/transcripts/*).
//
// Transcript files are emitted as hashed assets under /_astro/ (?url&no-inline
// forces a file even though Vite would inline small ones) and fetched by the
// deck only when it comes into view. Card 0's numbers and first passages are
// also imported here so the page renders real evidence at build time.
import records from './recording-cases.json';
import t1 from './transcripts/1-emma-chamberlain-like-literally.json?url&no-inline';
import t2 from './transcripts/2-ariana-grande-zach-sang-2018.json?url&no-inline';
import t3 from './transcripts/3-kendall-jenner-jay-shetty.json?url&no-inline';
import t4 from './transcripts/4-elon-musk-jre-1470.json?url&no-inline';
import t5 from './transcripts/5-zuckerberg-senate-testimony-3hr.json?url&no-inline';
import firstCard from './transcripts/4-elon-musk-jre-1470.json';

const urls = {
  'transcripts/1-emma-chamberlain-like-literally.json': t1,
  'transcripts/2-ariana-grande-zach-sang-2018.json': t2,
  'transcripts/3-kendall-jenner-jay-shetty.json': t3,
  'transcripts/4-elon-musk-jre-1470.json': t4,
  'transcripts/5-zuckerberg-senate-testimony-3hr.json': t5,
};

export const cases = records.map((record) => {
  const transcript = urls[record.transcript];
  if (!transcript) throw new Error(`cases: no emitted transcript for ${record.transcript}`);
  return { ...record, transcript, id: record.transcript.match(/transcripts\/(.+)\.json$/)[1] };
});

export const stamp = (seconds) => {
  const s = Math.floor(seconds);
  return (s >= 3600 ? Math.floor(s / 3600) + ':' : '') + String(Math.floor(s / 60) % 60).padStart(2, '0') + ':' + String(s % 60).padStart(2, '0');
};

/** Build-time evidence for the first card: real numbers and the opening passages. */
export const firstCardEvidence = {
  id: String(firstCard.id ?? cases[0].id),
  wordCount: firstCard.wordCount,
  umUhRemoved: firstCard.umUhRemoved,
  polishMs: firstCard.polishMs,
  provenance: firstCard.provenance,
  passages: firstCard.passages.slice(0, 8).map((p) => ({
    start: p.start,
    end: p.end,
    raw: p.raw,
    polished: p.polished,
    polishSucceeded: p.polishSucceeded,
    diff: p.diff,
  })),
  passageCount: firstCard.passages.length,
};
