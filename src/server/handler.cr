module HTTP2
  class Server
    module Handler
      # :nodoc:
      property next : Handler?

      # Call method to be implemented by each `Handler`. May eventually pass
      # execution to next handler with `#call_next`.
      abstract def call(context : Context)

      # Pass execution to *next* handler (if any).
      def call_next(context : Context)
        if handler = @next
          handler.call(context)
        end
      end
    end
  end
end
