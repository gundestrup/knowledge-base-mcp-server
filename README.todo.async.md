# Async writes vs. the refresh lock — analysis & TODO

Analyzed 2026-11-17 after `add_document` on the `engineering-memory` KB
was rejected with `REFRESH_LOCK_BUSY` ("Refresh lock is already held
for this model. Retry after the current refresh finishes.") while a
trigger-watcher refresh was running.

Status: **analysis only — no code changed.** Proposals below are
candidates for RFCs, not commitments.

Updated 2026-11-25 after upstream landed issue #1228 — see
"Status after upstream #1235" below.

## The incident

- `.reindex-trigger` in the KB was touched at 23:51; a trigger-watcher
  `updateIndex` was still running the next afternoon and held the
  per-model write lock the entire time.
- Every `add_document` call during that window exhausted the retry
  budget (~5 retries, ≤ 1 s each) and returned `WriteLockContentionError`.
- Workaround used: write the `.md` files directly into the KB tree.
  The in-flight refresh's filesystem walk picked them up — document
  count 602 → 603 and both docs became retrievable when the index
  swapped in. Zero divergence, because **the filesystem is the source
  of truth and the FAISS index is derived state**.

## How the lock works today

- `withWriteLock(resource, fn)` in `src/write-lock.ts` takes a
  `proper-lockfile` lock (`.kb-write.lock`) on a directory — callers
  pass `manager.modelDir`, so the lock is already **per-model**
  (`models/<id>/`), not global. Per-KB does not exist because one
  FAISS store spans every KB (cross-KB retrieval is a feature).
- Retry budget is intentionally tiny (~2 s) for the fast path; the
  heartbeat (`update: 5000`, `stale: 10 s`) keeps the lock alive
  across long slow-path holds — model-switch re-embeds and
  `updateIndex(..., {force:true})` rebuilds legitimately hold it for
  minutes.
- The lock is held for the **full duration of `fn`** — including all
  embedding calls — not just the atomic index save.
- `add_document` (`src/mcp-document-mutations.ts:276-296`) bundles
  `fsp.writeFile` **and** `manager.updateIndex(kb)` inside the same
  `withWriteLock` — accepting a write and embedding it are one
  synchronous transaction. Worse, the contract is strictly
  all-or-nothing: if `updateIndex` fails after the write,
  `rollbackAddDocumentWrite` deletes the file again and
  `AddDocumentRollbackError` is thrown. There is no
  "accepted, pending index" path at all. That coupling is the actual
  cause of the incident's UX, not the lock itself.
- Already present but unused by the error path:
  `.kb-write.lock.owner.json` (pid, command, started_at —
  `write-lock.ts:187-201`), `.reindex.run.json` run-state
  (`checkReindexRunState` in `src/reindex-runner.ts`), and the
  CLI-only progress surface `kb reindex status`
  (`src/reindex-progress.ts`).

## Why finer-grained locking is the wrong fix

- **Per-document locks are meaningless here.** The unit of atomic
  mutation is the whole FAISS index file — saves are version-atomic
  full-index swaps. Locking `foo.md` cannot stop a rebuild that walks
  the filesystem, and FAISS supports no concurrent mutation anyway.
- **Per-KB locks require per-KB indexes** — an architectural fork
  (splitting the shared store), not a lock tweak. It would also break
  cross-KB retrieval or require result merging.
- The real defect is a **synchronous accept-and-embed contract** on a
  system whose storage is already eventually consistent. The manual
  bypass proved the safe path: write file + hash sidecar, let the
  next refresh's walk embed it.

## Status after upstream #1235

Upstream implemented issue #1228 in PR #1235
(`KB_RETRIEVE_REFRESH_MODE` = `sync` | `async` | `off`), merged
2026-11-12 and since pulled into this fork. It fixes the **read
path**, which was #1228's scope: in `async` mode
`retrieve_knowledge` serves from the committed index snapshot via a
cached read-only manager and never joins the write lock; the
refresh is backgrounded through `BackgroundRefreshCoordinator`
(`src/retrieve-refresh.ts`), a single-flight runner keyed by model
dir. Responses carry `index_status` (`refresh_mode`, `state`,
`served_from`) — shipped without ETA/`pending_files`, which
upstream deliberately left out of the contract.

### What it does not fix — the mutation path analyzed here

- `add_document`/`delete_document` still couple write + embed in
  one `withWriteLock` with all-or-nothing rollback. Any writer
  holding the lock still rejects mutations with
  `REFRESH_LOCK_BUSY` after the ~2 s budget — the incident's exact
  failure mode stands.
- `sync` remains the default, so reads still join the lock unless
  deployments opt in. Set `KB_RETRIEVE_REFRESH_MODE=async` — it
  removes the entire class of read-path lock contenders, leaving
  mutations to contend only with real writers. Upstream invited
  dogfooding before considering `async` the default.

### What it changes for the TODO below

- **Item 1's "enqueue the embed" option now has a substrate.**
  `BackgroundRefreshCoordinator.trigger(modelDir, run)` is the
  shared single-flight queue; a decoupled accept path can write the
  file + sidecar, return `index_status: 'refreshing'`, and let the
  coordinator run the embed under its own lock acquisition.
- **`index_status` is now response-contract precedent.** A
  mutation tool returning `{ indexed: false, index_status }` for an
  accepted-pending write matches an established shape — no new
  contract surface needed.
- **Semantic content hash stays open.** The `kbm.*` frontmatter
  amplifier from #1228 was explicitly deferred upstream: redefining
  the hash forces a one-time full re-embed and needs a frontmatter
  whitelist design. Worth its own RFC — directly relevant to
  workflows where a curation tool stamps frontmatter.
- **ETA/`pending_files` in `index_status` was declined for now** —
  upstream will revisit if a caller would act on it. Our
  `reindex_status` tool idea (item 3) covers the same need without
  coupling the retrieve contract to indexer internals.

## TODO

- [ ] **Decouple accept from embed in `add_document`.** Write the file
      and update the hash sidecar under a short lock (or none — the
      sidecar write is tmp+rename), then either return immediately with
      `indexed: false`/`pending` in the response and let the next
      refresh pick it up, or enqueue the embed behind the current
      refresh. The refresh-walks-disk design makes this safe by
      construction — that is the desired async semantic: accepted now,
      indexed eventually.
- [ ] **Surface lock owner + run state in `WriteLockContentionError`.**
      The error already carries `lockPath`; read
      `.kb-write.lock.owner.json` and `.reindex.run.json` and include
      pid/command/started_at/progress in the message. "Refresh
      started 14 min ago by `kb reindex`, 340/602 files" beats
      "retry later."
- [ ] **Expose refresh status as an MCP tool.** `kb reindex status`
      (`computeReindexProgress`) exists CLI-only; a read-only
      `reindex_status` tool would let MCP clients distinguish
      "locked, progressing" from "locked, wedged" instead of blind
      retry.
- [ ] **Document the direct-write fallback.** Clients hitting
      `REFRESH_LOCK_BUSY` today must discover that writing the file
      directly is safe (eventual consistency by design). Either
      bless it in the `add_document` description/error text or keep
      it deliberately undocumented — decide explicitly.
- [ ] **(Deferred, probably rejected) vector store with incremental
      mutation** — sqlite-vec/LanceDB-style stores would allow true
      per-doc indexing without rebuilds, at the cost of the embedded
      FAISS choice. Only revisit if writes-during-refresh becomes a
      routine need rather than an occasional collision.

## Notes for whoever implements

- `atomicSave` already *requires* its caller to hold the write lock
  (`FaissIndexManager.ts:1285` precondition comment) — the decoupled
  accept path must not call `updateIndex` inline; the embed must run
  under its own lock acquisition.
- The all-or-nothing rollback exists for good reasons (no half-indexed
  state to reason about). A pending-accept design replaces it with a
  "dirty file awaiting embed" state — hash sidecars already track
  file-vs-index drift for refresh, so the state is representable; it
  needs an explicit decision on staleness semantics.
- Watch `src/write-lock.ts` M1+M2 comments: per-model `modelDir`
  locking is what callers pass today; any per-KB scheme must be
  designed against the shared-store reality.
- `delete_document` has the same accept-vs-embed coupling
  (`mcp-document-mutations.ts:385`+) and additionally leaves orphan
  vectors until rebuild — same proposal applies.
