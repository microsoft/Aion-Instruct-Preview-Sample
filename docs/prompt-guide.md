# Improving Prompts for Aion

This guide describes a repeatable, evidence-driven way to improve prompts for Aion. Most of it applies to any small language model (SLM).

> Treat prompt improvement as an optimization problem with a clear contract, representative scenarios, measurable outcomes, and controlled experiments.

Do not optimize a prompt by reading a few outputs and making changes that merely feel better. Define success first, keep a held-out set, inspect failures, and change one meaningful part of the system at a time.

The examples use a hypothetical **settings assistant** that turns a user’s request into an action and a list of settings, for example `DISABLE|["Notifications", "Sounds"]`. Substitute your own task.

## Contents

- [Aion preview API scope](#aion-preview-api-scope)
- [Quick-start checklist](#quick-start-checklist)
- [1. Define the task contract](#1-define-the-task-contract)
- [2. Build a representative scenario set](#2-build-a-representative-scenario-set)
- [3. Establish a reproducible baseline](#3-establish-a-reproducible-baseline)
- [4. Know how small models fail](#4-know-how-small-models-fail)
- [5. Write the first prompt around the contract](#5-write-the-first-prompt-around-the-contract)
- [6. Separate instructions from data](#6-separate-instructions-from-data)
- [7. Constrain outputs when the answer space is known](#7-constrain-outputs-when-the-answer-space-is-known)
- [8. Decompose tasks when one prompt mixes different decisions](#8-decompose-tasks-when-one-prompt-mixes-different-decisions)
- [9. Run controlled prompt experiments](#9-run-controlled-prompt-experiments)
- [10. Use agents to improve prompts](#10-use-agents-to-improve-prompts)
- [11. Advanced optimization with GEPA](#11-advanced-optimization-with-gepa)
- [Before deployment](#before-deployment)

## Aion preview API scope

The current Aion preview API exposes:

- an optional system prompt through `CreateContext(systemPrompt)`;
- `Temperature`, `TopP`, and `TopK` through `LanguageModelOptions`;
- `ContentFilterOptions`;
- streamed progress updates and a final response status.

It does **not** currently expose a maximum generated-token setting, tokenizer-token counts,
custom chat-template selection, JSON-schema/regex constrained decoding, or candidate scoring.
Those techniques remain useful general guidance, but require application-side orchestration,
post-validation, or a future API. Treat progress callback counts as updates, not token counts.

## Quick-start checklist

1.  Write a machine-checkable task contract and a scorer for it.
2.  Collect tagged scenarios and split them into development and held-out sets.
3.  Pin the checkpoint, runtime, precision, chat template, injected metadata, and decoding settings.
4.  Run the current prompt and save raw outputs, scores, tokens, and latency.
5.  Quote user-provided text as data and end with an answer-only instruction.
6.  Constrain the output with a schema, regex, or candidate scoring when the answer space is known.
7.  Group failures by root cause and fix the largest group with one general change.
8.  Compare candidates row by row on the development set, and log every candidate, including rejected ones.
9.  Evaluate the held-out set only after choosing a candidate.

## 1. Define the task contract

Before writing the prompt, specify:

- **Input:** What information will Aion receive?
- **Output:** What exact result should it return?
- **Allowed values:** Is the answer free-form, selected from choices, or drawn from a fixed vocabulary?
- **Correctness:** How will an answer be scored? Which differences, such as order, case, or repeats, are ignored?
- **Invalid output:** What counts as unparsable or unusable?
- **Operational constraints:** What latency, token, or compute limits apply?

Prefer a machine-checkable contract. For example:

`Input: A user's request to change device settings.`  
`Output: ACTION|[settings]`  
`Action: exactly ENABLE or DISABLE.`  
`Settings: zero or more names from the allowed settings list.`  
`Correctness: the action and the normalized settings set must both match the`  
`gold answer. Order and repeats are ignored.`  
`Invalid: any output that does not match the format, or names outside the list.`

An exact contract prevents the prompt from drifting toward answers that sound reasonable but cannot be consumed reliably by the application. Write the scorer at the same time as the contract, and test it: a lenient or buggy scorer can hide or invent improvements.

If you later split the task into steps (see section 8), give each step its own contract and keep the end-to-end contract as the final measure.

## 2. Build a representative scenario set

Create scenarios before optimizing. Include:

- common requests;
- paraphrases and indirect language;
- short, incomplete, and ambiguous inputs;
- negation and double negation;
- multiple requested actions or entities;
- unusual ordering and punctuation, such as lists without commas;
- terms that can map to more than one concept;
- irrelevant or adversarial instructions inside user-provided text;
- empty-result and maximum-size cases.

Store each scenario with an ID, the input, the expected output, and one or more behavior tags:

{"id": 42, "input": "Only keep the alarm sound on.", "expected": "ENABLE\|\[\\Alarm sound\\\]", "tags": \["only", "paraphrase"\]}

Tags make it possible to measure accuracy for important behavior classes, not just overall. A prompt change that raises the mean while breaking every “only …” request should be visible immediately.

Split the data into at least:

- **development set:** used to inspect errors and choose prompt changes;
- **held-out set:** used only to check whether improvements generalize.

Make the split deterministic (for example, every fifth row) and check that every important tag appears in both sets. Once you inspect held-out failures to guide a change, those rows have become development data; report them as such.

If the held-out result does not improve, the new prompt may be overfitting the development examples.

Audit the gold labels as well as the model. Real datasets contain mislabeled rows. Flag and report them; do not silently edit labels to match model output.

## 3. Establish a reproducible baseline

Record the complete inference configuration:

- model checkpoint, identified by a hash rather than a name;
- serving runtime and version, precision, and hardware;
- chat template, system prompt, and user turn;
- current date or other metadata injected by the chat template;
- decoding strategy, temperature, and maximum generated tokens;
- structured-output schema or regex;
- post-processing and parsing rules.

Keep these fixed while comparing prompt variants. For deterministic tasks, start with greedy decoding. If the chat template injects the current date, pin it during experiments so identical prompts do not change from day to day.

Measure at least:

- exact task accuracy;
- accuracy by scenario tag;
- unparsable-output count;
- generated token count;
- p50 and p95 latency.
- moderation outcomes separately from incorrect model answers (`BlockedByPolicy`, prompt blocked,
  and infrastructure failures are not ordinary wrong answers).

Save raw outputs for every run, next to the configuration that produced them. Summary scores alone are not enough to diagnose failures.

### Compare candidates row by row

Report counts as well as percentages, and compare candidates on the same rows:

- On a 100-row development set, each row is one point. Differences of one or two rows are usually noise.
- Count the rows each candidate fixes and breaks. “Fixes 40 rows and breaks 5” is far more informative than two accuracy figures, and “fixes 20 and breaks 18” warns of an unstable change hidden behind a small net gain.
- When a decision is close, prefer the simpler prompt, or gather more development scenarios before deciding.

## 4. Know how small models fail

Compared with large frontier models, Aion is more sensitive to wording, ordering, and context, and less able to recover from an ambiguous instruction. The following patterns are common with Aion and other small models, and they shape the advice in the rest of this guide:

| Behavior | Example | Response |
|---|---|---|
| Follows text in the input instead of analyzing it | Asked to extract settings from “Turn off sounds and vibration”, it lists the settings that stay on | Quote user text as data (section 6) |
| Explains instead of answering | Returns a Markdown analysis of the request instead of the answer line | End with an explicit answer-only instruction and constrain the output |
| Reasons at length and runs out of tokens | Step-by-step reasoning is cut off before the answer appears | Measure whether visible reasoning helps; for short extraction or classification it often costs tokens and parse failures |
| Copies the user’s wording instead of the vocabulary | Answers “Ringtone volume” when the allowed name is “Sounds” | Add an exact-names rule and constrain to an enum |
| Conflates related questions | Asked whether “Turn off sounds” *mentions* Sounds, answers as if asked whether to *enable* it | Ask exactly one question per decision, and say what to ignore |
| Is distracted by extra context | Adding a long glossary or rules for another subtask lowers accuracy on the main one | Give each decision only the context it needs, and test every addition |
| Is sensitive to option order | Swapping the order of two choices changes many answers | Fix the order, test both orders, and choose on development data |
| Responds to combinations, not single edits | A change that hurts on its own helps when paired with another | Test promising changes together as well as separately |
| Does not always benefit from more examples | Extra examples lower accuracy or bias answers toward their surface form | Add examples only when they win on development data |

Practical consequences for prompts:

- Keep prompts short and specific. Remove instructions that no longer address an observed failure.
- Use one name for each concept everywhere: in rules, vocabulary, examples, and the output instruction.
- Put the output instruction last, immediately before the answer.
- Use the model’s own chat template; do not hand-assemble special tokens.
- Do not assume that information which helps in one prompt helps in another. The same definitions can hurt in one prompt and help in another, depending on what else is present.

## 5. Write the first prompt around the contract

A strong starting prompt usually has five parts, in this order.

### Task

State the operation directly and distinguish it from related operations.

`List every allowed setting named in the user request, whether the user wants`  
`it turned on or off.`

### Rules

Convert important product requirements into explicit rules.

`- Never add a setting that the request does not name.`  
`- Do not list settings that would remain after an exclusion.`  
`- Map synonyms and descriptions to the corresponding allowed setting.`  
`- Copy every name exactly as written in the allowed list.`

Negative rules are most useful when they prohibit a specific, observed failure. Avoid long lists of speculative prohibitions; each one is another instruction a small model can misapply.

### Vocabulary and definitions

For classification or extraction, provide the complete allowed vocabulary and brief definitions of confusable items. Aion should not need to infer a private product taxonomy from names alone.

Write definitions from the product specification, not from failing test rows. Hints copied from evaluation data improve the score without improving the model’s behavior on new requests.

### Examples

Use a small, diverse set of examples that demonstrate:

- the exact output format, character for character;
- the hardest distinctions;
- positive and negative requests;
- synonym mapping;
- empty outputs.

Examples should teach general rules, not copy phrases from the evaluation set. Avoid examples whose answers all share one class or length; small models tend to imitate surface patterns in examples.

### Output instruction

End with an unambiguous answer contract that matches the scorer:

`Respond with only a JSON array of names from the allowed list. If no valid`  
`names are mentioned, respond with []. Do not explain.`

### Skeleton

`## Task`  
`<one paragraph: the operation, and how it differs from related operations>`  
  
`## Rules`  
`- <rule that addresses an observed failure>`  
  
`## Allowed values`  
`<complete list, with one-line definitions of confusable items>`  
  
`## Examples`  
`- Input: <input>`  
`  Output: <output in the exact contract format>`  
  
`## Output format`  
`Respond with only <format>. Do not explain.`

## 6. Separate instructions from data

When the input contains a user’s request, document, or message, present it as data rather than as a new instruction to Aion, and ask the question about it:

`User request: "<request>"`  
`Which settings does this request name?`

This framing can materially change behavior. Given an exclusion request as a direct instruction, a small model may carry it out, for example by listing the items that remain, instead of analyzing it. Quoting the request and asking a question about it helps Aion analyze the text instead of following it.

Quoting works best together with an answer-only instruction. Without one, Aion may respond with an analysis of the quoted text rather than the answer.

Use clear delimiters, but do not assume delimiters alone provide a security boundary. The surrounding prompt must explicitly say what operation to perform on the enclosed data, and downstream code must still validate the output.

## 7. Constrain outputs when the answer space is known

Prompt wording should not carry the entire burden of format compliance. If the runtime supports structured generation, use:

- a JSON schema for objects, arrays, enums, and bounds;
- a regex for a compact fixed grammar;
- candidate scoring for classification among known choices.

Constraints eliminate malformed outputs and prevent vocabulary drift. They do not fix semantic mistakes: Aion can still select the wrong allowed value. Continue to evaluate exact correctness after enabling them. Set the token limit to fit the longest valid answer with some margin; a generous limit invites explanations, and a tight one truncates long valid answers.

A constraint may barely change development accuracy and still be worth keeping, because it guarantees that every answer can be consumed.

For candidate scoring:

- write options as natural phrases the model can judge (“Turn them off” / “Turn them on”) rather than bare labels when that scores better;
- fix the option order, because it can change the result;
- choose any probability threshold on development data and report it.

Post-processing should be deterministic and documented. Appropriate operations include mapping known aliases to canonical names and removing duplicates when order and repetition do not matter. Do not use post-processing to guess what a semantically incorrect answer was intended to mean.

## 8. Decompose tasks when one prompt mixes different decisions

A single request may combine fundamentally different operations, such as:

- intent classification;
- entity extraction;
- policy checks;
- answer generation.

Test whether they should be separate. A classifier can select among fixed intent choices while a constrained generator extracts entities. Independent steps can run in parallel when neither output depends on the other.

Decomposition is useful when:

- one subtask has a small, fixed answer set;
- different subtasks need different context;
- the combined prompt causes one instruction to interfere with another;
- separate metrics reveal which decision failed;
- specialized decoding can make a subtask more reliable.

Do not decompose automatically. Multiple calls add operational complexity and may add latency or require extra serving capacity. Compare the decomposed system with a constrained single-pass prompt on accuracy, latency, and maintainability. Also test whether passing one step’s output to the next helps; if it does not, keep the steps independent so they can run in parallel.

## 9. Run controlled prompt experiments

Use the following loop:

1.  Run the current prompt over the development scenarios.
2.  Group failures by root cause, not just by example.
3.  Choose the largest or most important failure group.
4.  Propose one general change that addresses that group.
5.  Run the full development set again.
6.  Compare overall, per-tag, row-level, formatting, token, and latency metrics.
7.  Keep the change only if the trade-off is acceptable.
8.  Record the candidate, its scores, and the decision in the experiment log.
9.  Evaluate the held-out set once a candidate is selected.

Common root causes and first responses:

| Root cause | First response to try |
|---|---|
| Misunderstood task | Restate the task; distinguish it from the related operation |
| Data treated as instruction | Quote the input and ask a question about it |
| Malformed or explained output | Answer-only instruction, structured output, tighter token limit |
| Name outside the vocabulary | Exact-names rule, enum or regex constraint |
| Missed entity | Definitions or examples of the missed synonym or value |
| Hallucinated entity | “Only list what the input names” rule |
| Wrong intent or class | Decision cues in context, candidate scoring, option-order check |
| Ambiguous vocabulary or missing definition | One-line definitions written from the specification |
| Interference between instructions | Remove the instruction, or decompose the task |
| Conflicting examples | Remove or rewrite the example |
| Insufficient context | Add the missing context; consider a larger model if it does not fit |
| Questionable gold label | Flag and report; do not change the prompt to match it |

Change one meaningful variable at a time when possible. If prompt text, examples, decoding, and post-processing all change together, the result will not reveal which intervention helped. Because small models respond to combinations, also test the best changes together before concluding that one of them does not work.

Expect framing changes, such as quoting the input or restating the task, to matter as much as adding rules or examples, and try them early.

### Keep an experiment log

Record every candidate, including the ones you reject, with:

- the date, checkpoint, and configuration;
- what changed and why (the failure cluster it targets);
- development scores, overall and by tag;
- the decision and its reason.

A short table per round is enough. The log prevents re-testing ideas that already failed and makes the final prompt auditable.

### Avoid leaking evaluation data into the prompt

- Write rules, definitions, and examples from the task specification.
- Do not paste failing test inputs into examples.
- Drop changes that were motivated by held-out errors, unless they also win on development data alone.
- Compare development and held-out accuracy at the end. A large gap suggests overfitting.

## 10. Use agents to improve prompts

Agents can accelerate prompt development by generating scenarios, reviewing failures, proposing prompt variants, and running evaluations. The safest workflow gives each agent a narrow role and uses deterministic scoring or human review as the source of truth.

### Recommended agent roles

#### Scenario author

Creates candidate scenarios from the task contract and a coverage plan.

`Generate 20 new scenarios for the <task> task. Cover the supplied behavior`  
`tags evenly. Do not rewrite existing cases. For every case, provide the input,`  
`expected output, tags, and a short justification based only on the task`  
`contract.`

Have a person or a separate reviewer validate expected answers before adding them to the gold set.

#### Adversarial scenario agent

Looks for cases that expose fragile prompt assumptions:

- ambiguous terms;
- instruction-like text inside quoted data;
- reordered lists;
- missing punctuation;
- conflicting cues;
- boundary sizes;
- uncommon but valid paraphrases.

This agent should expand coverage, not merely make inputs longer or stranger.

#### Failure analyst

Receives the task contract, current prompt, expected outputs, and failed trajectories. It clusters failures and identifies the smallest general rule or definition that may address each cluster.

Ask it to cite scenario IDs for every conclusion. This makes suggestions auditable and discourages vague prompt advice.

#### Prompt proposer

Produces a small number of focused variants. Require a hypothesis and the scenario tags each edit is expected to affect.

`Propose at most three prompt changes. Each change must address one documented`  
`failure cluster, preserve the output contract, and avoid incorporating exact`  
`evaluation phrases. Return a diff, rationale, and predicted risks.`

Remind the proposer that the target is a small model: prefer short, specific edits over long explanatory additions.

#### Evaluation agent

Runs the fixed evaluation harness, records configuration and outputs, and creates a comparison table with row-level fixes and breaks. It must not alter gold labels or silently repair invalid outputs.

### A practical agent loop

1.  The scenario and adversarial agents propose new development cases.
2.  A human or independent reviewer approves their gold answers.
3.  The evaluation agent runs the baseline.
4.  The failure analyst clusters incorrect trajectories.
5.  The prompt proposer creates targeted variants.
6.  The evaluation agent runs every variant under identical settings.
7.  A selection step keeps variants that improve the objective without unacceptable regressions.
8.  The held-out set is evaluated only after a candidate is selected.

Keep the optimizer, evaluator, and gold-label owner logically separate. An agent that writes the prompt, changes the expected answers, and judges its own output can manufacture an apparent improvement.

## 11. Advanced optimization with GEPA

[GEPA: Reflective Prompt Evolution Can Outperform Reinforcement Learning (PDF)](https://arxiv.org/pdf/2507.19457) presents **GEPA (Genetic-Pareto)**, a prompt optimizer that uses natural-language reflection over trial-and-error trajectories. Code is available at [gepa-ai/gepa](https://github.com/gepa-ai/gepa).

At a high level, GEPA:

1.  samples trajectories from an AI system, including reasoning, tool calls, and tool outputs;
2.  reflects on those trajectories in natural language to diagnose failures;
3.  proposes and tests prompt updates;
4.  retains complementary candidates on a Pareto frontier;
5.  combines lessons from successful candidates and continues evolving them.

The paper reports that, across six tasks, GEPA outperformed GRPO by 6% on average and by up to 20%, while using up to 35 times fewer rollouts. It also reports gains of over 10% over MIPROv2. These are paper results, not guarantees for Aion; the benefit depends on the task, evaluator, trajectories, and search budget.

### Applying GEPA-style optimization to Aion

Start only after the basic evaluation harness is trustworthy.

1.  **Define the objective.** Use exact accuracy or a weighted combination of correctness, format validity, latency, and token cost.
2.  **Select development scenarios.** Include representative tags and enough failures to provide useful reflection.
3.  **Capture complete trajectories.** Store inputs, prompt versions, outputs, tool interactions, scores, and relevant runtime errors.
4.  **Reflect on evidence.** Ask the optimizer to explain failed and successful cases and derive general rules. Use a stronger model for reflection if needed, but always evaluate candidates on Aion.
5.  **Mutate prompts.** Generate targeted edits rather than unconstrained prompt rewrites.
6.  **Evaluate every candidate.** Use the same Aion checkpoint, settings, and scenario set.
7.  **Maintain a Pareto frontier.** Preserve candidates that offer different useful trade-offs, such as best accuracy, lowest latency, or strongest performance on a critical scenario class.
8.  **Recombine compatible lessons.** Test combinations; do not assume two individually useful edits remain useful together.
9.  **Stop on a fixed budget or plateau.** More search increases the risk of development-set overfitting.
10. **Validate once on held-out data.** Reject candidates whose apparent gains do not generalize.

### Safeguards for automated prompt evolution

- Never expose held-out labels to the optimizer.
- Do not let the optimizer modify the evaluator or gold data.
- Validate agent-created labels independently.
- Cap prompt length and inference cost; long evolved prompts can distract a small model and slow every request.
- Preserve required safety and product rules as immutable constraints.
- Reject changes that improve the mean while materially harming critical tags.
- Review evolved prompts for leaked examples, contradictory rules, and scenario-specific patches.
- Re-run production regression scenarios before deployment.

GEPA is most appropriate when a reliable evaluator exists, the system can record informative trajectories, and manual prompt iteration has reached a plateau. For small tasks with a handful of obvious failures, the controlled manual loop is usually easier to understand and maintain.

## Before deployment

- Re-run the chosen prompt on the untouched held-out set.
- Report correctness, invalid output, moderation-blocked, and infrastructure-failure counts
  separately.
- Verify the prompt uses only controls available in the Aion preview API.
- Exercise the production `ContentFilterOptions` and clear partial output on terminal blocks.
- Record the model/runtime versions, hardware, decoding options, prompt version, and scorer.
- Review critical behavior tags for regressions even when the aggregate score improves.
