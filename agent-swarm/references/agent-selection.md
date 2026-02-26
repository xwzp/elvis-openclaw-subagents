# Agent Selection Guide

Choosing the right agent for each task maximizes one-shot success rate and minimizes cost.

## Agent Comparison

| Dimension | Codex | Claude Code | Gemini |
|-----------|-------|-------------|--------|
| **Speed** | Slower (thorough) | Fast | Fast |
| **Reasoning depth** | Deep, multi-step | Good, occasionally shallow | Good for design |
| **Frontend** | Adequate | Strong | Strong (design) |
| **Backend** | Excellent | Good | Adequate |
| **Multi-file refactors** | Excellent | Good | Adequate |
| **Git operations** | Adequate | Excellent | N/A |
| **Context window** | Large | Large | Very large |
| **Cost** | ~$90/month | ~$100/month | Free tier available |
| **Sandbox** | Sandboxed by default | Needs `--dangerously-skip-permissions` | Varies |
| **False positives** | Low | Medium (overly cautious) | Low |
| **Default model** | `gpt-5.2-codex` | `claude-opus-4-6` | `gemini-2.5-pro` |

## Selection Matrix

### By Task Type

| Task Type | Recommended Agent | Confidence | Notes |
|-----------|------------------|------------|-------|
| **Backend API endpoint** | Codex | High | Deep reasoning about edge cases, auth, validation |
| **Complex bug fix** | Codex | High | Thorough root cause analysis, reads across files |
| **Multi-file refactor** | Codex | High | Maintains consistency across boundaries |
| **Database migration** | Codex | High | Careful with data integrity concerns |
| **Frontend component** | Claude Code | High | Faster iteration, good at CSS/React patterns |
| **Quick bug fix** | Claude Code | High | Speed matters for small, obvious fixes |
| **Git operations** | Claude Code | High | Native git understanding, fewer permission issues |
| **Documentation** | Claude Code | High | Strong writing ability |
| **UI design spec** | Gemini then Claude Code | Medium | Gemini generates design, Claude implements |
| **Code review** | Codex | High | Most thorough, lowest false positive rate |
| **Security audit** | Codex + Gemini | High | Both catch different classes of issues |
| **Performance optimization** | Codex | Medium | Good at identifying bottlenecks |
| **Test writing** | Claude Code | Medium | Fast and practical test generation |

### By Project Characteristics

| Scenario | Recommended Agent | Why |
|----------|------------------|-----|
| Large codebase (100k+ lines) | Codex | Better at navigating and reasoning across large codebases |
| Small/focused change | Claude Code | Faster turnaround, less overhead |
| Type-heavy codebase | Codex | Better at type inference and propagation |
| CSS-heavy work | Claude Code or Gemini | Better design sensibility |
| Time-sensitive | Claude Code | Faster execution |
| High-stakes (billing, auth) | Codex | More thorough, fewer missed edge cases |

## Agent Launch Commands

### Codex

```bash
codex --model gpt-5.2-codex \
  -c "model_reasoning_effort=high" \
  --dangerously-bypass-approvals-and-sandbox \
  "Your prompt here"
```

Effort levels:
- `high` — Thorough reasoning, best for complex tasks (default)
- `medium` — Balanced, good for moderate tasks
- `low` — Fast, for simple/obvious tasks

### Claude Code

```bash
claude --model claude-opus-4-6 \
  --dangerously-skip-permissions \
  -p "Your prompt here"
```

### Gemini (Design Phase)

Use Gemini to generate an HTML/CSS spec, then hand to Claude Code to implement:

```bash
# Step 1: Gemini generates design spec
gemini generate "Design a dashboard component with..." > design-spec.html

# Step 2: Claude Code implements from spec
bash spawn-agent.sh --agent claude --prompt "Implement this design spec: $(cat design-spec.html)"
```

## Multi-Agent Review Strategy

For code reviews, use multiple agents to catch different issue classes:

| Reviewer | Catches | False Positive Rate | Cost |
|----------|---------|-------------------|------|
| Codex | Logic errors, edge cases, race conditions | Low | Paid |
| Gemini Code Assist | Security issues, scalability, specific fixes | Low | Free |
| Claude Code | General quality, but overly cautious | Medium-High | Paid |

**Recommendation:** Use Codex + Gemini for review. Add Claude only for critical/security-sensitive PRs.

## Cost Optimization

1. **Default to Codex** for important tasks — higher success rate means fewer respawns
2. **Use Claude Code** for speed-sensitive and simple tasks — cheaper per task due to faster execution
3. **Use Gemini** for free-tier tasks — reviews, design specs, exploratory work
4. **Scope tasks small** — smaller tasks have higher one-shot success rates across all agents
5. **Log learnings** — track which agent/prompt combos work for which task types
