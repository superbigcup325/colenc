/// Drives the sketch from the acceptance rig. Every command prints
/// `RESULT|key|value` lines so the Python side never parses prose.

///|
fn parse_int(text : String) -> Int32 {
  let mut value = 0
  for char in text {
    value = value * 10 + (char.to_int() - 48)
  }
  value
}

///|
fn parse_uint64(text : String) -> UInt64 {
  let mut value = 0UL
  for char in text {
    value = value * 10UL + (char.to_int() - 48).to_uint64()
  }
  value
}

///|
fn mix64(value : UInt64) -> UInt64 {
  let mut x = value
  x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9UL
  x = (x ^ (x >> 27)) * 0x94d049bb133111ebUL
  x ^ (x >> 31)
}

///|
/// A deterministic value stream: the same seed and count always produce the same
/// ids, so a rerun on another backend or another day compares the same input.
fn probe_value(seed : UInt64, index : Int32) -> Int64 {
  mix64(seed + 0x9e3779b97f4a7c15UL * index.to_uint64()).reinterpret_as_int64()
}

///|
fn checksum(bytes : Bytes) -> Int32 {
  let mut hash = 0
  for index in 0..<bytes.length() {
    hash = (hash * 31 + bytes[index].to_int()) % 1000000007
  }
  hash
}

///|
fn take(args : Array[String], from : Int32, count : Int32) -> Array[String] {
  let out : Array[String] = []
  let end = from + count
  let mut index = from
  while index < end {
    out.push(args[index])
    index += 1
  }
  out
}

///|
fn build(rest : Array[String], repeat : Int32) -> @sketches.HllSketch {
  let precision = parse_int(rest[0])
  let seed = parse_uint64(rest[1])
  let count = parse_int(rest[2])
  let sketch = @sketches.HllSketch::new(precision) catch {
    error => abort(@types.EncodingError::message(error))
  }
  for index in 0..<count {
    let value = probe_value(seed, index)
    for _ in 0..<repeat {
      sketch.add_int64(value)
    }
  }
  sketch
}

///|
fn accepts(bytes : BytesView) -> Bool {
  try {
    let _ = @sketches.HllSketch::from_bytes(bytes)
    true
  } catch {
    _ => false
  }
}

///|
fn corrupt(bytes : Bytes, offset : Int32, value : Int32) -> Bytes {
  let copy = FixedArray::make(bytes.length(), b'\x00')
  for index in 0..<bytes.length() {
    copy[index] = bytes[index]
  }
  copy[offset] = value.to_byte()
  Bytes::from_array(copy.exact_view())
}

///|
fn reject_cases(rest : Array[String]) -> Unit {
  let sketch = build(rest, 1)
  let bytes = sketch.to_bytes()
  println("RESULT|bad_version|\{!accepts(corrupt(bytes, 0, 9).exact_view())}")
  println("RESULT|bad_precision|\{!accepts(corrupt(bytes, 1, 2).exact_view())}")
  println(
    "RESULT|bad_register|\{!accepts(corrupt(bytes, 2, 255).exact_view())}",
  )
  println("RESULT|truncated|\{!accepts(bytes.exact_view(start=0, end=5))}")
  let other = build(rest, 1)
  let mismatch = try {
    let bigger = @sketches.HllSketch::new(sketch.precision() + 1) catch {
      _ => abort("precision rejected")
    }
    let _ = other.merge(bigger)
    false
  } catch {
    _ => true
  }
  println("RESULT|merge_precision_mismatch|\{mismatch}")
}

///|
fn main {
  let argv = @env.args()
  if argv.length() < 2 {
    abort("usage: hll_probe <build|merge|roundtrip|reject> ...")
  }
  match argv[1] {
    "build" => {
      let sketch = build(take(argv, 2, 3), 1)
      println("RESULT|precision|\{sketch.precision()}")
      println("RESULT|registers|\{sketch.register_count()}")
      println("RESULT|estimate|\{sketch.estimate()}")
      println("RESULT|bytes_length|\{sketch.to_bytes().length()}")
      println("RESULT|bytes_checksum|\{checksum(sketch.to_bytes())}")
    }
    "duplicates" => {
      let repeat = parse_int(argv[5])
      let sketch = build(take(argv, 2, 3), repeat)
      println("RESULT|estimate|\{sketch.estimate()}")
      println("RESULT|bytes_checksum|\{checksum(sketch.to_bytes())}")
    }
    "stats" => {
      let sketch = build(take(argv, 2, 3), 1)
      let mut max_rank = 0
      let mut sum_rank = 0
      let mut empty = 0
      let mut one = 0
      for rank in sketch.registers() {
        if rank > max_rank {
          max_rank = rank
        }
        sum_rank += rank
        if rank == 0 {
          empty += 1
        }
        if rank == 1 {
          one += 1
        }
      }
      println("RESULT|max_rank|\{max_rank}")
      println("RESULT|sum_rank|\{sum_rank}")
      println("RESULT|empty|\{empty}")
      println("RESULT|rank_one|\{one}")
      println("RESULT|estimate|\{sketch.estimate()}")
    }
    "merge" => {
      // a from seed A over nA, b from seed B over nB, c from seed C over nC.
      let first = build([argv[2], argv[3], argv[4]], 1)
      let second = build([argv[2], argv[5], argv[6]], 1)
      let third = build([argv[2], argv[7], argv[8]], 1)
      let left = (first.merge(second) catch {
        error => abort(@types.EncodingError::message(error))
      }).merge(third) catch {
        error => abort(@types.EncodingError::message(error))
      }
      let right = first.merge(
        second.merge(third) catch {
          error => abort(@types.EncodingError::message(error))
        },
      ) catch {
        error => abort(@types.EncodingError::message(error))
      }
      let swapped = (second.merge(first) catch {
        error => abort(@types.EncodingError::message(error))
      }).merge(third) catch {
        error => abort(@types.EncodingError::message(error))
      }
      println("RESULT|associativity|\{left.to_bytes() == right.to_bytes()}")
      println("RESULT|commutativity|\{left.to_bytes() == swapped.to_bytes()}")
      println(
        "RESULT|operands_untouched|\{first.to_bytes() != second.to_bytes()}",
      )
      println("RESULT|bytes_checksum|\{checksum(left.to_bytes())}")
      println("RESULT|estimate|\{left.estimate()}")
    }
    "roundtrip" => {
      let sketch = build(take(argv, 2, 3), 1)
      let bytes = sketch.to_bytes()
      let back = @sketches.HllSketch::from_bytes(bytes.exact_view()) catch {
        error => abort(@types.EncodingError::message(error))
      }
      println("RESULT|roundtrip|\{back.to_bytes() == bytes}")
      println("RESULT|precision_kept|\{back.precision() == sketch.precision()}")
      println("RESULT|bytes_checksum|\{checksum(bytes)}")
      println("RESULT|estimate|\{sketch.estimate()}")
    }
    "reject" => reject_cases(take(argv, 2, 3))
    _ => abort("unknown command \{argv[1]}")
  }
}
