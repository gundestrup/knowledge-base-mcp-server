# RFC 023 — Semantic Content Hash: Stop Re-Embedding on Tool-Owned Frontmatter

**Status:** Proposed
**Depends on:** frontmatter-lift whitelist (`src/frontmatter-lift.ts`),
change detection via `source_sha256` chunk manifests
**Composes with:** RFC 017 (contextual retrieval — prefaces inherit the
same staleness signal), the KBM-flow curation-tool workflow that
motivates it
**Tracks:** removing the re-embed amplifier that turns cheap metadata
stamps into minutes-long index holds
**Prior art:** flagged in issue #1228 ("Related / separable") —
upstream agreed it is the real amplifier and deferred it for design

## Problem

Change detection hashes **whole source-file bytes** (`source_sha256`
in `<kb>/.index/*.chunks.json`). Any byte change marks the file changed
and re-chunks + re-embeds it.

But a growing class of writes is **tool-owned metadata stamps**:
`kbm.freshness`, `kbm.link_check`, `document_id`, curation-workflow
annotations inserted by companion tools (e.g. KBM-flow). These keys are
*not* in the frontmatter lift whitelist — `frontmatter-lift.ts` drops
them — so they produce **byte-identical embeddings**. The file
"changed" in exactly the bytes that don't reach the vector.

Production impact (from #1228): a curation tool stamping frontmatter on
~600 files forced whole-corpus re-embeds, turning routine stamps into
100–1200 s `updateIndex` lock holds — and, before `async` retrieve
mode, multi-minute reads. The cost is paid in the worst currency:
embedding latency and lock hold time, for zero vector change.

## Goal

Change detection should answer "would the embeddings differ?", not "did
the file bytes differ?". Introduce a **semantic content hash** computed
over the parts of the source that actually feed the vector:

```
semantic_hash = sha256(
  parsed_body_text
  + whitelisted_frontmatter_fields_that_reach_embeddings
  + chunking/config inputs
)
```

Writes that only touch dropped frontmatter keys hash identically →
file counts as unchanged → no re-chunk, no re-embed, no lock hold.

## Design

### 1. Hash input definition

The input must be *exactly* the bytes that determine chunk text and
metadata — no more (misses would skip real changes), no less (extra
bytes reintroduce the amplifier):

- **Body** — the parsed document text actually chunked (post
  frontmatter strip, post any format conversion). This is the dominant
  input.
- **Whitelisted frontmatter that reaches embeddings** — the keys
  `frontmatter-lift.ts` admits (`title`, `authors`, `published`, …)
  **if and only if** they are prepended into embedded text or land in
  chunk metadata that is embedded. Keys lifted to metadata *but not
  embedded* must stay out, or stamps on them re-add the amplifier.
- **Chunker/config inputs** — `chunk_size`, `chunk_overlap`, generator
  version — so a chunking change still invalidates (this is already
  sidecar-validated; keep semantics consistent).
- **Explicitly excluded:** `kbm.*` and every non-whitelisted key —
  *that is the point.*

### 2. The whitelist question — the real design risk

The dangerous failure is **too broad**: hashing a field that doesn't
reach the vector reintroduces the amplifier for that field; **too
narrow** is worse — silently missing real content changes means stale
vectors that *look* fresh. Design constraints:

- Derive the embedded frontmatter set from the embedding-construction
  code path (what `buildChunkDocuments`/`EMBEDDING_TEMPLATE` actually
  concatenate), not from a hand-maintained list that drifts.
- `title` is the judgment call: it commonly feeds chunk context. If it
  embeds, it's in; if it's metadata-only, it's out.
- The frontmatter-lift whitelist is a *superset* candidate — the
  semantic-hash whitelist is the subset of it that reaches the vector.
  Two lists, explicitly related, or drift between them reintroduces the
  bug.

### 3. Migration — the known cost

Every stored `source_sha256` uses the old definition. On upgrade all
manifests mismatch → **one-time full re-embed of every corpus**. There
is no dual-hash trick that avoids it (old hashes can't be recomputed
under the new definition without re-embedding anyway).

Mitigations:

- Ship behind a flag or as a marked "rehash migration" that runs once,
  inside the existing trigger/`kb reindex` machinery — the corpus
  already tolerates full rebuilds.
- Emit both hashes during a transition window (write `source_sha256`
  + `semantic_sha256` fields) so rollback/re-check is possible; drop
  the legacy field a release later.
- Clearly release-note the one-time cost — it is a known, bounded
  spike, vs. the unbounded recurring cost today.

### 4. Interaction with contextual prefaces

Preface sidecars key on `document_hash` — the same amplifier applies
twice over (re-prefacing files whose embeddings didn't actually
change). The semantic hash should feed `document_hash` too, or
prefaces get invalidated by the same non-semantic writes the FAISS side
learned to ignore. Keep one definition, two consumers.

### 5. Failure mode guard

If parsing fails (malformed frontmatter, unreadable body), fall back to
whole-byte hashing — a parse failure must fail *closed* (treat as
changed), never silently skip a real edit.

## Explicitly out of scope

- **Selective re-embed of unchanged chunks** (chunk-level semantic
  hashing) — bigger win, bigger design; file-level first.
- **Frontmatter whitelist changes themselves** — what `kbm.*` means is
  the curation tool's contract, not this RFC.
- **The original #1228 lock semantics** — solved separately
  (`async` mode + RFC 022).

## Acceptance

- A write that only touches `kbm.*` frontmatter produces
  `files_unchanged` for that source — verified by a fixture test that
  stamps a dropped key and asserts zero re-embed.
- A body edit still re-embeds (semantic hash changes).
- A whitelisted-frontmatter edit re-embeds iff the field feeds the
  vector.
- Malformed frontmatter → whole-byte fallback → file re-embedded.
- Migration: upgrade path documented; a run reports the one-time
  re-embed as expected, not an error.
