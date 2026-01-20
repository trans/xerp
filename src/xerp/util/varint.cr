module Xerp::Util
  # Encodes a UInt64 as a variable-length integer (LEB128 unsigned).
  def self.encode_u64(io : IO, value : UInt64) : Nil
    loop do
      byte = (value & 0x7F).to_u8
      value >>= 7
      if value != 0
        byte |= 0x80
      end
      io.write_byte(byte)
      break if value == 0
    end
  end

  # Decodes a variable-length integer (LEB128 unsigned) from IO.
  def self.decode_u64(io : IO) : UInt64
    result = 0_u64
    shift = 0
    loop do
      byte = io.read_byte
      raise IO::EOFError.new if byte.nil?
      result |= ((byte & 0x7F).to_u64 << shift)
      break if (byte & 0x80) == 0
      shift += 7
      raise ArgumentError.new("varint overflow") if shift >= 64
    end
    result
  end

  # Encodes an array of line numbers as delta-encoded varints.
  # Lines must be sorted in ascending order.
  def self.encode_delta_u32_list(lines : Array(Int32)) : Bytes
    return Bytes.empty if lines.empty?

    io = IO::Memory.new
    prev = 0_i32
    lines.each do |line|
      delta = line - prev
      encode_u64(io, delta.to_u64)
      prev = line
    end
    io.to_slice
  end

  # Decodes a delta-encoded varint blob back to an array of line numbers.
  def self.decode_delta_u32_list(blob : Bytes) : Array(Int32)
    return [] of Int32 if blob.empty?

    io = IO::Memory.new(blob)
    result = [] of Int32
    current = 0_i32
    while io.pos < io.size
      delta = decode_u64(io).to_i32
      current += delta
      result << current
    end
    result
  end

  # Encodes an array of UInt32 values as varints (no delta encoding).
  def self.encode_u32_list(values : Array(Int32)) : Bytes
    return Bytes.empty if values.empty?

    io = IO::Memory.new
    values.each do |val|
      encode_u64(io, val.to_u64)
    end
    io.to_slice
  end

  # Decodes a varint blob to an array of Int32 values (no delta encoding).
  def self.decode_u32_list(blob : Bytes) : Array(Int32)
    return [] of Int32 if blob.empty?

    io = IO::Memory.new(blob)
    result = [] of Int32
    while io.pos < io.size
      result << decode_u64(io).to_i32
    end
    result
  end
end
