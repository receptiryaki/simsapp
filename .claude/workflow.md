# Workflow

How phases proceed, when to stop and ask, and how commits are framed.

## Phase gates (the rule that matters most)

The project ships in five numbered phases, defined in
[`project.md`](./project.md). The non-negotiable rule:

> **Do not start a phase before the user has signed off on the
> previous one.**

### Before starting a phase

1. **Write a short plan in chat** (a few bullet points): what files
   you'll create or change, what the acceptance check will look like,
   what's intentionally deferred.
2. **Wait for the user's OK.** A previous "go" doesn't carry over.
3. Only then start coding.

This applies even when the next phase feels obvious from the spec.
The cost of asking is small; the cost of building the wrong shape and
having to undo it is large.

### During a phase

- Stay inside the phase's scope. If a tempting cross-cutting cleanup
  presents itself, write it down as a follow-up; don't roll it in.
- Phase commits are conventional-commit-style (see
  [`conventions.md`](./conventions.md)). Multiple commits per phase
  are fine; everything in the phase ships before moving on.

### After a phase

1. **Produce a short "what changed" summary** (a few bullets at most).
2. **Hand the user an acceptance checklist** — a numbered list of
   things to run / look at / click to verify the phase is done.
3. **Wait for the user's OK** before moving on.

## "Ask before proceeding" rules

These are situations where the spec is intentionally ambiguous or the
right call genuinely depends on user preference. Stop and ask the user:

| Situation | Ask |
|---|---|
| The user could mean two different APIs / two different shapes | "Did you mean A or B? Here's the tradeoff." |
| You're about to touch something destructive or system-wide (`xcode-select`, simulator deletion, anything `sudo`) | "About to do X — confirm?" |
| A phase's acceptance criterion is interpretable two ways | Ask before declaring the phase done. |
| The user said "do it" but two interpretations exist | Pick one, but say which one and why, and offer to switch. |

Don't ask for permission for things the spec already specifies. Don't
ask routine clarifying questions when you can grep the answer out of
this `.claude/` folder.

## Commit style

```
feat(boot): list available simulators in the main window

Adds CoreSimulators wrapping SimServiceContext + SimDeviceSet via
NSClassFromString. The main NSTableView shows name / runtime /
UDID / state, refreshed on a 1s timer.
```

- Conventional commit type (`feat`, `fix`, `refactor`, `docs`,
  `test`, `chore`). Scope optional but useful: `feat(hid):`,
  `fix(fb):`, `refactor(arch):`.
- Subject line ≤ 72 chars, imperative mood ("add", "fix", "rewrite").
- Body explains *why*, not *what*. The diff says what.
- **No `Co-Authored-By` lines.** Per the user's
  `~/.claude/CLAUDE.md`.
- **Never commit without explicit confirmation.** Including small
  follow-up edits. A previous commit instruction is not standing
  approval for the next commit.

## When `.claude/` itself is wrong

If you discover the knowledge base is incorrect — a selector
signature is off, an offset is wrong, a path doesn't exist — fix the
note in the same commit as the code that disagrees with it. Stale
notes lie to the next session. Acceptable commit shape:

```
fix(hid): touchTarget byte offset is 0x6c (not 0x68)

The previous offset misrouted touches when the trackpad wrapper
returned a 384-byte (not 256-byte) message. Updated the recipe and
.claude/knowledge/indigo-hid.md in lockstep.
```

## Scratch work

If you need to prototype something or write code that isn't part of
the project, put it under `/tmp/` (the filesystem is fine) — **not**
inside this repo. The repo holds only Sims sources and `.claude/`.

## When all five phases are done

Phase 5's "acceptance" is the user saying "ship it". At that point,
write a `CHANGELOG.md` entry (don't have one yet — that's part of
Phase 5 polish), and the project is v1. We don't auto-cut a GitHub
release; that's a user-initiated step.
