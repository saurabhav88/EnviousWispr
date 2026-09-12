// AI Polished Dictation page evidence (#2816), from the mock's
// english-polish-benchmark.json (build-time rows) and its hard-coded speed
// cards and highlight tiles. Numbers are the approved measured values.
import data from './english-polish-benchmark.json';

export const benchmark = data;

export const highlights = [
  { label: 'EG-1 v2 overall', value: '90.3%', note: 'Pass + minor, across 1,462 cases' },
  { label: 'EG-1 self-corrections', value: '77.6%', note: 'Across 219 correction cases' },
  { label: 'S1-mini median polish', value: '87 ms', note: 'Single-request text cleanup' },
];

export const speedCards = [
  { name: 'EG-1 v2', median: '312', p95: '606 ms at p95' },
  { name: 'S1-mini', median: '87', p95: '176 ms at p95' },
  { name: 'Fluid-1', median: '267', p95: '1,746 ms at p95' },
];

export const runDate = 'August 26, 2026';
export const provenanceLine = ['Our archived test · M5 Max · 64 GB · macOS 26', 'EG-1 v2 · S1-mini in lists mode · Fluid-1 with reasoning'];
export const benchmarkRecordUrl = '/features/benchmark-record.json';
