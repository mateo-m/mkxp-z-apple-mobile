# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# Input.repeat? under fast-forward. A person holds a key for real
# seconds, but fast-forward runs n updates for each frame on the
# screen. The repeat delay must stay 0.4 s of real time, or a short
# press moves a menu cursor two or more steps. tests/host/host.m reads
# each "key" dialog as a key press.
#
#   tools/run-engine-tests.sh --suite input_repeat.rb
#   tools/run-engine-tests.sh --suite input_repeat.rb --fast-forward 4

unless defined?(EngineTest)
  harness_path = File.join(File.dirname(__FILE__), 'harness.rb')
  eval(File.read(harness_path), TOPLEVEL_BINDING, harness_path) # rubocop:disable Security/Eval
end

EngineTest.suite('input-repeat', 3)

SCANCODE_DOWN = 81

# Fills Graphics.average_frame_rate, which sets the repeat delay.
60.times { Graphics.update }

# The block gets the seconds since the press, before each update.
def repeats_for_press(seconds)
  msgbox("key #{SCANCODE_DOWN} #{seconds}")
  repeats = 0
  pressed = false
  start = Time.now
  while Time.now - start < seconds + 2
    yield Time.now - start if block_given?
    Graphics.update
    Input.update
    if Input.press?(Input::DOWN)
      pressed = true
      repeats += 1 if Input.repeat?(Input::DOWN)
    elsif pressed
      break
    end
  end
  repeats
end

EngineTest.test('a press of 0.25 s repeats once') do
  repeats = repeats_for_press(0.25)
  EngineTest.assert(repeats == 1, "Input.repeat? was true #{repeats} times")
end

# 1 at the press, then one each 0.1 s from 0.4 s on.
EngineTest.test('a press of 1 s repeats as at normal speed') do
  repeats = repeats_for_press(1.0)
  EngineTest.assert((5..8).include?(repeats), "Input.repeat? was true #{repeats} times")
end

# The 0.15 s held at 4x still count as 0.15 s after the switch to 1x.
EngineTest.test('a press of 0.3 s repeats once when fast-forward stops during the press') do
  msgbox('fast-forward 4')
  stopped = false
  repeats = repeats_for_press(0.3) do |held|
    if held >= 0.15 && !stopped
      msgbox('fast-forward 1')
      stopped = true
    end
  end
  msgbox('fast-forward 0')
  EngineTest.assert(repeats == 1, "Input.repeat? was true #{repeats} times")
end

EngineTest.finish
exit
