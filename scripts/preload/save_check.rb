# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# Reads each new save before it replaces the old one (MKXPSafeWrite in
# windows_fs.rb), and tells the host when the game loads a save.
#
# The reader walks the Marshal bytes. It makes no objects and runs no
# game code. A save fails the check only for a fault that a correct
# save cannot have, because a refused good save loses the player's
# progress too.
module MKXPSaveCheck
  class Malformed < StandardError; end

  # Ruby loads a 'u' value with _load of its class. These engine classes
  # always give an object of their own class.
  ENGINE_DUMP_CLASSES = %w[Color Tone Rect Table].freeze
  # Each byte becomes one Integer of an Array.
  LARGEST_FILE = 8 * 1024 * 1024

  module_function

  # A game that moves in the file can write over a dump.
  module MovesInFile
    def seek(*args)
      @mkxp_save_watch[:moved] = true
      super
    end

    def pos=(*args)
      @mkxp_save_watch[:moved] = true
      super
    end

    def rewind(*args)
      @mkxp_save_watch[:moved] = true
      super
    end

    def sysseek(*args)
      @mkxp_save_watch[:moved] = true
      super
    end

    def truncate(*args)
      @mkxp_save_watch[:moved] = true
      super
    end

    def reopen(*args)
      @mkxp_save_watch[:moved] = true
      super
    end
  end

  # The temp file of a safe write. Marshal.dump records the bytes that
  # it writes to the file.
  def watch(file)
    watch = { :ranges => [], :moved => false }
    file.instance_variable_set(:@mkxp_save_watch, watch)
    file.extend(MovesInFile)
    watch
  end

  def watch_of(io)
    IO === io ? io.instance_variable_get(:@mkxp_save_watch) : nil
  end

  # Returns why the file must not replace the save, or nil.
  def problem(path, watch)
    data = read(path)
    return nil unless data

    reader = Reader.new(data)
    ranges = watch && !watch[:moved] ? watch[:ranges] : []
    ranges.empty? ? reader.problem_in_dumps : reader.problem_in_ranges(ranges)
  rescue StandardError, SystemStackError, NoMemoryError
    nil
  end

  def read(path)
    return nil if File.size(path) > LARGEST_FILE

    data = File._mkxp_orig_open(path, 'rb', &:read)
    bytes = data ? data.unpack('C*') : []
    bytes[0] == 4 && bytes[1] == 8 ? bytes : nil
  end

  # The refused file stays next to the save, until the next refused
  # save of the same name replaces it.
  def reject(temp, target, problem)
    File._mkxp_orig_rename(temp, MKXPSafeWrite.temp_path(target, 'rejected'))
    report(:report_save_rejected, "#{File.basename(target)}: #{problem}")
  end

  def report(name, detail)
    System.send(name, detail) if defined?(System) && System.respond_to?(name)
  end

  def save_source?(source)
    return false unless source.is_a?(File)

    path = File.expand_path(source.path).downcase
    root = defined?(MKXPSaveFS) && MKXPSaveFS.game_root_prefix
    !(root && path.start_with?("#{root.downcase}data/"))
  rescue StandardError
    false
  end

  # A game reads a save with one Marshal.load for each part. The host
  # gets one report for each open file.
  def loading(source)
    return if source.instance_variable_get(:@mkxp_save_load_noted)

    source.instance_variable_set(:@mkxp_save_load_noted, true)
    report(:report_save_load, File.basename(source.path))
  end

  # Saves from before #81 hold sound names that the old sweep broke. The
  # getter in audio_file_name_repair.rb repairs a name only when the game
  # reads it. A repair at load keeps the broken names out of the next
  # save, so the check does not refuse each later save of the game.
  def repair_proc(game_proc)
    audio = audio_file_class
    return game_proc unless audio

    proc do |obj|
      if audio === obj # rubocop:disable Style/CaseEquality -- a BasicObject has no is_a?.
        name = obj.instance_variable_get(:@name)
        obj.instance_variable_set(:@name, '') unless name.nil? || name.is_a?(String)
      end
      game_proc ? game_proc.call(obj) : obj
    end
  end

  def audio_file_class
    RPG::AudioFile if defined?(RPG::AudioFile) && RPG::AudioFile.is_a?(Class)
  end

  # The type of a value is nil, :string, :unknown, or the name of a
  # type that is not a String.
  class Reader
    def initialize(bytes)
      @bytes = bytes
      @audio = MKXPSaveCheck.audio_file_class
      @classes = {}
    end

    # The bytes of each Marshal.dump call must read back as one dump.
    def problem_in_ranges(ranges)
      ranges.each do |start, finish|
        return "bytes #{start} to #{finish} do not read back as a dump" unless reads_to?(start, finish)
        return @problem if @problem
      end
      nil
    end

    # A file that is not only dumps can fail to read. Only a fault in a
    # dump that reads back is certain.
    def problem_in_dumps
      @pos = 0
      while @pos < @bytes.size
        found = dump(@pos, @bytes.size)
        return found if found
      end
      nil
    rescue Malformed
      nil
    end

    private

    def reads_to?(start, finish)
      dump(start, finish)
      @pos == finish
    rescue Malformed
      false
    end

    # The tasks are a stack, not a recursion, because a deep save must
    # not overflow the stack of the game thread.
    def dump(start, finish)
      @pos = start
      @end = [finish, @bytes.size].min
      raise Malformed unless byte == 4 && byte == 8

      @objects = []
      @symbols = []
      @types = []
      @problem = nil
      @tasks = [[:value, false, nil]]
      step until @tasks.empty?
      @problem
    end

    def byte
      raise Malformed if @pos >= @end

      @pos += 1
      @bytes[@pos - 1]
    end

    def long
      c = byte
      c -= 256 if c > 127
      return 0 if c.zero?
      return c - 5 if c > 4
      return c + 5 if c < -4

      count = c.abs
      raise Malformed if count > 8

      value = 0
      count.times { |i| value |= byte << (8 * i) }
      c > 0 ? value : value - (1 << (8 * count))
    end

    # Each value takes one byte or more.
    def count
      found = long
      raise Malformed if found < 0 || found > @end - @pos

      found
    end

    def skip(size)
      raise Malformed if size < 0 || size > @end - @pos

      @pos += size
    end

    def text
      size = long
      skip(size)
      @bytes[@pos - size, size].pack('C*')
    end

    # A link to the object table or to the symbol table.
    def at(list)
      index = long
      raise Malformed unless index >= 0 && index < list.size

      list[index]
    end

    def symbol
      case byte.chr
      when ':' then new_symbol(false)
      when ';' then at(@symbols)
      when 'I' then byte.chr == ':' ? new_symbol(true) : raise(Malformed)
      else raise Malformed
      end
    end

    # The encoding of a symbol is true, false or a String.
    def new_symbol(ivars)
      name = text
      @symbols << name
      return name unless ivars

      count.times do
        symbol
        case byte.chr
        when 'T', 'F' then nil
        when '"'
          skip(long)
          @objects << :string
        else
          raise Malformed
        end
      end
      name
    end

    def step
      task = @tasks.pop
      case task[0]
      when :value
        value(task[1], task[2])
      when :pairs
        pair(task[1], task[2])
      when :ivars
        later([:pairs, count, nil]) unless task[1] && task[1][0]
      when :register
        @objects << task[1]
        @types << task[1] if task[2]
      when :name
        type = @types.pop
        @problem ||= "the @name of an #{task[1]} is a #{type}" if type.is_a?(String)
      end
    end

    # The first task given runs first.
    def later(*tasks)
      @tasks.concat(tasks.reverse)
    end

    def values(size)
      size.times { @tasks << [:value, false, nil] }
    end

    # An ivar or a Struct member: a symbol, then a value.
    def pair(left, audio)
      return if left.zero?

      name = symbol
      if audio && name == '@name'
        later([:value, true, nil], [:name, audio], [:pairs, left - 1, audio])
      else
        later([:value, false, nil], [:pairs, left - 1, audio])
      end
    end

    # want: the type goes on @types when the value ends.
    # held: the ivars of an 'I' around the value, that a 'u' reads.
    def value(want, held)
      type = value_type(want, held)
      @types << type if want && type != :later
    end

    # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength -- one branch for each type byte
    def value_type(want, held)
      case byte.chr
      when '0' then nil
      when 'T' then 'true'
      when 'F' then 'false'
      when 'i'
        long
        'Integer'
      when ':', ';'
        @pos -= 1
        symbol
        'Symbol'
      when 'I' then ivar_value(want)
      when '"' then entry(:string, long)
      when 'f' then entry('Float', long)
      when 'l' then bignum
      when '/' then entry('Regexp', long + 1)
      when 'c', 'm', 'M' then entry('Module', long)
      when '@' then at(@objects)
      when '[' then container('Array', count, false)
      when '{' then container('Hash', count * 2, false)
      when '}' then container('Hash', count * 2, true)
      when 'S' then struct
      when 'o' then object
      when 'U', 'd' then allocated
      when 'u' then user_dump(want, held)
      when 'e'
        symbol
        later([:value, want, held])
        :later
      when 'C'
        symbol
        later([:value, want, nil])
        :later
      else
        raise Malformed
      end
    end
    # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength

    def entry(type, size)
      skip(size)
      @objects << type
      type
    end

    # A sign byte, then the size in 16-bit words.
    def bignum
      byte
      entry('Integer', long * 2)
    end

    # Ruby reads the encoding of a symbol with the symbol.
    def ivar_value(want)
      return new_symbol(true) && 'Symbol' if byte.chr == ':'

      @pos -= 1
      held = [false]
      later([:value, want, held], [:ivars, held])
      :later
    end

    def container(type, size, default)
      raise Malformed if size > @end - @pos

      @objects << type
      later([:value, false, nil]) if default
      values(size)
      type
    end

    def struct
      type = entry(class_type(symbol), 0)
      later([:pairs, count, nil])
      type
    end

    def object
      name = symbol
      klass = resolve(name)
      type = class_type(name)
      @objects << type
      audio = @audio && klass.is_a?(Class) && klass <= @audio ? name : nil
      later([:pairs, count, audio])
      type
    end

    def allocated
      type = entry(class_type(symbol), 0)
      values(1)
      type
    end

    # Ruby adds a 'u' value to the table after its data and its ivars.
    def user_dump(want, held)
      name = symbol
      skip(long)
      klass = resolve(name)
      type = ENGINE_DUMP_CLASSES.include?(name) && klass.is_a?(Class) ? name : :unknown
      return entry(type, 0) unless held

      held[0] = true
      later([:pairs, count, nil], [:register, type, want])
      :later
    end

    def class_type(name)
      klass = resolve(name)
      klass.is_a?(Class) && !(klass <= String) ? name : :unknown
    end

    # const_get can call a const_missing hook of the game. const_defined?
    # first stops that.
    def resolve(name)
      return @classes[name] if @classes.key?(name)

      found = Object
      name.split('::').each do |part|
        unless found.is_a?(Module) && part =~ /\A[A-Z]\w*\z/ && found.const_defined?(part)
          found = nil
          break
        end
        found = found.const_get(part)
      end
      @classes[name] = found.is_a?(Module) ? found : nil
    rescue StandardError
      @classes[name] = nil
    end
  end
end

class << Marshal
  alias _mkxp_check_dump dump unless method_defined?(:_mkxp_check_dump)
  alias _mkxp_check_load load unless method_defined?(:_mkxp_check_load)

  def dump(obj, *args)
    watch = MKXPSaveCheck.watch_of(args[0])
    return _mkxp_check_dump(obj, *args) unless watch

    start = args[0].pos
    result = _mkxp_check_dump(obj, *args)
    watch[:ranges] << [start, args[0].pos]
    result
  end

  def load(source, *args)
    return _mkxp_check_load(source, *args) unless MKXPSaveCheck.save_source?(source)

    MKXPSaveCheck.loading(source)
    repair = MKXPSaveCheck.repair_proc(args[0])
    args[0] = repair if repair
    _mkxp_check_load(source, *args)
  end
end
