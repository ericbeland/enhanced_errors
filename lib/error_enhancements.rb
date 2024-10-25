module ErrorEnhancements
  def message
    original_message = super()
    "#{original_message}\n#{variables_message}"
  rescue => e
    puts "Error in message method: #{e.message}"
    original_message
  end

  def variables_message
    @variables_message ||= begin
                             bindings_of_interest = []
                             if defined?(@binding_infos) && @binding_infos && !@binding_infos.empty?
                               bindings_of_interest = select_binding_infos(@binding_infos)
                             end
                             EnhancedErrors.format(bindings_of_interest)
                           rescue => e
                             puts "Error in variables_message: #{e.message}"
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

    # find the last rescue binding if there is one
    binding_infos.reverse.each do |info|
      if info[:capture_event] == 'rescue'
        bindings_of_interest << info
        break
      end
    end
    bindings_of_interest
  end

end
