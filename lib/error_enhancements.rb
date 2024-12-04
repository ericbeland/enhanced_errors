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
                             bindings_of_interest = []
                             if defined?(@binding_infos) && @binding_infos && !@binding_infos.empty?
                               bindings_of_interest = select_binding_infos(@binding_infos)
                             end
                             EnhancedErrors.format(bindings_of_interest)
                           rescue => e
                             # Avoid using puts; consider logging instead
                             # Avoid raising exceptions in rescue blocks
                             ""
                           end
  end

  private

  def select_binding_infos(binding_infos)
    # Preference:
    # Grab the first raise binding that isn't a library (gem) binding.
    # If there are only library bindings, grab the first one.
    # Grab the last rescue binding if we have one

    bindings_of_interest = []

    binding_infos.each do |info|
      if info[:capture_event] == 'raise' && !info[:library]
        bindings_of_interest << info
        break
      end
    end

    if bindings_of_interest.empty?
      bindings_of_interest << binding_infos.first if binding_infos.first
    end

    # Find the last rescue binding if there is one
    binding_infos.reverse.each do |info|
      if info[:capture_event] == 'rescue'
        bindings_of_interest << info
        break
      end
    end
    bindings_of_interest
  end
end
