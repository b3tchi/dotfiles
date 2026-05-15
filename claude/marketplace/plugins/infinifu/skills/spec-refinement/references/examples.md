# Spec Refinement — Worked Examples

**Load this reference when:** you want to see the review checklist applied in full to realistic tasks. Each example shows a failure mode, why the review missed it, and what a rigorous review produces instead.

## Example 1 — Skipping Edge-Case Analysis (Category 6)

### What went wrong

A developer reviewed `bd-3: Implement VIN scanner` and ran the checklist:

```
1. Granularity:      ✅ 6-8 hours
2. Implementability: ✅ Junior can implement
3. Success Criteria: ✅ Has 5 test scenarios
4. Dependencies:     ✅ Correct
5. Safety Standards: ✅ Anti-patterns present
6. Edge Cases:       [SKIPPED — "looks straightforward"]
7. Red Flags:        ✅ None found

Conclusion: "Task looks good, approve ✅"
```

The task shipped. Production issues followed:

- VIN scanner matched random 17-char strings (no checksum validation)
- Lowercase VINs weren't normalized
- Catastrophic regex backtracking on long inputs (DoS vulnerability)

### Why the review failed

Skipping Category 6 on "straightforward" tasks is the most common miss. The reviewer didn't ask: *What happens with invalid checksums? Lowercase? Long inputs?* The junior engineer had no signal to handle these, because they weren't in the task. Production incidents and emergency fixes followed.

### What a rigorous Category 6 review produces

Walk every task through the edge-case questions and write down the findings before updating:

```markdown
## Edge Case Analysis for bd-3: VIN Scanner

- Malformed input? VIN has a checksum — must validate, not just pattern-match
- Empty/nil? What if empty string is passed?
- Concurrency? Read-only scanner, no concurrency issues
- Dependency failures? No external dependencies
- Unicode/special chars? VIN is alphanumeric only — but what about lowercase?
- Large inputs? Regex `.*` patterns can cause catastrophic backtracking

Findings:
❌ VIN checksum validation not mentioned (will match random strings)
❌ Case normalization not mentioned (lowercase VINs exist)
❌ Regex backtracking risk not mentioned (DoS vulnerability)
```

Then update the task:

```bash
bd update bd-3 --design "$(cat <<'EOF'
[... original content ...]

## Key Considerations (ADDED BY SRE REVIEW)

**VIN Checksum Complexity**:
- ISO 3779 requires transliteration table (letters → numbers)
- Weighted sum algorithm with modulo 11
- Reference: https://en.wikipedia.org/wiki/Vehicle_identification_number#Check_digit
- MUST validate checksum, not just pattern — prevents false positives

**Case Normalization**:
- VINs can appear in lowercase
- MUST normalize to uppercase before validation
- Test with mixed case: "1hgbh41jxmn109186"

**Regex Backtracking Risk**:
- CRITICAL: Pattern `.*[A-HJ-NPR-Z0-9]{17}.*` has backtracking risk
- Test with pathological input: 10000 'X's followed by 16-char string
- Use possessive quantifiers or bounded repetition
- Reference: https://www.regular-expressions.info/catastrophic.html

**Edge Cases to Test**:
- Valid VIN with valid checksum (should match)
- Valid pattern but invalid checksum (should NOT match)
- Lowercase VIN (should normalize and validate)
- Ambiguous chars I/O not valid in VIN (should reject)
- Very long input (should not DoS)
EOF
)"
```

### What you gain

Junior engineer has complete requirements. False positives, data handling bugs, and the DoS vulnerability are all prevented before a line of code is written.

---

## Example 2 — Accepting Placeholder Text (Red Flag #10)

### What went wrong

`bd-5: Implement License Plate Scanner` looked complete at a glance:

```markdown
## Implementation Checklist
- [ ] Create scanner module
- [ ] [Complete implementation steps detailed above]
- [ ] Add tests

## Success Criteria
- [ ] [As specified in the implementation checklist]
- [ ] Tests pass

## Key Considerations
- [Will be added during implementation]
```

Review: *"Looks comprehensive, has implementation checklist and success criteria ✅"*

During implementation, the junior engineer had to ask:
- "What are the 'implementation steps detailed above'?"
- "What specific success criteria should I verify?"
- "What key considerations exist?"

None of those questions had answers in the task. Two days lost researching and filling in what should already have been there.

### Why the review failed

Each placeholder reads like structure but contains no content:

- `[Complete implementation steps detailed above]` — meta-reference, not actual steps
- `[As specified in the implementation checklist]` — circular reference
- `[Will be added during implementation]` — deferral, not a specification

Red Flag #10 (placeholder text = auto-reject) was the whole point of this check.

### What a rigorous Red Flag check produces

Read the task line by line and call out every placeholder:

```
Line 15: "[Complete implementation steps detailed above]"
❌ PLACEHOLDER — "detailed above" is a meta-reference, not actual content

Line 22: "[As specified in the implementation checklist]"
❌ PLACEHOLDER — Circular reference, not explicit criteria

Line 30: "[Will be added during implementation]"
❌ PLACEHOLDER — Deferral, not actual considerations

DECISION: REJECT ❌
Reason: Contains placeholder text — task not ready for implementation
```

Then update with real content:

```bash
bd update bd-5 --design "$(cat <<'EOF'
## Implementation Checklist
- [ ] Create src/scan/plugins/scanners/license_plate.rs
- [ ] Implement LicensePlateScanner struct with ScanPlugin trait
- [ ] Add regex patterns for US states:
  - CA: `[0-9][A-Z]{3}[0-9]{3}` (e.g., 1ABC123)
  - NY: `[A-Z]{3}[0-9]{4}` (e.g., ABC1234)
  - TX: `[A-Z]{3}[0-9]{4}|[0-9]{3}[A-Z]{3}` (e.g., ABC1234 or 123ABC)
  - Generic: `[A-Z0-9]{5,8}` (fallback)
- [ ] Implement has_healthcare_context() check
- [ ] Create test module with 8+ test cases
- [ ] Register in src/scan/plugins/scanners/mod.rs

## Success Criteria
- [ ] Valid CA plate "1ABC123" detected in healthcare context
- [ ] Valid NY plate "ABC1234" detected in healthcare context
- [ ] Invalid plate "123" NOT detected (too short)
- [ ] Valid plate NOT detected outside healthcare context
- [ ] 8+ unit tests pass covering all patterns and edge cases
- [ ] Clippy clean, no warnings
- [ ] cargo test passes

## Key Considerations

**False Positive Risk**:
- License plates are short and generic (5-8 chars)
- MUST require healthcare context via has_healthcare_context()
- Without context, will match random alphanumeric sequences
- Test: Random string "ABC1234" should NOT match outside healthcare context

**State Format Variations**:
- 50 US states have different formats
- Implement common formats (CA, NY, TX) + generic fallback
- Document which formats supported in module docstring
- Consider international plates in future iteration

**Performance**:
- Regex patterns are simple, no backtracking risk
- Should process <1ms per chunk

**Reference Implementation**:
- Study src/scan/plugins/scanners/vehicle_identifier.rs
- Follow same pattern: regex + context check + tests
EOF
)"
```

Then verify with `bd show bd-5` that no placeholder text remains.

---

## Example 3 — Accepting Vague Success Criteria (Category 3)

### What went wrong

`bd-7: Implement Data Encryption` had three criteria:

```markdown
## Success Criteria
- [ ] Encryption is implemented correctly
- [ ] Code is good quality
- [ ] Tests work properly
```

Review: *"Has 3 success criteria ✅ Meets minimum requirement"*

The junior engineer could not verify any of them objectively, so they guessed:
- Used ECB mode (insecure — should have been GCM)
- No key rotation (bad practice)
- Tests covered only the happy path

Code review found critical security issues. Three days wasted on a complete rewrite.

### Why the review failed

The check is *"All criteria testable/verifiable?"* not *"Are there at least 3 items?"*. None of these criteria pass:

- "Implemented correctly" — correct by what standard?
- "Good quality" — subjective
- "Work properly" — what is proper?

Counting criteria without examining them is cargo-cult review.

### What a rigorous Category 3 review produces

Call each criterion out and replace with something verifiable:

```markdown
## Success Criteria Analysis for bd-7

- "Encryption is implemented correctly"
  ❌ NOT TESTABLE — "correctly" is subjective, no standard specified
- "Code is good quality"
  ❌ NOT TESTABLE — "good quality" is opinion
- "Tests work properly"
  ❌ NOT TESTABLE — "properly" is vague

Minimum: 3+ specific, measurable, testable criteria
Current: 0 testable criteria
DECISION: REJECT ❌
```

Then rewrite with verifiable criteria:

```bash
bd update bd-7 --design "$(cat <<'EOF'
[... original content ...]

## Success Criteria

**Encryption Implementation**:
- [ ] Uses AES-256-GCM mode (verified in code review)
- [ ] Key derivation via PBKDF2 with 100,000 iterations (NIST recommendation)
- [ ] Unique IV generated per encryption (crypto_random)
- [ ] Authentication tag verified on decryption

**Code Quality** (automated checks):
- [ ] Clippy clean with no warnings: `cargo clippy -- -D warnings`
- [ ] Rustfmt compliant: `cargo fmt --check`
- [ ] No unwrap/expect in production: `rg "\.unwrap\(\)|\.expect\(" src/` returns 0
- [ ] No TODOs without issue numbers: `rg "TODO" src/` returns 0

**Test Coverage**:
- [ ] 12+ unit tests pass covering:
  - test_encrypt_decrypt_roundtrip (happy path)
  - test_wrong_key_fails_auth (security)
  - test_modified_ciphertext_fails_auth (security)
  - test_empty_plaintext (edge case)
  - test_large_plaintext_10mb (performance)
  - test_unicode_plaintext (data handling)
  - test_concurrent_encryption (thread safety)
  - test_iv_uniqueness (security)
  - [4 more specific scenarios]
- [ ] All tests pass: `cargo test encryption`
- [ ] Test coverage >90%: `cargo tarpaulin --packages encryption`

**Documentation**:
- [ ] Module docstring explains encryption scheme (AES-256-GCM)
- [ ] Function docstrings include examples
- [ ] Security considerations documented (key management, IV handling)

**Security Review**:
- [ ] No hardcoded keys or IVs (verified via grep)
- [ ] Key zeroized after use (verified in code)
- [ ] Constant-time comparison for auth tag (timing attack prevention)
EOF
)"
```

### What you gain

Every criterion is verifiable with a command, a code review check, or a specific test case. Junior engineer has no room to guess; reviewers have no room to wave it through.
