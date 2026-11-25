# RFC 022 — Async Mutation Writes: Decouple Accept from Embed

**Status:** Proposed
**Depends on:** RFC 017 (contextual retrieval), issue #1228 / PR #1235
(`KB_RETRIEVE_REFRESH_MODE`, `BackgroundRefreshCoordinator`, `index_status`)
**Composes with:** `src/write-lock.ts`, `src/mcp-document-mutations.ts`,
`src/retrieve-refresh.ts`, `src/reindex-runner.ts`
**Tracks:** eliminating `REFRESH_LOCK_BUSY` as a user-visible failure mode
on the mutation path
**Prior art / analysis:** `README.todo.async.md` (incident postmortem,
2026-11-17)

## Problem

`add_document` and `delete_document` bundle the filesystem write **and**
`manager.updateIndex(kb)` inside a single `withWriteLock(modelDir)`
(`mcp-document-mutations.ts` ~L275–296). Accepting a write and embedding
it are one synchronous, all-or-nothing transaction — if `updateIndex`
fails after `writeFile`, `rollbackAddDocumentWrite` deletes the file and
`AddDocumentRollbackError` is thrown.

Consequence: whenever **any** writer holds the per-model lock — a
trigger-watcher `updateIndex`, a `kb reindex`, a model-switch re-embed —
mutations exhaust the ~2 s retry budget and surface
`WriteLockContentionError` (`REFRESH_LOCK_BUSY`). In production a
trigger-watcher refresh held the lock for 15+ h; every `add_document` in
that window was rejected. The working manual bypass — write the `.md`
directly, let the in-flight refresh's filesystem walk pick it up —
proved the safe path exists: **the filesystem is the source of truth and
the FAISS index is derived state.** The defect is the synchronous
contract, not the lock.

#1235 fixed the analogous read-path defect (`retrieve_knowledge` joining
the lock under `sync` mode). The mutation path was explicitly out of
scope and remains the last user-visible surface of lock contention.

## Goal

Mutations return an *accepted-pending* result instead of a lock error
when a refresh is in flight:

1. `add_document` writes the file (+ hash sidecar bookkeeping) without
   joining the write lock, returns immediately with
   `indexed: false` and an `index_status` payload, and enqueues the
   embed behind the current refresh.
2. `delete_document` deletes the file the same way; orphan vectors are
   already tolerated until rebuild, so the semantic is unchanged —
   only the lock coupling is removed.
3. The embedded refresh that eventually walks the filesystem picks the
   write up through the existing hash-sidecar drift detection — no new
   consistency machinery.

## Design

### 1. Accept path (no write lock)

`add_document` keeps `resolveKbPath`, `assertKbWritePolicyAllowsMutation`,
ancestor-dir collection, `mkdir -p`, and `fsp.writeFile` — all of which
are filesystem operations needing no index lock. The policy boundary and
audit hooks (`beforeHash`, `snapshotDocumentForRollback`) stay.

What changes is what happens *after* the write lands:

- **Do not call `manager.updateIndex` inline.** `atomicSave` requires its
  caller to hold the write lock (`FaissIndexManager.ts` precondition);
  the embed must run under its own lock acquisition.
- Trigger a background refresh and return.

### 2. Embed scheduling — reuse `BackgroundRefreshCoordinator`, add pending semantics

`BackgroundRefreshCoordinator` (`src/retrieve-refresh.ts`, shipped in
#1235) is a single-flight runner keyed by model dir — but its
`trigger()` while a run is in flight is a no-op join with **no pending
flag**. That is correct for reads (staleness tolerance) and wrong for
mutations: if `add_document` writes a file while an in-flight refresh's
walk has already passed that directory, a no-op join would drop the
embed until some *other* trigger — possibly hours.

Options, in order of preference:

- **(a) Add a `pending` bit to the coordinator.** `trigger()` during an
  in-flight run sets `pending[key]`; on settle, if `pending`, the
  coordinator immediately starts one follow-up run and clears it. This
  is exactly the in-flight+pending serialization
  `ReindexTriggerWatcher` already implements — generalizing it into the
  shared refresh queue, as #1228 originally proposed. Bounded
  (one pending run, further triggers coalesce), no unbounded queue.
- **(b) Mutation path awaits `coordinator.settled(modelDir)` then
  re-triggers once.** Simpler, but leaves a settle→re-trigger gap where
  a second mutation can interleave — fine (still eventual), slightly
  more coordination code per caller.

The filesystem-is-truth model makes (a)'s bounded coalescing safe: a
follow-up run re-walks the disk and picks up *all* writes since the
previous walk began, not just the one that set the bit.

### 3. Response contract — reuse `index_status`

Mutations return, alongside today's fields:

```json
{
  "indexed": false,
  "index_status": {
    "refresh_mode": "background",
    "state": "refreshing" | "queued",
    "hint": "Write accepted; embeddings update when the current index refresh finishes."
  }
}
```

`index_status` is already shipped response-contract precedent (#1235) —
no new surface. `indexed: true` keeps the fast path identical when no
refresh is in flight and the embed can run inline immediately (see
§4).

### 4. Lock acquisition strategy

Two viable shapes:

- **(a) Try-lock, fallback to pending:** attempt `withWriteLock` with a
  minimal/zero retry budget. On success, run today's inline
  `updateIndex` and return `indexed: true`. On `WriteLockContentionError`,
  take the pending path. Preserves synchronous semantics in the common
  (uncontended) case — zero behavior change when nothing is running.
- **(b) Always pending:** never take the lock in the mutation tool; the
  embed is always background. Simpler control flow, but every
  `add_document` becomes async — a real semantic regression for callers
  that write-then-read immediately and previously got fresh results.

**(a) is the right default**: uncontended writes keep today's
guarantee; contended writes degrade to pending instead of failing.

### 5. `delete_document` specifics

Same accept/embed split, but:

- The delete itself is unconditional filesystem truth — no rollback
  analogue needed (nothing to restore if a later embed fails).
- Orphan vectors already persist until rebuild today, so staleness is
  not new; the response should say so explicitly:
  `"deleted": true, "indexed": false, "index_status": …` with a hint
  that retrieval may surface the doc until refresh.
- Privacy/unpublish concern: a caller deleting *because content is
  sensitive* may need the vector gone *now*, not eventually. Offer an
  opt-in `wait: true` arg that takes the lock and rebuilds
  synchronously (today's behavior) for that case.

### 6. Error surfacing (carried from the TODO doc)

When the pending path *is* taken, the response should include what
today's blind error hides: read `.kb-write.lock.owner.json` (pid,
command, started_at — `write-lock.ts:172`) and `.reindex.run.json`
(`checkReindexRunState`) and embed `owner`/`progress` in
`index_status`. "Reindex started 14 min ago by `kb reindex`, 340/1157
files" beats "retry later." Independent of the rest of this RFC — small,
uncontroversial, can ship first.

## Staleness semantics — the open decision

The all-or-nothing rollback exists to eliminate half-indexed state. A
pending-accept design replaces it with "dirty file awaiting embed" —
representable, since hash sidecars already track file-vs-index drift —
but it needs an explicit contract:

- **Retrieval may serve stale results** until the pending embed lands.
  Under `KB_RETRIEVE_REFRESH_MODE=async` this is *already* the
  documented behavior (`served_from: committed_snapshot`); the mutation
  RFC aligns writes to the same model rather than introducing a new one.
- **Write-then-read clients must check `index_status.state`** — the
  hint tells the calling LLM to requery or tolerate the gap.
- **Failure propagation**: if the background embed fails, the sidecar
  drift stays marked and the next refresh retries — failure is
  recoverable by construction, unlike `AddDocumentRollbackError` which
  destroyed the accepted write.

## Explicitly out of scope

- **Per-KB locks** — require per-KB indexes (an architectural fork of
  the shared FAISS store; breaks or complicates cross-KB retrieval).
- **Per-document locks** — meaningless against full-index atomic swaps.
- **Incremental vector-store mutation** (sqlite-vec/LanceDB) — the
  deferred alternative; revisit only if pending-writes become routine
  rather than occasional.
- **Trigger watcher / `kb reindex` behavior** — unchanged; they remain
  the writers.

## Milestones

- **M0** — surface lock owner + run-state in `index_status`/error
  payloads (§6). Standalone, unblocks observability immediately.
- **M1** — coordinator `pending` bit + `add_document` try-lock→pending
  path. Ships the semantic change for adds.
- **M2** — `delete_document` same treatment + `wait: true` opt-in.
- **M3** — MCP `reindex_status` tool (read-only, wraps
  `computeReindexProgress`) so clients can distinguish "locked,
  progressing" from "locked, wedged" without CLI access.

## Acceptance

- During a held `updateIndex` (trigger watcher or `kb reindex`),
  `add_document` returns `indexed: false` + `index_status` instead of
  `REFRESH_LOCK_BUSY`, and the document appears in retrieval once the
  follow-up refresh lands — verified by an integration test that holds
  the lock across the call.
- Uncontended `add_document` keeps synchronous `indexed: true`
  semantics (existing tests unchanged).
- No spec file may poison a shared worker's state — the pending path
  takes no lock it doesn't release.
