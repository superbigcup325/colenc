///|
/// The ceiling a decoder applies to the value count it was asked for.
///
/// A page header supplies `num_values`, and several families encode a very
/// large count in a handful of bytes: a hybrid stream at bit width zero, a
/// delta block whose deltas are all zero and a dictionary repeat run all
/// describe 2^31 - 1 values with a few bytes. That is a valid stream, so no
/// input check can reject the count without rejecting a page a writer could
/// have produced. The decoder still has to allocate `count` values, which turns
/// an untrusted header into a memory lever: 2^31 - 1 `Int64` values is 16 GiB,
/// and on wasm-gc the allocation request traps the process rather than raising.
///
/// This ceiling turns that into a typed error. It is a policy, not a format
/// limit, so every decoder that takes it also takes a per-call override: raise
/// it when a caller legitimately decodes more than this in one page. The
/// default is 4096 times the largest batch the in-tree consumer writes (one
/// page per 4096-row batch) and 16 times the most values a 1 MiB page of
/// one-byte values can hold, so a real page stays far below it, while the worst
/// allocation an untrusted header can force is 128 MiB.
pub const DEFAULT_MAX_VALUES : Int32 = 16777216

///|
/// The count above which a decoder walks the stream before it allocates.
///
/// The ceiling above bounds the worst case, but the output is still sized from
/// the count before the stream is read, so a body that claims the count and
/// ends short pays for it first. Walking the runs or miniblocks once without
/// unpacking and only then allocating removes that, at the cost of a second
/// pass over the run and block headers: measured on `harness/perf -- families`,
/// the DELTA_BINARY_PACKED decoders lost 17% to 27% of their decode time at
/// 500k values when the pass ran unconditionally, which is the same 20% the
/// last three decode PRs bought back.
///
/// So the pass runs only where the allocation is worth protecting. At 2^20
/// values the output is at least 4 MiB and at most 8 MiB, which is above any
/// page a writer produces: the in-tree consumer writes 4096-value pages, and a
/// 1 MiB Parquet page holds at most about 1M one-byte values. Below the
/// threshold the allocation is a few megabytes at worst and the single-pass
/// path stays, so a real page decodes exactly as fast as it did before.
pub const PREVALIDATE_ABOVE : Int32 = 1048576
