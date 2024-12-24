require 'weakref'

require_relative 'context'

require 'weakref'
require 'monitor'

module Enhanced
  module ExceptionContext
    extend self

    REGISTRY = {}
    MUTEX = Monitor.new

    def store_context(exception, context)
      MUTEX.synchronize do
        REGISTRY[exception.object_id] = { weak_exc: WeakRef.new(exception), context: context }
      end
    end

    def context_for(exception)
      MUTEX.synchronize do
        entry = REGISTRY[exception.object_id]
        return nil unless entry

        begin
          _ = entry[:weak_exc].__getobj__ # ensure exception is still alive
          entry[:context]
        rescue RefError
          # Exception no longer alive, clean up
          REGISTRY.delete(exception.object_id)
          nil
        end
      end
    end

    def clear_context(exception)
      MUTEX.synchronize do
        REGISTRY.delete(exception.object_id)
      end
    end

    def clear_all
      MUTEX.synchronize do
        REGISTRY.clear
      end
    end
  end
end
