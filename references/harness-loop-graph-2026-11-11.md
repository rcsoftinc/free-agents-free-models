# The tool against an outside checklist: "Harness, Loop and Graph"

*November 2026*

## The source

"Harness, Loop and Graph: The Enhanced Edition of Agent Engineering", an
article published on X on 2026-11-05 (author handle `0xwhrrari`). It is a
synthesis, not original research: it quotes Anthropic's posts on building
effective agents, context engineering, long-running harnesses, tool design, the
multi-agent research system and the C compiler build, OpenAI's harness
engineering post, Cursor's two posts on scaling agents, and LangGraph's docs on
interrupts. Where those sources could be checked, the article quotes them
correctly. Its own contributions are the vocabulary, a failure catalog and a
checklist, and a worked example (IssueBot) that the author says ran only against
fakes.

## What it says, in the parts that touch this tool

Three layers, which it says nest: the **harness** is what the agent can see,
touch, remember and prove (tools, permissions, context, state, sensors,
traces); the **loop** is how it tries, checks, retries and stops (evidence,
feedback, retries, stop rules); the **graph** is which steps exist and who
picks the next one (nodes, typed edges, routing, joins, gates). These are the
same three `docs/dev/PARADIGMS.md` took from Priyanka Vergadia's piece, with
near-identical definitions.

Seven parts of a loop: trigger, goal, state, action policy, evidence, feedback,
stop rule. Each missing part predicts a failure; the two this tool should care
about are **no feedback** ("each retry repeats the last mistake") and **no
state** ("each iteration starts from zero").

Three honest exits: success (the evidence says done), budget (turns, tokens,
time), stall (no progress in K rounds). "The dishonest exit is the model
deciding it is done."

Four join rules for a fan-out, decided before it happens: ALL, ANY, QUORUM,
SETTLED (keep every result, let the join decide).

Harness decay: every component encodes an assumption about what the model
cannot do; re-check the assumptions when the model changes, by removing one
component at a time and measuring.

Evals: you ship the harness plus the model, so test the pair, on ~20 real cases
drawn from real usage, three runs each (single runs are noise), graded on the
end state, and rerun on every change. Ablations are harness evals.

Economics: the denominator is cost per finished task, not cost per run.

## Where the tool already stands

| Checklist line | In the tool |
|---|---|
| a verify step the actor cannot skip or edit; tests read-only for the actor | `--verify`; `readonly:` globs put back from a snapshot before any check; `protected_edit` finding |
| classify on output, never on exit code | `classify.sh`; "These CLIs exit 0 on hard failures" (CLAUDE.md) |
| policy enforced outside the model | `no_new_privs` on every worker and check, `refuse_if_worker`, workers never push |
| typed edges validated in code | `result:` JSON + `when` clauses, `malformed_result`, `plan.sh` rejects malformed graphs |
| durable state, resume, idempotent side effects | append-only journal replayed on `resume`, `orphan_abandoned`; push mode reuses the pull request it recorded |
| an explicit join | independent tasks settle; the project check runs on what landed; a failure's dependents end in a `deadlock` report, the run is not killed |
| budget exits | `MAX_ATTEMPTS` 6, `VALIDATE_ROUNDS` 3, per-attempt and per-verify timeouts, verify output cut to its tail |
| traces a human reads; secrets redacted | `fa jobs`, the journal, `fa findings` with redaction, `--post` only after asking |
| the planner's context stays clean (Cursor's finding) | coordinator/worker split; handoffs capped at `HANDOFF_MAX_CHARS` |
| untrusted input and dangerous tools apart | workers never dispatch (`FA_DEPTH`), never push, never `sudo` |

Nothing in the article says the tool is built wrong.

## What it exposed

Each item was checked in the code before it was written down; the live list is
in `docs/dev/SESSION.md`, "Next, if resuming".

1. **A retried task learns nothing from the attempt before it.** After
   `verify_failed`, `validation_failed`, `unverified` or `attempt_failed`, the
   orchestrator dispatches the task again (`TASK_RETRIES`) with the prompt
   `build_prompt` produced the first time. An isolated pool slot is reset first
   (`reset --hard`, `clean -fdx`); an in-place task keeps the earlier edits.
   The new attempt is told neither. A fix round inside one lane already gets
   the whole task plus the failing output (`fix_prompt`, run.sh); a retry
   should get the same, plus whether the directory still holds the earlier
   work. The journal already has what is needed (`cmd`, `rounds`, `tail`,
   `missing`).
2. **Lane-minutes per verified task.** On free lanes the scarce resource is
   lane time, so the number that compares models is lane-minutes per task that
   passed its checks. Every journal event has `ts`, every RUN-META has `ms`;
   `fa profile` shows ok/fail rates only and `fa analyze` computes no
   durations.
3. **The registry never forgets.** `.stats`, `.cat_stats` and `.agent_stats`
   are lifetime counters with no timestamps, a failure weighs twice a success
   in the candidate score, and a demoted model runs again only when everything
   above it fails. Free models change under the same name, so a demotion from
   months ago may describe a model that no longer exists. A half-life on the
   counters, or one exploratory attempt per demoted model every so often. A
   decay, never a reset.
4. **An eval the tool ships with.** The suite is offline by design and real
   agent behaviour is deliberately untested. The three proof builds (mdsite,
   fmtkit, coldrun) are an eval set in embryo: rerunnable as an opt-in,
   lane-spending command, three runs each, reporting pass rate and
   lane-minutes, they would give a prompt, adapter or ranking change a number.
5. **Three existing backlog items named from outside:** a fast path for small
   tasks (the article's first cost lever; SESSION item 2), a schedule that
   fails without a sound (failure 14; item 6), and environment drift in fresh
   checkouts, fixed by an `init.sh` that is part of the harness (failure 05;
   item 10).

## Declined

- **An LLM evaluator per task (the article's L2 loop).** A lane spent on an
  opinion the task's verify command does not already give. The article itself
  says never to let an LLM reviewer be the only gate, and quotes a practitioner
  who dropped adversarial review as a waste of tokens. The coordinator reviews.
- **Token accounting.** Rejected before (SESSION item 4); the article's cost
  levers are worker-model prices this tool does not pay.
- **A stall detector on fix rounds.** With three check rounds there is at most
  one round to save.
- **Dynamic, model-written workflows.** `plan.sh` → `tasks.json` → `orch.sh`
  already is a graph fixed once designed.

## Accuracy notes on the article itself

- Its opening reads one ordinary prompt ("make it really good, use lots of
  tokens and iterate till you're proud of it") as goal, budget and system -
  and "iterate till you're proud of it" is the dishonest exit it later warns
  against.
- "Harness engineering" is a term in use; "loop engineering" and "graph
  engineering" link to the author's earlier articles. The layers and the
  L0-L5 ladder are the author's constructs.
- Prices, context sizes and product names from after mid-2026 could not be
  checked here; the author says to re-check them before budgeting.
