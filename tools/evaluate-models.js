#!/usr/bin/env node
/**
 * Fail-closed, preflight evaluator for candidate text models.
 *
 * A model command receives one JSON request on stdin and must write its answer
 * to stdout. The production prompt is deliberately not accepted by this tool.
 */
'use strict';

const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');
const crypto = require('crypto');

function die(message) { console.error(`evaluate-models: ${message}`); process.exit(2); }
function readJson(file) { try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (e) { die(`${file}: ${e.message}`); } }
function argsOf(argv) {
  const out = { models: null, suite: null, output: 'evaluation-report.json', includeOutputs: false, seed: 17 };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--include-outputs') out.includeOutputs = true;
    else if (a === '--models') out.models = argv[++i];
    else if (a === '--suite') out.suite = argv[++i];
    else if (a === '--output') out.output = argv[++i];
    else if (a === '--seed') out.seed = Number(argv[++i]);
    else if (a === '--help') { console.log('Usage: node tools/evaluate-models.js --models models.json --suite suite.json [--output report.json] [--include-outputs]'); process.exit(0); }
    else die(`unknown argument ${a}`);
  }
  if (!out.models || !out.suite) die('--models and --suite are required');
  return out;
}
function hash(s) { return crypto.createHash('sha256').update(s).digest('hex').slice(0, 16); }
function shuffle(items, seed) {
  const a = items.slice(); let x = (seed >>> 0) || 1;
  for (let i = a.length - 1; i > 0; i--) { x = (1664525 * x + 1013904223) >>> 0; const j = x % (i + 1); [a[i], a[j]] = [a[j], a[i]]; }
  return a;
}
function normalize(v) { return String(v).trim().toLowerCase().replace(/\s+/g, ' '); }
function scoreCase(test, answer) {
  const text = String(answer || '');
  if (test.must_not_match && test.must_not_match.some(p => new RegExp(p, 'is').test(text))) return { score: 0, reason: 'forbidden pattern matched' };
  if (test.must_include && !test.must_include.every(s => text.toLowerCase().includes(String(s).toLowerCase()))) return { score: 0, reason: 'required evidence missing' };
  if (test.type === 'exact') return normalize(text) === normalize(test.expected) ? { score: 1, reason: 'exact match' } : { score: 0, reason: 'wrong answer' };
  if (test.type === 'includes') return test.expected.every(s => text.toLowerCase().includes(String(s).toLowerCase())) ? { score: 1, reason: 'all required terms present' } : { score: 0, reason: 'required term missing' };
  if (test.type === 'regex') return new RegExp(test.expected, 'is').test(text) ? { score: 1, reason: 'pattern matched' } : { score: 0, reason: 'pattern did not match' };
  if (test.type === 'json') {
    try {
      const got = JSON.parse(text); const expected = test.expected;
      const ok = Object.keys(expected).every(k => JSON.stringify(got[k]) === JSON.stringify(expected[k]));
      return ok ? { score: 1, reason: 'JSON fields matched' } : { score: 0, reason: 'JSON fields differed' };
    } catch (_) { return { score: 0, reason: 'invalid JSON' }; }
  }
  die(`unsupported test type: ${test.type}`);
}
function invoke(model, test, timeoutMs) {
  return new Promise(resolve => {
    if (!model.command || !Array.isArray(model.args || [])) return resolve({ error: 'model requires command and args array' });
    const child = spawn(model.command, model.args || [], { shell: false, env: { ...process.env, ...(model.env || {}) } });
    let stdout = '', stderr = '', done = false;
    const finish = result => { if (!done) { done = true; clearTimeout(timer); try { child.kill('SIGKILL'); } catch (_) {} resolve(result); } };
    const timer = setTimeout(() => finish({ error: `timeout after ${timeoutMs}ms` }), timeoutMs);
    child.stdout.on('data', d => { stdout += d; if (stdout.length > 200000) finish({ error: 'stdout limit exceeded' }); });
    child.stderr.on('data', d => { stderr += d; });
    child.on('error', e => finish({ error: e.message }));
    child.on('close', code => finish(code === 0
      ? { answer: stdout, stderr: stderr.slice(-2000), exitCode: code }
      : { error: `adapter exited with code ${code}`, stderr: stderr.slice(-2000), exitCode: code }));
    child.stdin.end(JSON.stringify({ evaluation_id: test.id, category: test.category, prompt: test.prompt }));
  });
}
async function main() {
  const cli = argsOf(process.argv), models = readJson(cli.models), suite = readJson(cli.suite);
  if (!Array.isArray(models) || !models.length) die('models must be a non-empty array');
  if (!suite.tests || !Array.isArray(suite.tests) || !suite.tests.length) die('suite.tests must be a non-empty array');
  const cfg = { timeout_ms: 15000, pass_threshold: 0.8, hard_fail_categories: [], category_thresholds: {}, repeats: 1, ...suite };
  const tests = shuffle(cfg.tests, cli.seed); const report = { schema: 'brine.preflight.v1', generated_at: new Date().toISOString(), suite: suite.name || 'unnamed', seed: cli.seed, models: [] };
  for (const model of models) {
    const cases = [], repeats = Math.max(1, Number(cfg.repeats));
    for (const test of tests) for (let repeat = 0; repeat < repeats; repeat++) {
      const raw = await invoke(model, test, cfg.timeout_ms);
      const verdict = raw.error ? { score: 0, reason: raw.error } : scoreCase(test, raw.answer);
      cases.push({ id: test.id, category: test.category, repeat, score: verdict.score, reason: verdict.reason, answer_sha256: raw.answer ? hash(raw.answer) : null, ...(cli.includeOutputs ? { output: raw.answer || '', stderr: raw.stderr || '' } : {}) });
    }
    const byCategory = {};
    for (const c of cases) (byCategory[c.category] ||= []).push(c.score);
    const categoryScores = Object.fromEntries(Object.entries(byCategory).map(([k, v]) => [k, v.reduce((a, b) => a + b, 0) / v.length]));
    const overall = cases.reduce((a, c) => a + c.score, 0) / cases.length;
    const hardFail = cfg.hard_fail_categories.some(c => (categoryScores[c] ?? 0) < (cfg.category_thresholds[c] ?? 1));
    const admitted = !hardFail && overall >= cfg.pass_threshold && Object.entries(cfg.category_thresholds).every(([c, t]) => (categoryScores[c] ?? 0) >= t);
    report.models.push({ id: model.id || model.name, admitted, overall_score: overall, category_scores: categoryScores, cases });
    console.log(`${model.id || model.name}: ${admitted ? 'ADMIT' : 'REJECT'} ${(overall * 100).toFixed(1)}%`);
  }
  fs.mkdirSync(path.dirname(path.resolve(cli.output)), { recursive: true }); fs.writeFileSync(cli.output, JSON.stringify(report, null, 2) + '\n');
  console.log(`Report: ${cli.output}`);
}
main().catch(e => die(e.stack || e.message));
