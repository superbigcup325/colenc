/// Exercise the Roaring operation sequences that have no reference bytes.
///
///   moon run harness/roaring_ops_probe -- --out-dir <dir>
///
/// The byte-diff cases in `harness/check_roaring.py` only cover the add-only and
/// construct-then-`run_optimize` paths. These sequences cover the other two:
/// adding after `run_optimize` (where colenc de-optimises the run while CRoaring
/// keeps it, so the bytes legitimately differ) and mutating a set operation's
/// result (where an aliased container would rewrite an operand).
///
/// Each step writes its serialized stream to `<out-dir>/<step>.bin` and prints
/// one line: `step|<name>|<cardinality>|<bytes>|<fnv1a-32 of the ascending ids>`.
/// The checker parses the stream itself, so the library's own claims are only a
/// cross-check.

///|
fn consecutive(start : Int32, count : Int32) -> Array[Int32] {
  Array::makei(count, fn(index) { start + index })
}

///|
fn bitmap_of(ids : Array[Int32], what : String) -> @encoders.RoaringBitmap {
  @encoders.RoaringBitmap::from_ids(ids) catch {
    error =>
      abort(
        "\{what}: from_ids raised (\{@types.EncodingError::message(error)})",
      )
  }
}

///|
fn add(bitmap : @encoders.RoaringBitmap, id : Int32, what : String) -> Unit {
  bitmap.add(id) catch {
    error =>
      abort("\{what}: add raised (\{@types.EncodingError::message(error)})")
  }
}

///|
fn parse(bytes : Bytes, what : String) -> @encoders.RoaringBitmap {
  @encoders.RoaringBitmap::from_bytes(bytes) catch {
    error =>
      abort(
        "\{what}: from_bytes raised (\{@types.EncodingError::message(error)})",
      )
  }
}

///|
/// FNV-1a 32 over the ascending ids, four little-endian bytes each: a compact
/// way for the checker to compare the whole set without shipping it twice.
fn fnv1a(ids : Array[Int32]) -> Int64 {
  let mut hash = 2166136261L
  for id in ids {
    let value = id.to_int64() & 0xFFFFFFFFL
    for shift in [0, 8, 16, 24] {
      let byte = (value >> shift) & 0xFFL
      hash = ((hash ^ byte) * 16777619L) & 0xFFFFFFFFL
    }
  }
  hash
}

///|
fn report(
  directory : String,
  name : String,
  bitmap : @encoders.RoaringBitmap,
) -> Unit {
  let ids = bitmap.to_array()
  let bytes = bitmap.to_bytes()
  let path = "\{directory}/\{name}.bin"
  @fs.write_bytes_to_file(path, bytes) catch {
    @fs.IOError(message) => abort("cannot write \{path}: \{message}")
  }
  println(
    "step|\{name}|\{bitmap.cardinality()}|\{bytes.length()}|\{fnv1a(ids)}",
  )
}

///|
fn main {
  let args = @env.args()
  let mut directory = ""
  let mut index = 1
  while index < args.length() {
    if args[index] == "--out-dir" && index + 1 < args.length() {
      directory = args[index + 1]
      index += 2
    } else {
      eprintln("roaring_ops_probe: unexpected argument \{args[index]}")
      println("usage: moon run harness/roaring_ops_probe -- --out-dir <dir>")
      return
    }
  }
  if directory == "" {
    println("usage: moon run harness/roaring_ops_probe -- --out-dir <dir>")
    return
  }

  // A large run container, then one id added: the run has to be de-optimised
  // into a legal container instead of growing an array past 4096 values.
  let base = bitmap_of(consecutive(0, 5000), "base")
  report(directory, "base", base)
  base.run_optimize()
  report(directory, "base-run", base)
  add(base, 6000, "base-run")
  report(directory, "base-run-add", base)
  let reparsed = parse(base.to_bytes(), "base-run-add")
  report(directory, "base-run-add-reparse", reparsed)

  // A union that only one side contributes to must not share that container.
  let left = bitmap_of([1, 2], "union-left")
  let right = bitmap_of([65536], "union-right")
  report(directory, "union-left", left)
  report(directory, "union-right", right)
  let merged = left.union(right)
  add(merged, 3, "union")
  report(directory, "union", merged)
  report(directory, "union-left-after", left)
  report(directory, "union-right-after", right)

  // Both sides carry the same key.
  let even : Array[Int32] = []
  let odd : Array[Int32] = []
  for value in 0..<100 {
    if value % 2 == 0 {
      even.push(value)
    } else {
      odd.push(value)
    }
  }
  let evens = bitmap_of(even, "same-key")
  let odds = bitmap_of(odd, "same-key")
  report(directory, "same-key-union", evens.union(odds))

  // An intersect result, then mutated.
  let low = bitmap_of(consecutive(0, 100), "intersect")
  let high = bitmap_of(consecutive(50, 100), "intersect")
  let shared = low.intersect(high)
  report(directory, "intersect", shared)
  add(shared, 200, "intersect")
  report(directory, "intersect-add", shared)
  report(directory, "intersect-left-after", low)

  // A run container that takes part in a union and then receives an id.
  let runs = bitmap_of(consecutive(0, 5000), "run-union")
  runs.run_optimize()
  let run_union = runs.union(bitmap_of([65536], "run-union"))
  add(run_union, 6000, "run-union")
  report(directory, "run-union-add", run_union)

  // A run container that receives an id in a later key: the container itself
  // must stay untouched while a new key appears.
  let crossing = bitmap_of(consecutive(0, 5000), "cross-key")
  crossing.run_optimize()
  add(crossing, 131072, "cross-key")
  report(directory, "cross-key-add", crossing)
}
