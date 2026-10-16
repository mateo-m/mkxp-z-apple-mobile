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

wall_start = Time.now
clock_start = System.uptime
frames = 0
while Time.now - wall_start < 2.0
  Graphics.update
  frames += 1
end
clock_rate = (System.uptime - clock_start) / (Time.now - wall_start)
drawn_frame_rate = frames / (Time.now - wall_start) / MULTIPLIER

EngineTest.test('System.uptime runs at the fast-forward speed') do
  EngineTest.assert((clock_rate - MULTIPLIER).abs < MULTIPLIER * 0.1,
                    format('clock rate %.2f, expected %d', clock_rate, MULTIPLIER))
end

EngineTest.test('Graphics.average_frame_rate counts drawn frames in real time') do
  average = Graphics.average_frame_rate
  EngineTest.assert((average - drawn_frame_rate).abs < drawn_frame_rate * 0.15,
                    format('average %.1f, drawn %.1f', average, drawn_frame_rate))
end

EngineTest.finish
exit
