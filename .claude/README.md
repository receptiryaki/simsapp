# `.claude/` — knowledge base for Sims

This is the project's source of truth for *how the system is built and why*.
Any future Claude session **must read these three files before doing anything**:

1. [`README.md`](./README.md) (this file) — the index.
2. [`project.md`](./project.md) — what we're building, scope, non-goals, phases.
3. [`workflow.md`](./workflow.md) — phase gates, "ask before proceeding" rules,
   commit style. This is the rule you most easily skip and most regret skipping.

After that, read what the task needs. The map:

| If you're working on… | Read |
|---|---|
| Layer split, bounded contexts, design decisions | [`architecture.md`](./architecture.md) |
| Naming, style, error handling, logging, testing | [`conventions.md`](./conventions.md) |
| Listing / booting / shutting down simulators | [`knowledge/coresimulator-api.md`](./knowledge/coresimulator-api.md) |
| Framebuffer streaming, IOSurface, frame callbacks | [`knowledge/simulatorkit-framebuffer.md`](./knowledge/simulatorkit-framebuffer.md) |
| Mouse/keyboard input injection | [`knowledge/indigo-hid.md`](./knowledge/indigo-hid.md) — **the single most important knowledge file in this repo** |
| `dlopen`/symbol loading, Xcode discovery | [`knowledge/private-frameworks.md`](./knowledge/private-frameworks.md) |
| NSWindow tabs, multi-window UI | [`knowledge/appkit-tabs.md`](./knowledge/appkit-tabs.md) |
| Why old tools (`idb`, `AXe`) stopped working | [`knowledge/ios26-changes.md`](./knowledge/ios26-changes.md) |

## Ground rules for editing `.claude/`

- **This folder is the source of truth.** If reality contradicts a knowledge
  note (a selector turns out to have a different signature, an offset is
  wrong, a framework path changed), **fix the note in the same commit that
  fixes the code**. Stale notes lie to the next session and waste a day.
- Every knowledge file holds concrete artefacts: symbols, selectors, byte
  offsets, file paths, minimal code recipes. **Not prose summaries.** If a
  function has nine arguments, all nine are named with their types.
- `knowledge/` is for facts about external systems (CoreSimulator,
  SimulatorKit, AppKit). The four top-level docs (`project.md`,
  `architecture.md`, `conventions.md`, `workflow.md`) are about *our* code.
- New external knowledge → new file under `knowledge/`. The README index
  is the contract; keep it short and accurate.

## Provenance

The knowledge under `knowledge/` was verified against the Xcode 26
SimulatorKit / CoreSimulator framework layout on Apple Silicon
macOS 26+. Selectors, signatures, and byte offsets were confirmed by
disassembling the framework binaries directly; anything that's still
guesswork is called out inline.
