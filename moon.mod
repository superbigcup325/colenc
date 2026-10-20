// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html

name = "superbigcup325/colenc"

version = "0.1.0"

readme = "README.md"

repository = "https://github.com/superbigcup325/colenc"

license = "Apache-2.0"

keywords = [ "parquet", "columnar", "encoding", "compression", "bit-packing" ]

description = "Columnar encoding kernel for MoonBit: the Parquet page-level encoding family as a reusable, verifiable, pluggable library."

import {
  "moonbitlang/x@0.5.6",
  "moonbitlang/quickcheck@0.15.0",
}
