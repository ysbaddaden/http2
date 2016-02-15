module HTTP2
  module HPACK
    class DynamicTable
      getter bytesize : Int32
      getter maximum : Int32

      def initialize(@maximum)
        @bytesize = 0
        @table = [] of Tuple(String, String)
      end

      def add(name, value)
        header = {name, value}
        @table.unshift(header)
        @bytesize += count(header)
        cleanup
        nil
      end

      def [](index)
        @table[index]
      end

      def []?(index)
        @table[index]?
      end

      def each
        @table.each { |header, index| yield header, index }
      end

      def each_with_index
        @table.each_with_index { |header, index| yield header, index }
      end

      def size
        @table.size
      end

      def empty?
        @table.empty?
      end

      def resize(@maximum)
        cleanup
        nil
      end

      private def cleanup
        while bytesize > maximum
          @bytesize -= count(@table.pop)
        end
      end

      private def count(header)
        header[0].bytesize + header[1].bytesize + 32
      end
    end
  end
end
