# exception.rb
require_relative 'exception_context'

module Enhanced
  module ExceptionBindingInfos
    def binding_infos
      ctx = Enhanced::ExceptionContext.context_for(self)
      unless ctx
        ctx = Context.new
        Enhanced::ExceptionContext.store_context(self, ctx)
      end
      ctx.binding_infos
    end

    def captured_variables
      return '' unless binding_infos&.any?
      bindings_of_interest = select_binding_infos
      EnhancedErrors.format(bindings_of_interest)
    rescue
      ''
    end

    private

    def select_binding_infos
      # Preference:
      # 1. First 'raise' binding that isn't from a library (gem).
      # 2. If none, the first binding.
      # 3. The last 'rescue' binding if available.

      bindings_of_interest = []

      first_app_raise = binding_infos.find do |info|
        info[:capture_event] == 'raise' && !info[:library]
      end
      bindings_of_interest << first_app_raise if first_app_raise

      if bindings_of_interest.empty? && binding_infos.first
        bindings_of_interest << binding_infos.first
      end

      last_rescue = binding_infos.reverse.find do |info|
        info[:capture_event] == 'rescue'
      end
      bindings_of_interest << last_rescue if last_rescue

      bindings_of_interest.compact
    end
  end
end

class Exception
  prepend Enhanced::ExceptionBindingInfos
end
