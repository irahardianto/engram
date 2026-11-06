# Research Verification Archive

> **Historical Context:** The files in this directory (`V01`–`V07`) are empirical verification audits of the Phase 1 prior-art and technology research documents in [`../`](../README.md). Each report verified claims in `01-hindsight.md` through `07-temporal-kg-and-evals.md` against primary source repositories, live SurrealDB `v3.3.4` containers, Cargo dependency trees, and upstream benchmark papers.
>
> All errata uncovered by `V01`–`V07` were incorporated into [`../README.md`](../README.md), [`../../../DISCOVERY_HANDOFF.md`](../../../DISCOVERY_HANDOFF.md), and the normative specification package in [`../../spec/README.md`](../../spec/README.md).

## Verification Reports

| Report | Verified Target | Primary Evidence Used |
|---|---|---|
| [`V01-hindsight.md`](./V01-hindsight.md) | [`../01-hindsight.md`](../01-hindsight.md) | `vectorize-io/hindsight` source (`b4a0da1e`) |
| [`V02-cognee.md`](./V02-cognee.md) | [`../02-cognee.md`](../02-cognee.md) | `topoteretes/cognee` source (`v1.6.5`) |
| [`V03-mem0.md`](./V03-mem0.md) | [`../03-mem0.md`](../03-mem0.md) | `mem0ai/mem0` source (`2c81af3b`) |
| [`V04-hermes-integration.md`](./V04-hermes-integration.md) | [`../04-hermes-integration.md`](../04-hermes-integration.md) | `NousResearch/hermes-agent` source (`v0.22.4`) |
| [`V05-surrealdb.md`](./V05-surrealdb.md) | [`../05-surrealdb.md`](../05-surrealdb.md) | Live `surrealdb/surrealdb:v3.3.4` container + `cargo tree` |
| [`V06-rust-stack-deployment.md`](./V06-rust-stack-deployment.md) | [`../06-rust-stack-deployment.md`](../06-rust-stack-deployment.md) | Live Cargo workspace compilation + `rmcp` / `axum` inspection |
| [`V07-temporal-kg-and-evals.md`](./V07-temporal-kg-and-evals.md) | [`../07-temporal-kg-and-evals.md`](../07-temporal-kg-and-evals.md) | Graphiti / Zep, LoCoMo, LongMemEval, and ConvoMem primary papers & repos |
