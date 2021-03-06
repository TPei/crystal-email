abstract class EMail::Header
  # :nodoc:
  FIELD_NAME = /\A[\x{21}-\x{39}\x{3b}-\x{7e}]+\z/
  # :nodoc:
  FIELD_BODY = /\A[\x{1}-\x{9}\x{b}\x{c}\x{e}-\x{1f}\x{20}-\x{7f}]+\z/

  # :nodoc:
  NON_VCHAR = /[^\x{9}\x{20}-\x{7e}]/
  # :nodoc:
  LINE_LENGTH = 78
  # :nodoc:
  ENCODE_DEFINITION_SIZE = 13
  # :nodoc:
  ENCODE_DEFINITION_HEAD = " =?UTF-8?B?"
  # :nodoc:
  ENCODE_DEFINITION_TAIL = "?="

  def self.base64_encode(src_string : String, offset : Int32) : Tuple(String, Int32)
    encoded_lines = [] of String
    encoded_line = ""
    src_chars = Char::Reader.new(src_string)
    until src_chars.current_char == '\u{0}'
      encoded_size = ((encoded_line.bytesize + src_chars.current_char_width).to_f / 6 * 8).ceil
      if offset + ENCODE_DEFINITION_SIZE + encoded_size > LINE_LENGTH
        if encoded_line.empty?
          encoded_lines << ""
        else
          encoded_lines << ENCODE_DEFINITION_HEAD + Base64.strict_encode(encoded_line.to_slice) + ENCODE_DEFINITION_TAIL
        end
        encoded_line = ""
        offset = 0
      end
      encoded_line += src_chars.current_char
      src_chars.next_char
    end
    encoded_lines << ENCODE_DEFINITION_HEAD + Base64.strict_encode(encoded_line.to_slice) + ENCODE_DEFINITION_TAIL unless encoded_line.empty?
    if last_line = encoded_lines.last?
      offset = last_line.size
    end
    {encoded_lines.join("\n"), offset}
  end

  getter name

  @name : String

  def initialize(field_name : String)
    raise Error::HeaderError.new("#{field_name.inspect} is invalid as a header field name.") unless field_name =~ FIELD_NAME
    @name = field_name.split("-").map(&.capitalize).join("-")
  end

  private def body
    ""
  end

  def empty?
    body.empty?
  end

  def to_s(io : IO)
    header_body = body
    raise Error::HeaderError.new("Header #{@name} includes invalid line break(s).") if header_body =~ /\n[^\x{9}\x{20}]/
    io << @name << ":"
    splited_body = header_body.split(/\s+/)
    offset = @name.size + 1
    while (body_part = splited_body.shift?)
      if body_part =~ FIELD_BODY
        unless offset + body_part.size < LINE_LENGTH
          io << '\n'
          offset = 0
        end
        io << ' ' << body_part
        offset += body_part.size + 1
      else
        encoded_part, offset = Header.base64_encode(body_part, offset)
        io << encoded_part
      end
    end
  end

  class AddressList < Header
    getter list

    @list = [] of Address

    private def body
      @list.join(", ")
    end

    def empty?
      @list.empty?
    end

    def size
      @list.size
    end

    def add(mail_address : String, sender_name : String? = nil)
      @list << Address.new(mail_address, sender_name)
    end

    def add(mail_address : Address)
      @list << mail_address
    end
  end

  class SingleAddress < Header
    @addr : Address? = nil

    private def body
      addr.to_s
    end

    def empty?
      @addr.nil?
    end

    def addr
      @addr.not_nil!
    end

    def set(mail_address : String, sender_name : String? = nil)
      @addr = Address.new(mail_address, sender_name)
    end

    def set(mail_address : Address)
      @addr = mail_address
    end
  end

  class Date < Header
    RFC2822_FORMAT = "%a, %d %b %Y %T %z"

    @timestamp : Time? = nil

    def initialize
      super("Date")
    end

    def time=(time : Time)
      @timestamp = time
    end

    def empty?
      @timestamp.nil?
    end

    private def body
      @timestamp.not_nil!.to_s(RFC2822_FORMAT)
    end
  end

  class Unstructured < Header
    @text : String = ""

    private def body
      @text
    end

    def set(body_text : String)
      @text = body_text
    end
  end

  class MimeVersion < Header
    def initialize(@version : String = "1.0")
      super("Mime-Version")
    end

    private def body
      @version
    end
  end

  class ContentType < Header
    @mime_type : String
    @options : Hash(String, String)

    def initialize(@mime_type : String, @options = Hash(String, String).new)
      super("Content-Type")
    end

    def set_option(name : String, value : String)
      @options[name] = value
    end

    def set_mime_type(mime_type : String)
      @mime_type = mime_type
    end

    def set_charset(charset : String)
      @options["charset"] = charset
    end

    def set_fname(file_name : String)
      @options["file_name"] = file_name
    end

    def set_boundary(boundary : String)
      @options["boundary"] = boundary
    end

    private def body
      String.build do |body_text|
        body_text << @mime_type << ';'
        if charset = @options["charset"]?
          body_text << " charset=" << charset << ';'
        end
        if fname = @options["file_name"]?
          body_text << " name=\""
          encoded_fname, _ = Header.base64_encode(fname, 6)
          body_text << encoded_fname.strip.gsub(/\n +/, ' ') << "\";"
        end
        if boundary = @options["boundary"]?
          body_text << " boundary=\"" << boundary << "\";"
        end
      end
    end
  end

  class ContentTransferEncoding < Header
    def initialize(@encoding : String)
      super("Content-Transfer-Encoding")
    end

    def set(encoding : String)
      @encoding = encoding
    end

    private def body
      @encoding
    end
  end

  class ContentDisposition < Header
    @file_name : String

    def initialize(@file_name : String)
      super("Content-Disposition")
    end

    private def body
      String.build do |body_text|
        body_text << "attachment; " << encoded_fname(@file_name)
      end
    end

    private def encoded_fname(file_name : String)
      encoded_lines = [] of String
      fname_chars = Char::Reader.new(file_name)
      encoded_line = " filename*#{encoded_lines.size}*=UTF-8''"
      until fname_chars.current_char == '\u{0}'
        fname_char = URI.escape(fname_chars.current_char.to_s)
        line_size = encoded_line.size + fname_chars.current_char_width * 3
        unless line_size < LINE_LENGTH
          encoded_lines << encoded_line + ";"
          encoded_line = " filename*#{encoded_lines.size}*="
        end
        encoded_line += fname_char
        fname_chars.next_char
      end
      encoded_lines << encoded_line + ";" unless encoded_line =~ /\=\z/
      encoded_lines.join
    end
  end

  class ContentID < SingleAddress
    def initialize
      super("Content-Id")
    end
  end
end
