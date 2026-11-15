# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# The full-screen option of Pokemon Essentials v16 and v17 (the
# "Win32API" and "Sprite_Resizer" script sections) on the Win32API
# stand-ins of win32_wrap.rb. A screen size of 0 made the factor 0 and
# the offsets NaN, so a viewport raised "float nan out of range of
# integer" and the next Sprite#x= raised FloatDomainError.
#
#   tools/run-engine-tests.sh --suite full_screen_resizer.rb --ruby 18
#
# This file must parse on all three interpreters.

unless defined?(EngineTest)
  harness_path = File.join(File.dirname(__FILE__), 'harness.rb')
  eval(File.read(harness_path), TOPLEVEL_BINDING, harness_path) # rubocop:disable Security/Eval
end

EngineTest.suite('full-screen-resizer', 3)

EngineTest.load_preloads(%w[windows_fs platform_compat pokemon_compat win32_wrap])

# The Essentials code keeps its own style, so that it stays the same
# as what the games run.
# rubocop:disable all
class Win32API
  @@RGSSWINDOW=nil
  @@GetCurrentThreadId=Win32API.new('kernel32','GetCurrentThreadId', '%w()','l')
  @@GetWindowThreadProcessId=Win32API.new('user32','GetWindowThreadProcessId', '%w(l p)','l')
  @@FindWindowEx=Win32API.new('user32','FindWindowEx', '%w(l l p p)','l')

  def Win32API.pbFindRgssWindow
    return @@RGSSWINDOW if @@RGSSWINDOW
    processid=[0].pack('l')
    threadid=@@GetCurrentThreadId.call
    nextwindow=0
    begin
      nextwindow=@@FindWindowEx.call(0,nextwindow,"RGSS Player",0)
      if nextwindow!=0
        wndthreadid=@@GetWindowThreadProcessId.call(nextwindow,processid)
        if wndthreadid==threadid
          @@RGSSWINDOW=nextwindow
          return @@RGSSWINDOW
        end
      end
    end until nextwindow==0
    raise "Can't find RGSS player window"
  end

  def Win32API.focusWindow
    window = Win32API.new('user32', 'ShowWindow', 'LL' ,'L')
    hWnd = pbFindRgssWindow
    window.call(hWnd, 9)
  end

  def Win32API.fillScreen
    setWindowLong = Win32API.new('user32', 'SetWindowLong', 'LLL', 'L')
    setWindowPos = Win32API.new('user32', 'SetWindowPos', 'LLIIIII', 'I')
    metrics = Win32API.new('user32', 'GetSystemMetrics', 'I', 'I')
    hWnd =  pbFindRgssWindow
    width = metrics.call(0)
    height = metrics.call(1)
    setWindowLong.call(hWnd, -16, 0x00000000)
    setWindowPos.call(hWnd, 0, 0, 0, width, height, 0)
    Win32API.focusWindow
    return [width,height]
  end
end

# pbConfigureFullScreen, with the game size and the border as
# arguments, and Sprite#x= of a sprite with no viewport. It returns
# the factor and offsets that the game gives to pbSetResizeFactor2.
def essentials_full_screen(gamew, gameh, border)
  params = Win32API.fillScreen
  fullgamew = gamew + 80 * 2 * border
  fullgameh = gameh + 80 * 2 * border
  factor_x = ((2*params[0])/fullgamew).floor
  factor_y = ((2*params[1])/fullgameh).floor
  factor = [factor_x,factor_y].min/2.0
  offset_x = (params[0]-gamew*factor)/(2*factor)
  offset_y = (params[1]-gameh*factor)/(2*factor)
  EngineTest.owning(Viewport.new(0, 0, gamew, gameh)) do |o|
    o.rect.x = o.rect.x+offset_x
    o.rect.y = o.rect.y+offset_y
  end
  resize_factor_mul = (factor*100).to_i
  EngineTest.owning(Sprite.new) do |sprite|
    sprite.x = ((10+offset_x)*resize_factor_mul/100).to_i
  end
  [factor, offset_x, offset_y]
end
# rubocop:enable all

EngineTest.test('GetSystemMetrics gives a screen the size of the game') do
  EngineTest.assert_equal([Graphics.width, Graphics.height], Win32API.fillScreen, 'Win32API.fillScreen')
end

EngineTest.test('full screen keeps the game size with no border') do
  EngineTest.assert_equal([1.0, 0.0, 0.0], essentials_full_screen(Graphics.width, Graphics.height, 0),
                          'factor and offsets')
end

EngineTest.test('full screen with the border has a factor above 0') do
  factor, = essentials_full_screen(Graphics.width, Graphics.height, 1)
  EngineTest.assert(factor > 0, "factor #{factor}")
end

EngineTest.finish
exit
