///|
/// The largest value count `bit_unpack` will allocate for.
///
/// Same policy and the same number as `types.DEFAULT_MAX_VALUES`, and a second
/// constant on purpose: this package sits below the model layer, and `types`
/// declares no imports at all (that is what keeps consumer types out of the
/// public API), so the primitive cannot borrow the model's ceiling. The two
/// values have to move together — the encoders and the facade take the `types`
/// one as their default, and a primitive that is stricter or looser than its
/// callers would be a trap.
///
/// The count is the memory lever *here* specifically because a width of zero
/// carries no bytes: `bit_unpack(b"", 0, 2^31 - 1)` asks for 16 GiB while the
/// length check above it derives a requirement of zero, so no input check can
/// refuse it — only a ceiling can. Both library callers clamp what they ask for
/// (the hybrid walk and the delta miniblock walk unpack only the values the
/// caller requested, and those are already ceiling-checked), so this bound is
/// for the consumer that calls the primitive directly, which is the case
/// AGENTS.md records under "a public primitive is part of the decode surface".
pub const DEFAULT_MAX_VALUES : Int32 = 16777216
