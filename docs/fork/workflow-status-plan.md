# Workflow status: plan

Fork-only document. Upstream does not commit plans (see `AGENTS.md`, "Plans and work artifacts"),
so this lives under `docs/fork/` on the `fork` branch and must not be included in any upstream PR.

## Goal

Let any prescriptive process tell the user where it is, visually, with drill-down. "Any" means a
Claude Code `Workflow` script, a skill or `CLAUDE.md` checklist, a Codex or OpenCode agent, a shell
script, a CI watcher, or a scheduled task. None of them should need to know about each other, and the
UI should not care which one is talking.

## What exists today

T3 already renders one producer: the Claude Code `Workflow` tool.

- `apps/server/src/orchestration-v2/Adapters/claudeWorkflowProgress.ts` parses Claude's
  `workflow_progress` stream into `OrchestrationV2SubagentWorkflow`
  (`packages/contracts/src/orchestrationV2.ts`, around line 797).
- `packages/client-runtime/src/state/subagentRuntime.ts` groups agents by phase
  (`deriveWorkflowGroups`).
- `apps/web/src/components/chat/ThreadLineageWorkflowRow.tsx` renders the collapsible
  workflow → phase → agent outline in the chat timeline, with "open subagent thread" and
  "stop workflow".
- `t3_workflow_stop` in `apps/server/src/mcp/toolkits/orchestrator/tools.ts` is the only agent-facing
  control.
- Mobile renders nothing for workflows.

Limits: the model is shaped like Claude's output (phases of agents), it is only populated by one
adapter, it lives on a subagent node so it scrolls away with the transcript, and it has no notion of a
step waiting on a human or on something external.

## Design

### 1. One generic model, many producers

A **workflow run** is a first-class orchestration entity attached to a thread (optionally to a
project when no thread owns it, e.g. a CI watcher). It is not a subagent property.

```
WorkflowRun {
  id, threadId, projectId?, name, producer: { kind, id? }, startedAt, updatedAt, completedAt?
  state: pending | running | waiting_for_human | waiting_for_external | completed | failed | cancelled
  message?: string                 // one line, the current headline
  steps: Step[]                    // declared up front; order is display order
  totals?: { tokens?, toolCalls?, durationMs? }
}
Step {
  id, title, detail?
  state: (same enum) | skipped
  dependsOn?: stepId[]             // drives the rail/DAG; absent = sequential
  message?, startedAt?, completedAt?, attempt?
  actions?: Action[]               // what the user can do right now on this step
  links?: Link[]                   // thread, subagent, file, pull-request, url
  metrics?: { tokens?, toolCalls?, durationMs? }
}
Action { id, label, kind: "resolve" | "retry" | "skip" | "cancel" | "open" , payload? }
Link   { kind: "thread" | "subagent" | "file" | "pull-request" | "url", ref }
```

Rules that keep it small:

- Steps are **declared once, updated many times.** A producer may add steps later, but the common case
  is: declare the whole plan, then patch states. That is what makes the UI prescriptive: future steps
  render immediately.
- Updates are **patches keyed by step id**, idempotent, last-write-wins by `updatedAt`. A producer that
  crashes and re-sends the same patch does no harm.
- `waiting_for_human` carries `actions`. When the user clicks one, T3 records a
  `workflow.action` event; the producer learns about it through whichever channel it listens on
  (see 3). T3 never executes the action itself.
- No free-form nesting. One level of steps plus links out to threads and subagents covers the drill-down.
  A sub-workflow is a separate run linked from a step.

### 2. Contracts and persistence

- Add `WorkflowRun`, `WorkflowStep`, `WorkflowPatch` schemas to `packages/contracts` (new file
  `workflow.ts`; `orchestrationV2.ts` is already 4k lines).
- New orchestration commands: `workflow.declare`, `workflow.patch`, `workflow.action`,
  `workflow.cancel`. Events: `workflow.declared`, `workflow.patched`, `workflow.actioned`,
  `workflow.completed`. Same event-sourced path as everything else: orchestrator decides, sink commits,
  projection updates.
- Projection: `workflowRuns` keyed by thread, with a per-environment "active runs" list for the
  cross-thread view.
- Retention: completed runs keep their final snapshot; patch history is not kept beyond the event log.

### 3. Ingestion paths (the generic part)

All paths call one service, `WorkflowService` in `apps/server`. Transports stay thin.

| Path | Who uses it | Shape |
| --- | --- | --- |
| MCP tools `t3_workflow_declare`, `t3_workflow_patch`, `t3_workflow_read` | any agent with the T3 MCP server (Claude, Codex, OpenCode, Cursor, scheduled tasks) | JSON matching the patch schema; `threadId` defaults to the caller's thread |
| HTTP `POST /api/workflow/:threadId` with a scoped token | shell scripts, CI, hooks, anything not an agent | same JSON body |
| CLI `npx t3 workflow declare|patch|action-wait` | the same, without hand-rolling curl; also usable from Claude Code hooks | wraps HTTP |
| Stdout marker `@@t3-workflow {json}` on its own line | tools that only have stdout (tests, build steps run via the agent) | provider adapters already scan stdout; one more marker |
| Claude `workflow_progress` adapter | existing `Workflow` tool | rewrite `claudeWorkflowProgress.ts` to emit a declare + patches instead of its own model |

The producer field records which one it was, so the UI can say "reported by hook" vs "reported by
Claude workflow" and offer the right stop control (only runs with a live provider task can be
"stopped"; others can only be "cancelled" in the UI, which notifies the producer).

Agents learn how to use it the same way they learn every T3 tool: tool descriptions, plus a short
section in `docs/user/outside-agents.md`. A skill or `CLAUDE.md` checklist becomes prescriptive by
starting with one `t3_workflow_declare` call.

For human actions, producers pick what fits: an agent calls `t3_workflow_read` (or `t3_workflow_wait`,
which blocks until the next action or a timeout); a script calls `npx t3 workflow action-wait`. The
Claude `Workflow` runner does not need this at all; it already has its own approval flow.

### 4. UI

Three layers, each drilling into the next. Web first; mobile gets layers 1 and 3.

1. **Status strip** in `ThreadActivityBanners.tsx` territory, above the composer, visible whenever a
   thread has an active run. Name, current step, segmented progress (one segment per step, colored by
   state), elapsed, and the single blocking message with its action buttons inline. Click opens the
   panel. No animation beyond the running segment's static accent.
2. **Workflow panel**, a new `RightPanelSurface` kind `workflow` in `apps/web/src/rightPanelStore.ts`
   rendered by `RightPanelSurfaceContent.tsx`. Vertical rail; nodes with `dependsOn` fan out side by
   side. Each node: state, title, message, metrics, action buttons. An environment-level tab lists
   active runs across threads.
3. **Step detail**, inside the panel. Full message, attempts, links (open thread, subagent, file, PR),
   metrics, retry/skip actions.

The existing `ThreadLineageWorkflowRow.tsx` stays as the transcript-level view and is re-pointed at
the generic model. The chat timeline keeps its outline; the panel is where the picture lives.

Every surface in the "Hit every surface" list in `AGENTS.md` gets a decision:

- Entry points: strip click, command palette "Open workflow", keybinding, MCP `t3_workflow_read`.
- Clients: web and desktop share the panel; mobile shows the strip and step detail as a screen.
- Providers: each adapter either maps native progress (Claude) or does nothing; the MCP and HTTP paths
  cover the rest.
- Reverse states: cancel, retry, skip, and "dismiss completed run" all exist. Declaring a run has a
  matching `workflow.cancel`.
- Connection modes: it is projection data over the existing WebSocket, so remote and relay follow.

### 5. Performance constraints

- Patches are coalesced per run on the server (last state per step) before broadcast; a chatty
  producer cannot flood the socket.
- The panel subscribes to one run, not the whole list. The strip subscribes to a derived
  `(state, currentStepId, message)` tuple.
- No per-frame animation. Progress bar segments change on state change only.

## Milestones

1. **Contracts + service + MCP** (server only). Schemas, commands, events, projection, `WorkflowService`,
   `t3_workflow_declare|patch|read`. Tests: orchestrator decides correct events, idempotent patches,
   action round-trip. Proof: a Claude thread declares a 4-step workflow over MCP and `t3_workflow_read`
   returns it.
2. **Web strip + transcript row on the new model.** Re-point `deriveWorkflowGroups` and
   `ThreadLineageWorkflowRow.tsx`; add the strip. Migrate `claudeWorkflowProgress.ts` to emit
   declare/patch so existing `Workflow` runs render through the generic path with no visible regression.
3. **Workflow panel + step detail.** New right-panel surface, rail layout, actions. Command palette and
   keybinding entries.
4. **HTTP + CLI + stdout marker.** Token scope `workflow:write`, `npx t3 workflow`, marker scanning in
   the adapter stdout path. Docs in `docs/user/outside-agents.md`.
5. **Mobile.** Strip and step detail screen in `apps/mobile`.
6. **Cross-thread view.** Environment-level active runs list in the panel.

Milestone 1 and 2 together are the minimum that proves the idea. 3 is what the user actually asked for.
4 is what makes it generic in practice. 5 and 6 can trail.

## Open questions

- Should a run be allowed to outlive its thread (CI watcher case) or should such runs always attach to
  a project? Leaning project-attached with `threadId` optional.
- Token scope for HTTP: reuse the existing guest-link scopes or add `workflow:write`? Adding is cleaner.
- Whether upstream wants this. If yes, milestones 1 to 3 are the PR, and this doc is replaced by the
  tracking issue per upstream's rules.
