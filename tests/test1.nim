import os
import unittest

import zopflipng
test "output file size less than original one":
  let src = "logo.png"
  let dest = "logo_out.png"
  optimizePNG(src, dest)
  doAssert getFileSize(dest) > 0
  doAssert getFileSize(dest) < getFileSize(src)
