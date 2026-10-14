# frozen_string_literal: true

# Thingie's obfuscation scan reads the whole of every changed file, so a sample blob in a spec that changes often
# flags every PR that touches that spec. Kept here, it only flags a PR that edits this file.
module ObfuscationSamples
  # 80+ hex chars, over the HEX_BLOB detection threshold.
  HEX_BLOB = '4142434445464748494a4b4c4d4e4f505152535455565758595a6162636465666768696a6b6c6d6e6f70'
end
