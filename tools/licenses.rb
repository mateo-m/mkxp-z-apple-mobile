#!/usr/bin/env ruby
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# Writes licenses.json, the license notices of the code in the package,
# from licenses/manifest.json. A host shows them on its licenses screen.
#
#   ruby tools/licenses.rb write [--root DIR] OUT
#   ruby tools/licenses.rb check ARCHIVE...
#
# write reads each file of each entry, and fails when one is missing.
# A path under licenses/ is a file of this repo. Any other path is in the
# source tree, which --root can take from another checkout.
#
# A file can also be a part of a source file: the lines from the first
# line with "from" up to the next line with "to". write removes the
# comment marks and the indent of these lines.
#
# check fails when an archive of the package matches no "archives"
# pattern of an entry, or a pattern matches no archive.

require 'json'

REPO = File.expand_path('..', __dir__)

def fail_with(message)
  abort "licenses: #{message}"
end

def manifest
  JSON.parse(File.read(File.join(REPO, 'licenses/manifest.json')))
end

def read_text(path)
  text = File.binread(path).force_encoding(Encoding::UTF_8)
  text = text.force_encoding(Encoding::ISO_8859_1).encode(Encoding::UTF_8) unless text.valid_encoding?
  text.delete("\r")
end

def excerpt(lines, part, path)
  first = lines.index { |line| line.include?(part['from']) }
  fail_with "#{path} has no line with #{part['from'].inspect}" unless first
  count = lines[(first + 1)..].index { |line| line.include?(part['to']) }
  fail_with "#{path} has no line with #{part['to'].inspect} after #{part['from'].inspect}" unless count
  lines = lines[first, count + 1].map { |line| line.sub(%r{\A\s*(\*|//)(?= |\z) ?}, '') }
  indent = lines.reject { |line| line.strip.empty? }.map { |line| line[/\A[ \t]*/].size }.min || 0
  lines.map { |line| line[indent..] || '' }
end

def read_part(part, root)
  part = { 'path' => part } if part.is_a?(String)
  base = part['path'].start_with?('licenses/') ? REPO : root
  path = File.join(base, part['path'])
  fail_with "#{path} is missing" unless File.file?(path)
  lines = read_text(path).lines.map(&:chomp)
  lines = excerpt(lines, part, path) if part['from']
  lines.map(&:rstrip).join("\n").strip
end

def write(args)
  root = REPO
  if args.first == '--root'
    args.shift
    root = File.expand_path(args.shift)
  end
  out = args.shift
  fail_with 'usage: licenses.rb write [--root DIR] OUT' unless out && args.empty?
  entries = manifest.map do |entry|
    parts = entry['files'].map { |part| read_part(part, root) }.uniq
    { 'name' => entry['name'], 'license' => entry['license'], 'text' => parts.join("\n\n") }
  end
  File.write(out, "#{JSON.pretty_generate(entries)}\n")
  puts "licenses: #{out}, #{entries.size} entries"
end

def check(args)
  shipped = args.map { |arg| File.basename(arg) }
  patterns = manifest.flat_map { |entry| entry['archives'] || [] }.uniq
  missing = shipped.reject { |archive| patterns.any? { |pattern| File.fnmatch(pattern, archive) } }
  unused = patterns.reject { |pattern| shipped.any? { |archive| File.fnmatch(pattern, archive) } }
  missing.each { |archive| warn "licenses: no entry in licenses/manifest.json names #{archive}" }
  unused.each do |pattern|
    warn "licenses: licenses/manifest.json names #{pattern}, which the package does not ship"
  end
  exit 1 unless missing.empty? && unused.empty?
end

case ARGV.shift
when 'write' then write(ARGV)
when 'check' then check(ARGV)
else fail_with 'usage: licenses.rb write [--root DIR] OUT | check ARCHIVE...'
end
