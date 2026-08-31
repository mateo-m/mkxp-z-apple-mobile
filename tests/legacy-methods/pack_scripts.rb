# Packs the harness and the suite into Data/Scripts.rxdata.
#
# The engine turns the syntax transform on for the sections of
# Scripts.rxdata alone, so this suite cannot boot from the
# "customScript" key that tests/engine uses.
#
#   ruby tests/legacy-methods/pack_scripts.rb
#   tools/run-engine-tests.sh --game tests/legacy-methods

require 'zlib'

HERE = File.dirname(File.expand_path(__FILE__))

SOURCES = [
  [1, 'harness', File.join(HERE, '..', 'engine', 'harness.rb')],
  [2, 'legacy_methods', File.join(HERE, 'legacy_methods.rb')]
].freeze

sections = SOURCES.map do |id, name, path|
  [id, name, Zlib::Deflate.deflate(File.binread(path))]
end

Dir.mkdir(File.join(HERE, 'Data')) unless File.directory?(File.join(HERE, 'Data'))
target = File.join(HERE, 'Data', 'Scripts.rxdata')
File.binwrite(target, Marshal.dump(sections))
puts "pack_scripts: wrote #{target}"
