
import unittest

import zopflipng
test "can add":
  let src = "logo.png"
  let dest = "logo_out.png"
  optimizePNG(src, dest)
