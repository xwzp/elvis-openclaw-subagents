# Ralph Loop V2: Self-Improving Respawn Strategy

## Overview

The traditional "Ralph Loop" is: pull context, generate, evaluate, save learnings. The prompt stays static.

**Ralph Loop V2** improves on this: when an agent fails, the orchestrator analyzes the failure with full business context and crafts an improved prompt before respawning. Each failure makes future prompts better.

## The Loop

```
1. DETECT  — check-agents.sh identifies failure
2. ANALYZE — Orchestrator examines logs, diff, CI output
3. IMPROVE — Craft better prompt based on failure analysis
4. RESPAWN — respawn-agent.sh with new prompt
5. LEARN   — log-learning.sh records the pattern
```

## Step 1: Detect

`check-agents.sh` runs periodically and detects failures:

- **Agent died (no PR)** — tmux session gone, no PR created
- **CI failing** — PR exists but CI checks are red
- **Review feedback** — Changes requested by reviewers
- **Stale agent** — Running longer than expected (default 4h)

Each failure type has a different recovery strategy.

## Step 2: Analyze

The orchestrator (OpenClaw) has context the agent didn't:

- **Business context** — Customer requirements, meeting notes, product decisions
- **Technical context** — Architecture decisions, team conventions, past bugs
- **Agent logs** — What the agent tried and where it got stuck
- **Diff history** — What was actually changed vs what was expected

### Common Failure Patterns

| Pattern | Signal | Root Cause |
|---------|--------|------------|
| Agent died early | Short log, no commits | Missing context or wrong entry point |
| Agent died late | Long log, partial commits | Ran out of context window |
| Wrong approach | Commits exist, but wrong files changed | Prompt was ambiguous |
| CI type errors | TypeScript errors in CI | Missing type definitions in prompt |
| CI test failures | Test errors in CI | Prompt didn't specify test expectations |
| Review rejection | Changes requested | Missing requirements or conventions |

## Step 3: Improve

Based on the failure analysis, improve the prompt:

### Agent ran out of context
**Strategy:** Narrow scope. Focus on fewer files.
```
"Focus ONLY on these three files:
- src/api/templates.ts
- src/services/template-service.ts
- tests/templates.test.ts
Ignore everything else."
```

### Agent went wrong direction
**Strategy:** Be more prescriptive. State the approach explicitly.
```
"Stop. The customer wanted API-only changes, not UI changes.
Implement a REST endpoint at /api/v1/templates with CRUD operations.
Do NOT modify any frontend files."
```

### Agent needs clarification
**Strategy:** Add business context that was missing.
```
"Here's the customer's email describing what they need: [paste email]
Their company does [X], so the template needs to support [Y].
The existing config format is: [paste schema]"
```

### CI type errors
**Strategy:** Include type definitions upfront.
```
"Here are the relevant type definitions:
[paste from src/types/template.ts]

Make sure all new code is fully typed. No 'any' types."
```

### CI test failures
**Strategy:** Include test patterns and expectations.
```
"Follow the test pattern in tests/api/users.test.ts.
The test should:
1. Create a template via POST /api/v1/templates
2. Verify it returns 201 with the correct shape
3. Verify GET /api/v1/templates returns the new template
4. Test error cases: missing required fields, duplicate name"
```

### Review rejection
**Strategy:** Include the specific feedback.
```
"The code reviewer found these issues:
1. Missing input validation on the 'name' field (max 100 chars)
2. No rate limiting on the create endpoint
3. SQL injection risk in the search query

Fix all three issues. Use the validation pattern from src/api/users.ts."
```

## Step 4: Respawn

Use `respawn-agent.sh` which handles the mechanics:

```bash
bash respawn-agent.sh \
  --task "feat-custom-templates" \
  --prompt "IMPROVED PROMPT based on analysis..." \
  --reason "Agent ran out of context - narrowing scope to 3 files"
```

The script:
1. Checks retry count hasn't exceeded limit (default 3)
2. Preserves original task config (repo, branch, agent, model)
3. Kills the old tmux session
4. Logs the respawn event to learnings
5. Calls `spawn-agent.sh` with the new prompt

## Step 5: Learn

Every outcome (success or failure) gets logged:

```bash
# On success
bash log-learning.sh \
  --task "feat-custom-templates" \
  --outcome success \
  --notes "Including type defs upfront + narrowing to 3 files worked. Codex completed in one shot."

# On failure that led to respawn
bash log-learning.sh \
  --task "feat-custom-templates" \
  --outcome failure \
  --notes "Initial prompt too broad. Agent tried to change 12 files and ran out of context. Next time: scope to max 5 files for Codex."
```

### Learning Patterns to Track

- Which prompt structures work for which task types
- Which agents perform better for which contexts
- Optimal scope size (number of files) per agent
- Business context that's always needed vs. optional
- Common failure modes per project/repo

## Guardrails

- **Max retries:** 3 by default. After 3 failures, mark as abandoned and escalate to human.
- **Retry budget:** Each respawn costs compute time. If an agent keeps failing, the task may be too complex for automated handling.
- **Escalation:** When a task is abandoned, include all learning entries in the escalation so the human has full context.
- **No blind respawns:** Never respawn with the same prompt. Always improve something based on the failure analysis.

## Example: Full Loop

```
1. Spawn: feat-billing-fix with Codex
2. check-agents.sh: Agent died (no PR). Retry 0/3.
3. Read log: Agent got confused by multiple billing modules.
4. Respawn: "Focus ONLY on src/services/billing-v2.ts. The old billing module in src/services/billing.ts is deprecated."
   Reason: "Agent confused by legacy billing module"
5. check-agents.sh: PR created, CI passing, reviews approved.
6. Log: success — "Always specify which billing module (v2) in prompts to avoid confusion with deprecated module."
```

Over time, these learnings compound. The orchestrator's prompts get better, one-shot success rate goes up, and respawns become rare.
