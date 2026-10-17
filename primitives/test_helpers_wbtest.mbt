/// Test-only helper: run a fallible call that must raise, and hand back the
/// error so the test can match on its payload.

///|
fn capture_error(run : () -> Unit raise PrimitivesError) -> PrimitivesError {
  let mut captured : PrimitivesError? = None
  run() catch {
    error => captured = Some(error)
  }
  match captured {
    Some(error) => error
    None => abort("expected the call to raise")
  }
}
