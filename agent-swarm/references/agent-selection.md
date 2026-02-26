# Agent Selection Guide

## Role Assignment

| Role | Agent | Model | Why |
|------|-------|-------|-----|
| **All coding tasks** | Claude Code | `claude-opus-4-6` | Default for all development: backend, frontend, bugs, refactors, tests, docs |
| **Code review** | Claude Code | `claude-sonnet-4-6` | Fast, accurate, understands its own code patterns |
| **Code review** | Codex | `gpt-5.2-codex` | Most thorough reviewer, lowest false positive rate |
| **Code review (free)** | Gemini | `gemini-2.5-pro` | Security, scalability, free tier |
| **UI design specs** | Gemini then Claude Code | `gemini-2.5-pro` | Gemini designs, Claude implements |

**Simple rule: Claude writes code. Claude, Codex, and Gemini all review code.**

## Coding Agent: Claude Code

Claude Code handles all development tasks:

- Backend API endpoints, services, database changes
- Frontend components, pages, UI interactions
- Bug fixes (simple and complex)
- Multi-file refactors
- Database migrations
- Git operations
- Documentation
- Test writing
- Performance optimization

### Launch Command

```bash
claude --model claude-opus-4-6 \
  --dangerously-skip-permissions \
  -p "Your prompt here"
```

This is what `spawn-agent.sh` uses by default (no `--agent` needed).

## Review Agents

For code reviews, use Claude, Codex, and/or Gemini via `review-pr.sh`:

| Reviewer | Catches | False Positive Rate | Cost |
|----------|---------|-------------------|------|
| Claude | Logic errors, architectural issues, code style | Low | Paid |
| Codex | Logic errors, edge cases, race conditions | Low | Paid |
| Gemini | Security issues, scalability, specific fixes | Low | Free |

### Recommended Review Strategy

- **Normal PRs**: Claude + Gemini (fast + free second opinion)
- **Important PRs**: Claude + Codex + Gemini (triple coverage)
- **Security-sensitive PRs**: Claude with `--focus security` + Codex with `--focus security`
- **Quick/low-risk PRs**: Gemini only (free)

```bash
# Standard review: dispatch Claude + Gemini
bash review-pr.sh --task "$ID" --reviewer claude
bash review-pr.sh --task "$ID" --reviewer gemini

# Thorough review: all three
bash review-pr.sh --task "$ID" --reviewer claude
bash review-pr.sh --task "$ID" --reviewer codex
bash review-pr.sh --task "$ID" --reviewer gemini

# Security-focused
bash review-pr.sh --task "$ID" --reviewer claude --focus security
bash review-pr.sh --task "$ID" --reviewer codex --focus security
```

## Gemini for Design

Use Gemini to generate an HTML/CSS spec, then hand to Claude Code to implement:

```bash
# Step 1: Gemini generates design spec
gemini -m gemini-2.5-pro "Design a dashboard component with..." > design-spec.html

# Step 2: Claude Code implements from spec
bash spawn-agent.sh --repo $REPO --task "ui-dashboard" --branch "feat/dashboard" \
  --prompt "Implement this design spec: $(cat design-spec.html)"
```

## Cost Optimization

1. **Claude for all coding** -- one agent type simplifies orchestration and prompt tuning
2. **Claude for review too** -- Claude is an excellent reviewer, use Sonnet for speed/cost
3. **Codex for important reviews** -- save Codex budget for high-stakes PRs
4. **Gemini for free reviews** -- always include Gemini as a second reviewer (it's free)
5. **Scope tasks small** -- smaller tasks have higher one-shot success rates
6. **Log learnings** -- track which prompt patterns work to reduce respawns
