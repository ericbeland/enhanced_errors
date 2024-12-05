# error_enhancements.rb

module ErrorEnhancements
  def message
    original_message = begin
                         super()
                       rescue
                         ''
                       end
    vars_message = variables_message rescue ""
    if original_message.include?(vars_message)
      original_message
    else
      "#{original_message}\n#{vars_message}"
    end
  rescue => e
    original_message || ''
  end

  def variables_message
    @variables_message ||= begin
                             if @binding_infos&.any?
                               bindings_of_interest = select_binding_infos(@binding_infos)
                               EnhancedErrors.format(bindings_of_interest)
                             else
                               ''
                             end
                           rescue
                             ''
                           end
  end

  private

    def select_binding_infos(binding_infos)
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

      bindings_of_interest
    end
end
