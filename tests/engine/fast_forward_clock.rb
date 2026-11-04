# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# The clocks under fast-forward. Pokemon Essentials v21 moves the
# player by System.uptime, not by frames, so that clock must speed up
# with the frames. The average frame rate still counts the frames
# drawn per real second. At a multiplier of n the engine draws one
# update in n.
#
#   tools/run-engine-tests.sh --suite fast_forward_clock.rb
#   tools/run-engine-tests.sh --suite fast_forward_clock.rb --fast-forward 4

unless defined?(EngineTest)
  harness_path = File.join(File.dirname(__FILE__), 'harness.rb')
  eval(File.read(harness_path), TOPLEVEL_BINDING, harness_path) # rubocop:disable Security/Eval
end

EngineTest.suite('fast-forward-clock', 2)

MULTIPLIER = [(ENV['MKXP_TEST_FAST_FORWARD'] || '1').to_i, 1].max
EngineTest.info('multiplier', MULTIPLIER)

# Graphics.average_frame_rate averages the last 41 frame times. A slow
# simulator draws fewer frames than that in 2 seconds, and the average
# then reaches back into the start-up. So draw at least 41 frames, and
# compare with the rate over those frames.
WINDOW = 41
wall_start = Time.now
clock_start = System.uptime
updates = []
while Time.now - wall_start < 2.0 || updates.size <= WINDOW * MULTIPLIER
  Graphics.update
  updates << Time.now
end
clock_rate = (System.uptime - clock_start) / (updates.last - wall_start)
window = updates.last((WINDOW * MULTIPLIER) + 1)
drawn_frame_rate = WINDOW / (window.last - window.first)

EngineTest.test('System.uptime runs at the fast-forward speed') do
  message = format('clock rate %<rate>.2f, expected %<expected>d',
                   :rate => clock_rate, :expected => MULTIPLIER)
  EngineTest.assert((clock_rate - MULTIPLIER).abs < MULTIPLIER * 0.1, message)
end

EngineTest.test('Graphics.average_frame_rate counts drawn frames in real time') do
  average = Graphics.average_frame_rate
  message = format('average %<average>.1f, drawn %<drawn>.1f',
                   :average => average, :drawn => drawn_frame_rate)
  EngineTest.assert((average - drawn_frame_rate).abs < drawn_frame_rate * 0.15, message)
end

EngineTest.finish
exit
