#!/usr/bin/env node
/**
 * evaluate.js — shared, provider-neutral evaluation engine for the BRINE
 * model-preflight gate. This is the single source of truth for test scoring,
 * adapter invocation, and report aggregation, shared by:
 *
 *   - tools/evaluate-models.js  (the batch CLI gate)
 *   - tools/workbench.js        (the interactive evaluation workbench)
 *
 * Philosophy (see tools/EVALUATION.md):
 *   - Fail-closed: a missing command, nonzero exit, timeout, malformed answer,
 *     or forbidden-pattern hit scores 0 and can only lower the model's result.
 *   - The production prompt is never accepted here; only the test prompt is
 *     sent to the candidate.
 *
 * Support is intentionally modest: exact / includes / regex / json /
 * json_schema / code. Category thresholds and hard-fail categories are applied
 * separately so a strong trivia score never masks a safety failure.
 */
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const { spawn } = require('child_process');

function die(message) { console.error(`evaluate: ${message}`); process.exit(2); }
function hash(s) { return crypto.createHash('sha256').update(s).digest('hex').slice(0, 16); }
function normalize(v) { return String(v || '').trim().toLowerCase().replace(/\s+/g, ' '); }

/** Deterministic Fisher–Yates-ish shuffle driven by a numeric LCG seed. */
function shuffle(items, seed) {
  const a = items.slice(); let x = (seed >>> 0) || 1;
  for (let i = a.length - 1; i > 0; i--) {
    x = (1664525 * x + 1013904223) >>> 0;
    const j = x % (i + 1);
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a;
}

/** Strip a surrounding ```lang ... ``` fence if present, leaving bare code. */
function stripCodeFences(answer) {
  const text = String(answer || '');
  const m = text.match(/```[^\n]*\n([\s\S]*?)```/);
  return m ? m[1].trim() : text.trim();
}

/** Run the candidate's emitted program and return its stdout. */
function runCode(answer, lang, timeoutMs) {
  const code = stripCodeFences(answer);
  if (!code) return { error: 'empty code' };
  const ext = lang === 'python3' || lang === 'python' ? '.py' : '.js';
  const cmd = lang === 'python3' || lang === 'python' ? 'python3' : 'node';
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'brine-code-'));
  const file = path.join(dir, 'main' + ext);
  try { fs.writeFileSync(file, code, 'utf8'); } catch (e) { return { error: e.message }; }
  return new Promise(resolve => {
    let stdout = '', stderr = '', done = false;
    const child = spawn(cmd, [file], { shell: false, env: process.env });
    const finish = result => {
      if (done) return; done = true;
      clearTimeout(timer);
      try { child.kill('SIGKILL'); } catch (_) {}
      try { fs.rmSync(dir, { recursive: true, force: true }); } catch (_) {}
      resolve(result);
    };
    const timer = setTimeout(() => finish({ error: `code runner timed out after ${timeoutMs}ms` }), timeoutMs);
    child.stdout.on('data', d => { stdout += d; if (stdout.length > 200000) finish({ error: 'code stdout limit exceeded' }); });
    child.stderr.on('data', d => { stderr += d; });
    child.on('error', e => finish({ error: e.message }));
    child.on('close', code_ => finish(code_ === 0
      ? { code, stdout, stderr: stderr.slice(-2000), exitCode: code_ }
      : { error: `code exited with code ${code_}`, stderr: stderr.slice(-2000), exitCode: code_ }));
    child.stdin.end();
  });
}

function matchesType(value, t) {
  switch (t) {
    case 'object': return value !== null && typeof value === 'object' && !Array.isArray(value);
    case 'array': return Array.isArray(value);
    case 'string': return typeof value === 'string';
    case 'number': return typeof value === 'number' && !Number.isNaN(value);
    case 'integer': return Number.isInteger(value);
    case 'boolean': return typeof value === 'boolean';
    case 'null': return value === null;
    default: return true;
  }
}

function validateSchema(value, schema) {
  if (!schema || typeof schema !== 'object') return false;
  if (schema.type && !matchesType(value, schema.type)) return false;
  if (Array.isArray(schema.required)) {
    if (value === null || typeof value !== 'object' || Array.isArray(value)) return false;
    for (const k of schema.required) if (!(k in value)) return false;
  }
  if (Array.isArray(schema.enum) && !schema.enum.some(e => JSON.stringify(e) === JSON.stringify(value))) return false;
  if (schema.properties && value && typeof value === 'object' && !Array.isArray(value)) {
    for (const [k, sub] of Object.entries(schema.properties)) {
      if (k in value && !validateSchema(value[k], sub)) return false;
    }
  }
  return true;
}

/**
 * Score one answer against one test. Returns { score: 0|1, reason }.
 * `must_not_match` and `must_include` are genre-agnostic gates applied first so
 * any test type can express a refusal / required-evidence check.
 */
function scoreCase(test, answer, timeoutMs) {
  const text = String(answer || '');
  if (test.must_not_match && test.must_not_match.some(p => new RegExp(p, 'is').test(text))) return { score: 0, reason: 'forbidden pattern matched' };
  if (test.must_include && !test.must_include.every(s => text.toLowerCase().includes(String(s).toLowerCase()))) return { score: 0, reason: 'required evidence missing' };

  const type = test.type || 'includes';
  if (type === 'exact') return normalize(text) === normalize(test.expected) ? { score: 1, reason: 'exact match' } : { score: 0, reason: 'wrong answer' };
  if (type === 'includes') return test.expected.every(s => text.toLowerCase().includes(String(s).toLowerCase())) ? { score: 1, reason: 'all required terms present' } : { score: 0, reason: 'required term missing' };
  if (type === 'regex') return new RegExp(test.expected, 'is').test(text) ? { score: 1, reason: 'pattern matched' } : { score: 0, reason: 'pattern did not match' };
  if (type === 'json') {
    try {
      const got = JSON.parse(text); const expected = test.expected;
      const ok = Object.keys(expected).every(k => JSON.stringify(got[k]) === JSON.stringify(expected[k]));
      return ok ? { score: 1, reason: 'JSON fields matched' } : { score: 0, reason: 'JSON fields differed' };
    } catch (_) { return { score: 0, reason: 'invalid JSON' }; }
  }
  if (type === 'json_schema') {
    try {
      const got = JSON.parse(text);
      return validateSchema(got, test.expected) ? { score: 1, reason: 'JSON matched schema' } : { score: 0, reason: 'JSON did not match schema' };
    } catch (_) { return { score: 0, reason: 'invalid JSON' }; }
  }
  if (type === 'code') die('code tests are scored via scoreAny');
  die(`unsupported test type: ${type}`);
}

async function scoreCodeAsync(test, answer, timeoutMs) {
  const spec = test.expected || {};
  const lang = spec.lang || 'node';
  const res = await runCode(String(answer || ''), lang, timeoutMs);
  if (res.error) return { score: 0, reason: res.error };
  const stdout = res.stdout.trim();
  const expected = String(spec.expected).trim();
  const ok = (spec.compare || 'exact') === 'includes'
    ? stdout.toLowerCase().includes(expected.toLowerCase())
    : stdout === expected;
  return ok ? { score: 1, reason: 'code ran and matched output' } : { score: 0, reason: `code output did not match (got: ${stdout.slice(0, 80) || '(empty)'})` };
}

/** Read one JSON request on stdin, spawn the adapter, return answer/error. */
function invoke(model, test, timeoutMs) {
  return new Promise(resolve => {
    if (!model.command || !Array.isArray(model.args || [])) return resolve({ error: 'model requires command and args array' });
    const child = spawn(model.command, model.args || [], {
      shell: false,
      cwd: model.cwd || process.cwd(),
      env: { ...process.env, ...(model.env || {}) },
    });
    let stdout = '', stderr = '', done = false;
    const finish = result => {
      if (!done) { done = true; clearTimeout(timer); try { child.kill('SIGKILL'); } catch (_) {} resolve(result); }
    };
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

/**
 * Run every test for a single model with repeats and return the per-model
 * diagnostic block plus its admission verdict.
 */
async function evaluateModel(model, tests, cfg, opts) {
  const repeats = Math.max(1, Number(cfg.repeats));
  const includeOutputs = !!(opts && opts.includeOutputs);
  const cases = [];
  for (const test of tests) {
    for (let repeat = 0; repeat < repeats; repeat++) {
      const raw = await invoke(model, test, cfg.timeout_ms);
      const verdict = raw.error
        ? { score: 0, reason: raw.error }
        : await scoreAny(test, raw.answer, cfg.timeout_ms);
      cases.push({
        id: test.id, category: test.category, repeat,
        score: verdict.score, reason: verdict.reason,
        answer_sha256: raw.answer ? hash(raw.answer) : null,
        ...(includeOutputs ? { output: raw.answer || '', stderr: raw.stderr || '' } : {}),
      });
    }
  }
  const byCategory = {};
  for (const c of cases) (byCategory[c.category] ||= []).push(c.score);
  const categoryScores = Object.fromEntries(Object.entries(byCategory).map(([k, v]) => [k, v.reduce((a, b) => a + b, 0) / v.length]));
  const overall = cases.reduce((a, c) => a + c.score, 0) / cases.length;
  const hardFail = cfg.hard_fail_categories.some(c => (categoryScores[c] ?? 0) < (cfg.category_thresholds[c] ?? 1));
  const admitted = !hardFail && overall >= cfg.pass_threshold &&
    Object.entries(cfg.category_thresholds).every(([c, t]) => (categoryScores[c] ?? 0) >= t);
  return {
    id: model.id || model.name, admitted, overall_score: overall,
    category_scores: categoryScores, cases,
  };
}

/** Route to the async-capable scorer (code tests need a subprocess). */
async function scoreAny(test, answer, timeoutMs) {
  const type = test.type || 'includes';
  if (type === 'code') return scoreCodeAsync(test, answer, timeoutMs);
  return scoreCase(test, answer, timeoutMs);
}

module.exports = {
  die, hash, normalize, shuffle, stripCodeFences, matchesType, validateSchema,
  runCode, scoreCase, invoke, evaluateModel, scoreAny,
};
