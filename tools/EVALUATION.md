# BRINE model preflight evaluation

`evaluate-models.js` is a provider-neutral admission gate. It evaluates each
candidate **without accepting or loading the production prompt**. Only models
marked `admitted: true` in the report should receive that prompt in a separate
orchestrator.

## Adapter contract

Each model is an executable command. The harness sends one JSON object on
stdin for every test:

```json
{"evaluation_id":"reasoning-001","category":"reasoning","prompt":"..."}
```

The adapter must write the candidate's answer to stdout and exit. Keep model
credentials and the real application prompt out of the suite and report.
`stderr` is captured only as a short diagnostic. A missing command, nonzero
exit, timeout, or malformed answer fails closed.

A minimal adapter can read stdin, call an API, and print only the answer. The
example model and suite are templates, not a claim that they are sufficient for
any safety-critical deployment.

## Run

```sh
node tools/evaluate-models.js \
  --models tools/models.example.json \
  --suite tools/evaluation-suite.example.json \
  --output evaluation-report.json
```

Use `--include-outputs` only in a protected local debugging report. By default
outputs are represented by short SHA-256 hashes to reduce accidental leakage.
The evaluator randomizes test order using a recorded seed; change `--seed` for
a second run. `repeats` can expose flaky candidates.

## Designing a real gate

There is no perfect filter. A benchmark can be memorized, gamed, biased toward
a language or task, or fail to predict behavior in the production context.
Treat this as a release gate, not a proof of safety:

- Keep a private, held-out, rotating set of domain tests; do not expose the
  production task or its hidden answers to candidates.
- Add deterministic tests wherever possible: exact answers, JSON schemas,
  executable code tests, citation/grounding checks, refusal checks, and tool
  permission checks. Use an LLM judge only for subjective residue, with a
  calibrated human-reviewed sample.
- Require hard zero-tolerance categories for the harms that are unacceptable
  in this application. Score categories separately; never let strong trivia
  scores compensate for a safety failure.
- Test paraphrases, multilingual/local user variants, adversarial prompt
  injection, sensitive-data requests, uncertainty, latency, and repeated runs.
- Log suite version, seed, model version, adapter version, raw scores, and
  failures. Re-run after model or prompt changes and monitor drift after
  admission.
- Use human/domain-expert review for high-impact decisions and for calibrating
  automated judges. A rejected model may be retrained or re-tested, but should
  not receive the protected production prompt until it passes again.

This design follows the broad principles of Stanford HELM's multi-metric,
scenario-based evaluation and NIST's pre-deployment TEVV/red-team guidance;
OWASP's current LLM risk list is a useful source for expanding security cases.
Useful references:

- [Stanford HELM](https://crfm.stanford.edu/2022/11/17/helm.html)
- [HELM Lite](https://crfm.stanford.edu/2023/12/19/helm-lite.html)
- [NIST AI 600-1 GenAI Profile](https://airc.nist.gov/docs/NIST.AI.600-1.GenAI-Profile.ipd.pdf)
- [OWASP Top 10 for LLM and GenAI](https://genai.owasp.org/initiatives/top-10-for-llm-and-genai/)
