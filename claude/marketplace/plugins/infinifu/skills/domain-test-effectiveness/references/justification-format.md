# Line-by-Line Justification Format

**Load this reference when:** writing justifications for RED or YELLOW classifications (Phase 4b). The format is mandatory because it forces you to verify the classification is correct.

## Why the format matters

Writing the justification forces you to:

1. Actually read the test code line by line
2. Actually read the production code
3. Articulate the specific gap
4. Consider what bugs could slip through

If you cannot write this justification, you haven't done the analysis properly.

## Required structure

```markdown
### [Test Name] — RED/YELLOW ([category])

**Test code (file:lines):**
- Line X: `code` — [what this line does]
- Line Y: `code` — [what this line does]
- Line Z: `assertion` — [what this asserts]

**Production code it claims to test (file:lines):**
- [Brief description of what production code does]

**Why RED/YELLOW:**
- [Specific reason with line references]
- [What bug could slip through despite this test passing]
```

## Example — RED (tautological)

```markdown
### testAuthWorks — RED (tautological)

**Test code (auth_test.ts:45-52):**
- Line 46: `const auth = new AuthService()` — creates auth instance
- Line 47: `const result = auth.login('user', 'pass')` — calls login
- Line 48: `expect(result).not.toBeNull()` — asserts result exists

**Production code (auth.ts:78-95):**
- login() returns AuthResult object (never null by TypeScript types)

**Why RED:**
- Line 48 asserts `!= null`, but TypeScript guarantees a non-null return
- If login returned `{success: false, error: "invalid"}`, the test still passes
- Bug example: wrong password accepted → returns `{success: true}` → test still passes
```

## Example — YELLOW (weak assertion)

```markdown
### testParseJson — YELLOW (weak assertion + happy-path only)

**Test code (parser_test.ts:23-30):**
- Line 24: `const input = '{"name": "test"}'` — valid JSON input
- Line 25: `const result = parse(input)` — calls production parser
- Line 26: `expect(result).toBeDefined()` — asserts result exists
- Line 27: `expect(result.name).toBe('test')` — verifies one field

**Production code (parser.ts:12-45):**
- parse() handles JSON parsing with error handling and validation

**Why YELLOW:**
- Lines 26–27 only cover the happy path with valid input
- Missing: malformed JSON, empty string, deeply nested structure, unicode
- Bug example: `parse('')` throws an unhandled exception — not caught by this test
- Upgrade path: add edge-case inputs with specific error assertions
```

## Checkpoint

After writing the justification, re-read it and ask: could a reviewer look at this and immediately see *what* is wrong and *why it matters in production*? If not, the justification isn't specific enough — add the concrete bug example before moving on.
