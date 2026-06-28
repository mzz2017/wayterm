---
name: vvterm-commit-message
description: Use when drafting, reviewing, amending, or committing VVTerm git commit messages. Trigger for git commit, commit title, commit body, conventional commit, reword, squash, changelog-oriented history, or when deciding whether a staged diff should be split into atomic commits.
---

# VVTerm Commit Message

Use this skill to write VVTerm commits that are conventional, searchable, and useful during review. Preserve the repo's existing `fix:`/`test:`/`ci:` style, but make the subject carry enough information to understand the affected owner and the durable change.

## Workflow

1. Inspect the staged diff first:
   - `git diff --cached --stat`
   - `git diff --cached --name-only`
   - sample the important hunks when the intent is not obvious.
2. Reject mixed commits before naming them. Split when the staged diff mixes unrelated code, tests, docs, infrastructure, generated files, or another agent's work.
3. Pick a conventional type:
   - `fix`: user-visible bug fixes, lifecycle correctness, race fixes, safety fixes.
   - `test`: new or changed test coverage only.
   - `ci`: build, test runner, scripts, automation, lock handling, or verification gates.
   - `docs`: documentation and engineering guidance only.
   - `refactor`: structural cleanup without behavior change.
   - `feat`: user-facing capability.
   - `chore`: narrow maintenance that does not fit the above.
4. Add a scope only when it improves searchability: `fix(ssh): ...`, `test(remote-files): ...`, `ci(ios): ...`.
5. Write the subject, then decide whether a body is needed.

## Subject Rules

Use:

```text
type(scope): verb object outcome
```

Keep the subject concise, imperative, lowercase after the prefix unless a proper noun requires capitalization, and normally under 72 characters. Prefer subjects that name the owner and the invariant, not vague activity.

Good VVTerm subjects:

```text
fix(ssh): track shell cleanup from stream termination
fix(cloudflare): scope oauth completion callbacks by session
ci(ios): preserve fresh ownerless test locks
test(remote-files): cover transfer cancellation handoff
docs(swift): record callback lifetime ownership rule
```

Avoid:

```text
fix lifecycle issue
Improve iOS test lock diagnostics
update tests
misc cleanup
```

## Body Rules

Add a body when the subject cannot explain the review-relevant context. Keep it short and wrap paragraphs around 72 columns.

Use the body to explain:

- why the change exists,
- what invariant it protects,
- how risky lifecycle, async, FFI, or test-infra behavior is guarded,
- what validation ran, if it is helpful to future archaeology.

Do not use the body to repeat the diff mechanically.

Good body shape:

```text
fix(ssh): track shell cleanup from stream termination

Stream termination used to depend on a weak callback path, so channel cleanup
could be skipped once the owner disappeared. Route termination through the SSH
owner's cleanup registry so later teardown can wait for it.

Validated with VVTermTests/SSHClientSupportOwnerTests.
```

## Atomicity Check

Before committing, ask:

- Can this be reverted independently?
- Are tests and production changes proving the same behavior?
- Is there any unrelated user or other-agent file staged?
- Would the title still be accurate if only half the diff were reviewed?

If any answer is uncomfortable, split the commit or unstage unrelated files.

## Commit Command

Use `git commit -m` for subject-only commits. Use a temp message file or editor for bodies; avoid unreadable shell quoting for multi-paragraph messages.

After committing, verify:

```bash
git show --stat --name-status --oneline HEAD
git status --short --branch
```
