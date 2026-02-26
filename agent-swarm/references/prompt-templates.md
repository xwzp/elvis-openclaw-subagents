# Prompt Templates

Reusable prompt templates for common task types. Copy, customize, and pass to `spawn-agent.sh --prompt` or `--prompt-file`.

## 1. Backend Feature

Best for: New API endpoints, services, database changes. Agent: Codex.

```
## Task
Implement [feature name]: [one-line description].

## Context
- This is for [customer/use case]
- Related existing code: [module/service name]
- Database: [relevant tables/schemas]

## Files to Focus On
- src/api/[route file]
- src/services/[service file]
- src/db/[migration or schema file]
- tests/[relevant test files]

## Requirements
1. [Specific requirement with acceptance criteria]
2. [Another requirement]
3. Add proper error handling for [edge cases]
4. Follow existing patterns in [reference file]

## Database Changes
- [Migration needed? Schema changes?]
- [Seed data needed?]

## Testing
- [ ] Unit tests for the service layer
- [ ] Integration tests for the API endpoint
- [ ] Test error cases: [list specific error scenarios]

## When Done
1. Commit all changes with descriptive message
2. Push to branch
3. Run: gh pr create --fill
```

## 2. Bug Fix

Best for: Fixing reported issues with known reproduction steps. Agent: Codex.

```
## Task
Fix: [bug description from issue/report].

## Bug Details
- Reported by: [source]
- Reproduction: [steps to reproduce]
- Expected: [expected behavior]
- Actual: [actual behavior]
- Error: [error message or stack trace if available]

## Root Cause (if known)
[Your analysis of what's likely wrong]

## Files to Investigate
- src/[suspected file 1]
- src/[suspected file 2]
- [Error log location if relevant]

## Fix Requirements
1. Fix the root cause, not just the symptom
2. Add regression test that would have caught this
3. Do not change unrelated code

## Testing
- [ ] Regression test covering the exact bug scenario
- [ ] Verify existing tests still pass
- [ ] Test edge cases: [related scenarios]

## When Done
1. Commit with message: "fix: [description]"
2. Push to branch
3. Run: gh pr create --fill
```

## 3. Frontend Feature

Best for: UI components, pages, user interactions. Agent: Claude Code (faster, better at frontend).

```
## Task
Build [UI component/page]: [one-line description].

## Design Reference
- [Link to design/mockup if available]
- [Description of visual requirements]

## Context
- This lives in [section of the app]
- Related components: [existing similar components]
- State management: [how data flows]

## Files to Focus On
- src/components/[component files]
- src/pages/[page files]
- src/styles/[style files]
- src/hooks/[relevant hooks]

## Requirements
1. [Visual requirement]
2. [Interaction requirement]
3. [Responsive behavior]
4. [Accessibility: keyboard nav, ARIA, screen reader]
5. Match existing design patterns in [reference component]

## State & Data
- Data source: [API endpoint or store]
- Loading states: [skeleton, spinner, etc.]
- Error states: [what to show on failure]
- Empty states: [what to show when no data]

## Testing
- [ ] Component renders correctly
- [ ] User interactions work as expected
- [ ] Responsive at mobile/tablet/desktop breakpoints
- [ ] Screenshot of the finished UI in PR description

## When Done
1. Commit all changes
2. Push to branch
3. Take screenshot and include in PR description
4. Run: gh pr create --fill
```

## 4. Refactoring

Best for: Code structure improvements without behavior changes. Agent: Codex.

```
## Task
Refactor [module/area]: [goal of refactoring].

## Motivation
- [Why this refactoring is needed]
- [What problem it solves]

## Current State
- [Description of current code structure]
- [Pain points]

## Target State
- [Description of desired code structure]
- [Patterns to follow]

## Files to Modify
- src/[file 1] — [what to change]
- src/[file 2] — [what to change]
- tests/[test files to update]

## Constraints
1. Zero behavior changes — all existing tests must pass unchanged
2. Follow the pattern established in [reference file]
3. Do not rename public API surfaces unless listed
4. [Specific constraint]

## Testing
- [ ] All existing tests pass without modification
- [ ] No new test failures introduced
- [ ] If splitting files, verify imports are updated everywhere

## When Done
1. Commit with message: "refactor: [description]"
2. Push to branch
3. Run: gh pr create --fill
```

## 5. Documentation

Best for: Updating docs, adding inline docs, writing guides. Agent: Claude Code (strong writing ability).

```
## Task
Document [area]: [what needs documentation].

## Scope
- [What to document]
- [Target audience: developers, users, ops]

## Files to Create/Update
- docs/[file 1]
- README.md sections: [which sections]
- src/[inline doc locations]

## Content Requirements
1. [Section 1]: [what to cover]
2. [Section 2]: [what to cover]
3. Include code examples for [what]
4. Keep tone [technical/conversational/formal]

## References
- Existing docs: [location]
- Source code: [relevant files to read for accuracy]

## When Done
1. Commit with message: "docs: [description]"
2. Push to branch
3. Run: gh pr create --fill
```

## Tips for Effective Prompts

1. **Be specific** -- "Add a REST endpoint for template CRUD" > "Add template support"
2. **Include file paths** -- Agents lose time exploring; give them the map
3. **Provide schemas** -- Paste relevant type definitions, DB schemas, API contracts
4. **Define done** -- What tests must pass? What does the output look like?
5. **Reference existing patterns** -- "Follow the pattern in src/api/users.ts"
6. **One PR per task** -- Keep tasks atomic. Easier to review, easier to revert
7. **Include business context** -- Why matters as much as what
