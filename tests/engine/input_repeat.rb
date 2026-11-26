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

EngineTest.suite('input-repeat', 6)

SCANCODE_DOWN = 81

# Gives the seconds since the press of each Input.repeat?. The block
# gets the seconds since the press and the repeats so far, before each
# update. $longest_step is the longest time between two updates while
# the key was down: a frozen game sees fewer repeats.
def repeat_times(seconds)
  msgbox("key #{SCANCODE_DOWN} #{seconds}")
  times = []
  pressed = false
  $longest_step = 0
  start = Time.now
  last = start
  while Time.now - start < seconds + 2
    yield Time.now - start, times if block_given?
    Graphics.update
    Input.update
    now = Time.now
    $longest_step = [$longest_step, now - last].max
    last = now
    if Input.press?(Input::DOWN)
      pressed = true
      times << (Time.now - start) if Input.repeat?(Input::DOWN)
    elsif pressed
      break
    end
  end
  times
end

def longest_step
  "longest step #{format('%.3f', $longest_step)} s"
end

def repeats_for_press(seconds, &block)
  repeat_times(seconds, &block).size
end

EngineTest.test('a press of 0.25 s repeats once') do
  repeats = repeats_for_press(0.25)
  EngineTest.assert(repeats == 1, "Input.repeat? was true #{repeats} times, #{longest_step}")
end

# A slow step, such as a map that loads, must not make the next press
# repeat sooner.
EngineTest.test('a press of 0.25 s right after a slow step repeats once') do
  sleep 2
  Graphics.update
  repeats = repeats_for_press(0.25)
  EngineTest.assert(repeats == 1, "Input.repeat? was true #{repeats} times, #{longest_step}")
end

# 1 at the press, then one each 0.1 s from 0.4 s on.
EngineTest.test('a press of 1 s repeats as at normal speed') do
  repeats = repeats_for_press(1.0)
  EngineTest.assert((5..8).include?(repeats), "Input.repeat? was true #{repeats} times, #{longest_step}")
end

# The 0.15 s held at 4x still count as 0.15 s after the switch to 1x.
EngineTest.test('a press of 0.3 s repeats once when fast-forward stops during the press') do
  msgbox('fast-forward 4')
  stopped = false
  repeats = repeats_for_press(0.3) do |held, _so_far|
    if held >= 0.15 && !stopped
      msgbox('fast-forward 1')
      stopped = true
    end
  end
  msgbox('fast-forward 0')
  EngineTest.assert(repeats == 1, "Input.repeat? was true #{repeats} times, #{longest_step}")
end

# Normal speed repeats each 0.1 s, also at 4x. The stall makes the
# third repeat late, and the fourth must still wait 0.1 s. A slow step of
# the runner makes a gap longer by up to that step.
EngineTest.test('a held key repeats 0.1 s after its last repeat when fast-forward starts') do
  msgbox('fast-forward 1')
  started = false
  times = repeat_times(1.2) do |_held, so_far|
    if so_far.size == 2 && !started
      msgbox('fast-forward 4')
      sleep 0.25
      started = true
    end
  end
  msgbox('fast-forward 0')
  gaps = times.size >= 4 ? [times[2] - times[1], times[3] - times[2]] : [0, 0]
  longest = 0.1 + $longest_step + 0.03
  EngineTest.assert(gaps.all? { |gap| gap.between?(0.07, longest) },
                    "the repeats after the switch came #{gaps.inspect} s apart, #{longest_step}")
end

# Input.repeatex? first sees a key as held one update after the press.
EngineTest.test('Input.repeatex? repeats 0.4 s after the press also when a slow step follows it') do
  msgbox("key #{SCANCODE_DOWN} 1.0")
  start = Time.now
  first = nil
  slowed = false
  while first.nil? && Time.now - start < 3
    Graphics.update
    Input.update
    pressed = Input.pressex?(:DOWN)
    break if slowed && !pressed

    first = Time.now - start if Input.repeatex?(:DOWN)
    next unless pressed && !slowed

    sleep 0.5
    slowed = true
  end
  sleep 1
  Graphics.update
  Input.update
  EngineTest.assert(first && first < 0.7, "the first Input.repeatex? came #{first.inspect} s after the press")
end

EngineTest.finish
exit
