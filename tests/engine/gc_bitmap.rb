# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# A game that drops a large bitmap on each frame does not fill the GPU
# memory. Pokemon Xenoverse clones a 1024x1024 background on each frame
# of a trade. The pixels are not on the Ruby heap, so the interpreter
# alone collects too late, and iOS stops the app.
#
#   tools/run-engine-tests.sh --suite gc_bitmap.rb --ruby 18
#
# This file must parse on all three interpreters.

unless defined?(EngineTest)
  harness_path = File.join(File.dirname(__FILE__), 'harness.rb')
  eval(File.read(harness_path), TOPLEVEL_BINDING, harness_path) # rubocop:disable Security/Eval
end

EngineTest.suite('gc-bitmap', 1)

DROPS = 600
# 400 MB of 1024x1024 bitmaps.
MAX_LIVE = 100

def live_bitmaps
  count = 0
  ObjectSpace.each_object(Bitmap) { |b| count += 1 unless b.disposed? }
  count
end

EngineTest.test('dropped bitmaps are collected before they fill the memory') do
  GC.start
  source = Bitmap.new(1024, 1024)
  shown = nil
  most = 0
  DROPS.times do |i|
    shown = source.clone
    most = [most, live_bitmaps].max if i % 20 == 0
  end
  EngineTest.assert(most <= MAX_LIVE, "#{most} bitmaps were alive at one time")
end

EngineTest.finish
exit
