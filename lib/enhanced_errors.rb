# enhanced_errors.rb

require 'set'
require 'json'

require_relative 'enhanced/integrations/rspec_error_failure_message'
require_relative 'enhanced/colors'

IGNORED_EXCEPTIONS = %w[SystemExit NoMemoryError SignalException Interrupt
                        ScriptError LoadError NotImplementedError SyntaxError
                        RSpec::Expectations::ExpectationNotMetError
                        RSpec::Matchers::BuiltIn::RaiseError
                        SystemStackError Psych::BadAlias]


class EnhancedErrors
  extend ::Enhanced

  class << self
    attr_accessor :enabled, :config_block, :max_length, :on_capture_hook,
                  :eligible_for_capture, :trace, :skip_list, :capture_rescue,
                  :override_messages

    GEMS_REGEX = %r{[\/\\]gems[\/\\]}
    RSPEC_EXAMPLE_REGEXP = /RSpec::ExampleGroups::[A-Z0-9]+.*/
    DEFAULT_MAX_LENGTH = 2000

    # Maximum binding infos we will track per-exception instance. This is intended as an extra
    # safety rail, not a normal scenario.
    MAX_BINDING_INFOS = 3

    # Add @__memoized and @__inspect_output to the skip list so they don't appear in output
    RSPEC_SKIP_LIST = Set.new([
                                :@assertions,
                                :@integration_session,
                                :@example,
                                :@fixture_cache,
                                :@fixture_cache_key,
                                :@fixture_connections,
                                :@fixture_connection_pools,
                                :@loaded_fixtures,
                                :@connection_subscriber,
                                :@saved_pool_configs,
                                :@assertion_instance,
                                :@legacy_saved_pool_configs,
                                :@matcher_definitions,
                                :@__memoized,
                                :@__inspect_output
                              ]).freeze

    RAILS_SKIP_LIST = Set.new([
                                :@new_record,
                                :@attributes,
                                :@association_cache,
                                :@readonly,
                                :@previously_new_record,
                                :@routes, # usually just shows #<ActionDispatch::Routing::RouteSet:0x000000016087d708>
                                :@destroyed,
                                :@response, #usually big, gets truncated anyway
                                :@marked_for_destruction,
                                :@destroyed_by_association,
                                :@primary_key,
                                :@strict_loading,
                                :@assertion_instance,
                                :@strict_loading_mode,
                                :@mutations_before_last_save,
                                :@mutations_from_database,
                                :@relation_delegate_cache,
                                :@predicate_builder,
                                :@generated_relation_method,
                                :@find_by_statement_cache,
                                :@arel_table,
                                :@response_klass,
                              ]).freeze

    DEFAULT_SKIP_LIST = (RAILS_SKIP_LIST + RSPEC_SKIP_LIST).freeze

    @enabled = false

    def max_length(value = nil)
      if value.nil?
        @max_length ||= DEFAULT_MAX_LENGTH
      else
        @max_length = value
      end
      @max_length
    end

    def capture_rescue(value = nil)
      if value.nil?
        @capture_rescue = @capture_rescue.nil? ? false : @capture_rescue
      else
        @capture_rescue = value
      end
      @capture_rescue
    end

    def skip_list
      @skip_list ||= DEFAULT_SKIP_LIST.dup
    end

    # takes an exception and bindings, calculates the variables message
    # and modifies the exceptions .message to display the variables
    def override_exception_message(exception, binding_or_bindings)
      # Ensure binding_or_bindings is always an array for compatibility
      return exception if binding_or_bindings.nil? || binding_or_bindings.empty? || exception.respond_to?(:unaltered_message)
      variable_str = EnhancedErrors.format(binding_or_bindings)
      message_str = exception.message
      exception.define_singleton_method(:unaltered_message) { message_str }
      exception.define_singleton_method(:message) do
        "#{message_str}#{variable_str}"
      end
      exception
    end

    def add_to_skip_list(*vars)
      skip_list.merge(vars)
    end

    def enhance_exceptions!(enabled: true, debug: false, capture_events: nil, override_messages: false, **options, &block)
      require_relative 'enhanced/exception'

      @output_format = nil
      @eligible_for_capture = nil
      @original_global_variables = nil
      @override_messages = override_messages

      if enabled == false
        @original_global_variables = nil
        @enabled = false
        @trace&.disable
      else
        # if there's an old one, disable it before replacing it
        # this seems to actually matter, although it seems like it
        # shouldn't
        @trace&.disable
        @trace = nil

        @enabled = true
        @debug = debug
        @original_global_variables = global_variables if @debug

        options.each do |key, value|
          setter_method = "#{key}="
          if respond_to?(setter_method)
            send(setter_method, value)
          elsif respond_to?(key)
            send(key, value)
          else
            # Ignore unknown options
          end
        end

        @config_block = block_given? ? block : nil
        instance_eval(&@config_block) if @config_block

        validate_and_set_capture_events(capture_events)

        events = @capture_events ? @capture_events.to_a : default_capture_events
        @trace = TracePoint.new(*events) do |tp|
          handle_tracepoint_event(tp)
        end

        @trace.enable
      end
    end

    def safe_prepend_module(target_class, mod)
      if defined?(target_class) && target_class.is_a?(Module)
        target_class.prepend(mod)
        true
      else
        false
      end
    end

    def safely_prepend_rspec_custom_failure_message
      return if @rspec_failure_message_loaded
      if defined?(RSpec::Core::Example) && !RSpec::Core::Example < Enhanced::Integrations::RSpecErrorFailureMessage
        RSpec::Core::Example.prepend(Enhanced::Integrations::RSpecErrorFailureMessage)
        @rspec_failure_message_loaded = true
      end
    rescue => e
      puts "Failed to prepend RSpec custom failure message: #{e.message}"
    end


    def start_rspec_binding_capture
      @rspec_example_binding = nil

      # In the Exception binding infos, I observed that re-setting
      # the tracepoint without disabling it seemed to accumulate traces
      # in the test suite where things are disabled and re-enabled often.
      @rspec_tracepoint&.disable

      @rspec_tracepoint = TracePoint.new(:b_return) do |tp|
        # This is super-kluge-y and should be replaced with... something TBD

        # early easy checks to nope out of the object name and other checks
        if tp.method_id.nil? && !(tp.path =~ /rspec/) && tp.path =~ /_spec\.rb$/
         # fixes cases where class and name are screwed up or overridden
          if determine_object_name(tp) =~ RSPEC_EXAMPLE_REGEXP
            @rspec_example_binding = tp.binding
          end
        end

      end

      @rspec_tracepoint.enable
    end

    def stop_rspec_binding_capture
      @rspec_tracepoint&.disable
      binding_info = convert_binding_to_binding_info(@rspec_example_binding) if @rspec_example_binding
      @rspec_example_binding = nil
      binding_info
    end

    def convert_binding_to_binding_info(b, capture_let_variables: true)
      file = b.eval("__FILE__") rescue nil
      line = b.eval("__LINE__") rescue nil
      location = [file, line].compact.join(":")

      locals = b.local_variables.map { |var| [var, safe_local_variable_get(b, var)] }.to_h
      receiver = b.receiver
      instance_vars = receiver.instance_variables
      instances = instance_vars.map { |var| [var, safe_instance_variable_get(receiver, var)] }.to_h

      # Capture let variables only for RSpec captures
      lets = {}
      if capture_let_variables && instance_vars.include?(:@__memoized)
        outer_memoized = receiver.instance_variable_get(:@__memoized)
        memoized = outer_memoized.instance_variable_get(:@memoized) if outer_memoized.respond_to?(:instance_variable_get)
        if memoized.is_a?(Hash)
          lets = memoized.transform_keys(&:to_sym)
        end
      end

      binding_info = {
        source: location,
        object: receiver,
        library: !!GEMS_REGEX.match?(location.to_s),
        method_and_args: {
          object_name: '',
          args: ''
        },
        test_name: test_name,
        variables: {
          locals: locals,
          instances: instances,
          lets: lets,
          globals: {}
        },
        exception: 'NoException',
        capture_event: 'RSpecContext'
      }

      # Apply skip list to remove @__memoized and @__inspect_output from output
      # but only after extracting let variables.
      binding_info = default_on_capture(binding_info)
      binding_info
    end

    def eligible_for_capture(&block)
      if block_given?
        @eligible_for_capture = block
      else
        @eligible_for_capture ||= method(:default_eligible_for_capture)
      end
    end

    def on_capture(&block)
      if block_given?
        @on_capture_hook = block
      else
        @on_capture_hook ||= method(:default_on_capture)
      end
    end

    def on_capture=(value)
      self.on_capture_hook = value
    end

    def on_format(&block)
      if block_given?
        @on_format_hook = block
      else
        @on_format_hook ||= method(:default_on_format)
      end
    end

    def on_format=(value)
      @on_format_hook = value
    end

    def format(captured_binding_infos = [], output_format = get_default_format_for_environment)
      return '' if captured_binding_infos.nil? || captured_binding_infos.empty?

      # If captured_binding_infos is already an array, use it directly; otherwise, wrap it in an array.
      binding_infos = captured_binding_infos.is_a?(Array) ? captured_binding_infos : [captured_binding_infos]

      result = binding_infos_array_to_string(binding_infos, output_format)

      if @on_format_hook
        begin
          result = @on_format_hook.call(result)
        rescue
          result = ''
        end
      else
        result = default_on_format(result)
      end

      result
    end

    def binding_infos_array_to_string(captured_bindings, format = :terminal)
      return '' if captured_bindings.nil? || captured_bindings.empty?
      captured_bindings = [captured_bindings] unless captured_bindings.is_a?(Array)
      Colors.enabled = format == :terminal
      formatted_bindings = captured_bindings.to_a.map { |binding_info| binding_info_string(binding_info) }
      format == :json ? JSON.pretty_generate(captured_bindings) : "\n#{formatted_bindings.join("\n")}"
    end

    def get_default_format_for_environment
      return @output_format unless @output_format.nil?
      env = ENV['RAILS_ENV'] || ENV['RACK_ENV'] || 'development'
      @output_format = case env
                       when 'development', 'test'
                         if running_in_ci?
                           :plaintext
                         else
                           :terminal
                         end
                       when 'production'
                         :json
                       else
                         :terminal
                       end
    end

    def running_in_ci?
      return @running_in_ci if defined?(@running_in_ci)
      ci_env_vars = {
        'CI' => ENV['CI'],
        'JENKINS' => ENV['JENKINS'],
        'GITHUB_ACTIONS' => ENV['GITHUB_ACTIONS'],
        'CIRCLECI' => ENV['CIRCLECI'],
        'TRAVIS' => ENV['TRAVIS'],
        'APPVEYOR' => ENV['APPVEYOR'],
        'GITLAB_CI' => ENV['GITLAB_CI']
      }
      @running_in_ci = ci_env_vars.any? { |_, value| value.to_s.downcase == 'true' }
    end

    def apply_skip_list(binding_info)
      unless @debug
        variables = binding_info[:variables]
        variables[:instances]&.reject! { |var, _| skip_list.include?(var) || (var.to_s.start_with?('@_') && !@debug) }
        variables[:locals]&.reject! { |var, _| skip_list.include?(var) }
        variables[:globals]&.reject! { |var, _| skip_list.include?(var) }
      end
      binding_info
    end

    def validate_binding_format(binding_info)
      unless binding_info.keys.include?(:capture_event) && binding_info[:variables].is_a?(Hash)
        return nil
      end
      binding_info
    end

    def binding_info_string(binding_info)
      exception = safe_to_s(binding_info[:exception])
      capture_event = safe_to_s(binding_info[:capture_event]).capitalize
      source = safe_to_s(binding_info[:source])
      result = ''
      unless exception.to_s == 'NoException'
        origination = "#{capture_event.capitalize}d"
        result += "#{Colors.green(origination)}: #{Colors.blue(source)}"
      end
      method_desc = method_and_args_desc(binding_info[:method_and_args])
      result += method_desc

      variables = binding_info[:variables] || {}

      if variables[:locals] && !variables[:locals].empty?
        result += "\n#{Colors.green('Locals:')}\n#{variable_description(variables[:locals])}"
      end

      instance_vars_to_display = variables[:instances] || {}

      if instance_vars_to_display && !instance_vars_to_display.empty?
        result += "\n#{Colors.green('Instances:')}\n#{variable_description(instance_vars_to_display)}"
      end

      # Display let variables for RSpec captures
      if variables[:lets] && !variables[:lets].empty?
        result += "\n#{Colors.green('Let Variables:')}\n#{variable_description(variables[:lets])}"
      end

      if variables[:globals] && !variables[:globals].empty?
        result += "\n#{Colors.green('Globals:')}\n#{variable_description(variables[:globals])}"
      end

      if result.length > max_length
        result = result[0...max_length] + "... (truncated)"
      end
      result + "\n"
    rescue => e
      puts "#{e.message}"
      ''
    end

    private

    def handle_tracepoint_event(tp)
      return unless @enabled
      return if Thread.current[:enhanced_errors_processing] || Thread.current[:on_capture] || ignored_exception?(tp.raised_exception)
      Thread.current[:enhanced_errors_processing] = true
      exception = tp.raised_exception
      capture_me = !exception.frozen? && EnhancedErrors.eligible_for_capture.call(exception)

      unless capture_me
        Thread.current[:enhanced_errors_processing] = false
        return
      end

      binding_context = tp.binding
      method_name = tp.method_id
      method_and_args = {
        object_name: determine_object_name(tp, method_name),
        args: extract_arguments(tp, method_name)
      }

      locals = binding_context.local_variables.map { |var|
        [var, safe_local_variable_get(binding_context, var)]
      }.to_h

      instance_vars = binding_context.receiver.instance_variables
      instances = instance_vars.map { |var|
        [var, safe_instance_variable_get(binding_context.receiver, var)]
      }.to_h

      # No let variables for exceptions
      lets = {}

      globals = {}
      if @debug
        globals = (global_variables - @original_global_variables).map { |var|
          [var, get_global_variable_value(var)]
        }.to_h
      end

      capture_event = safe_to_s(tp.event)
      location = "#{safe_to_s(tp.path)}:#{safe_to_s(tp.lineno)}"

      binding_info = {
        source: location,
        object: tp.self,
        library: !!GEMS_REGEX.match?(location),
        method_and_args: method_and_args,
        test_name: test_name,
        variables: {
          locals: locals,
          instances: instances,
          lets: lets,
          globals: globals
        },
        exception: safe_to_s(exception.class.name),
        capture_event: capture_event
      }

      binding_info = default_on_capture(binding_info)

      if on_capture_hook
        begin
          Thread.current[:on_capture] = true
          binding_info = on_capture_hook.call(binding_info)
        rescue
          binding_info = nil
        ensure
          Thread.current[:on_capture] = false
        end
      end

      if binding_info
        binding_info = validate_binding_format(binding_info)

        if binding_info && exception.binding_infos.length >= MAX_BINDING_INFOS
          # delete from the middle of the array as the ends are most interesting
          exception.binding_infos.delete_at(MAX_BINDING_INFOS / 2.round)
        end

        if binding_info
          exception.binding_infos << binding_info
          override_exception_message(exception, exception.binding_infos) if @override_messages
        end
      end
    rescue
      # Avoid raising exceptions here
    ensure
      Thread.current[:enhanced_errors_processing] = false
    end

    def ignored_exception?(exception)
      IGNORED_EXCEPTIONS.include?(exception.class.name)
    end

    def test_name
      if defined?(RSpec)
        RSpec&.current_example&.full_description
      end
    rescue
      nil
    end

    def default_capture_events
      events = [:raise]
      if capture_rescue && Gem::Version.new(RUBY_VERSION) >= Gem::Version.new('3.3.0')
        events << :rescue
      end
      Set.new(events)
    end

    def validate_and_set_capture_events(capture_events)
      if capture_events.nil?
        @capture_events = default_capture_events
        return
      end

      unless valid_capture_events?(capture_events)
        puts "EnhancedErrors: Invalid capture_events provided. Falling back to defaults."
        @capture_events = default_capture_events
        return
      end

      if capture_events.include?(:rescue) && Gem::Version.new(RUBY_VERSION) < Gem::Version.new('3.3.0')
        puts "EnhancedErrors: Warning: :rescue capture_event not supported below Ruby 3.3.0, ignoring it."
        capture_events = capture_events - [:rescue]
      end

      if capture_events.empty?
        puts "No valid capture_events provided to EnhancedErrors.enhance_exceptions! Falling back to defaults."
        @capture_events = default_capture_events
        return
      end

      @capture_events = capture_events.to_set
    end

    def valid_capture_events?(capture_events)
      return false unless capture_events.is_a?(Array) || capture_events.is_a?(Set)
      valid_types = [:raise, :rescue].to_set
      capture_events.to_set.subset?(valid_types)
    end

    def extract_arguments(tp, method_name)
      return '' unless method_name
      begin
        bind = tp.binding
        unbound_method = tp.defined_class.instance_method(method_name)
        method_obj = unbound_method.bind(tp.self)
        parameters = method_obj.parameters
        locals = bind.local_variables

        parameters.map do |(_, name)|
          value = locals.include?(name) ? safe_local_variable_get(bind, name) : nil
          "#{name}=#{safe_inspect(value)}"
        rescue => e
          "#{name}=[Error getting argument: #{e.message}]"
        end.join(", ")
      rescue => e
        "[Error getting arguments: #{e.message}]"
      end
    end

    def determine_object_name(tp, method_name = '')
      begin
        # These tricks are used to get around the fact that `tp.self` can be a class that is
        # wired up with method_missing where every direct call alters the class. This is true
        # on certain builders or config objects and caused problems.

        # Directly bind and call the `class` method to avoid triggering `method_missing`
        self_class = Object.instance_method(:class).bind(tp.self).call

        # Similarly, bind and call `singleton_class` safely
        singleton_class = Object.instance_method(:singleton_class).bind(tp.self).call

        if self_class && tp.defined_class == singleton_class
          object_identifier = safe_to_s(tp.self)
          method_suffix = method_name && !method_name.empty? ? ".#{method_name}" : ""
          "#{object_identifier}#{method_suffix}"
        else
          object_class_name = safe_to_s(self_class.name || 'UnknownClass')
          method_suffix = method_name && !method_name.empty? ? "##{method_name}" : ""
          "#{object_class_name}#{method_suffix}"
        end
      rescue Exception => e
        '[ErrorGettingName]'
      end
    end

    def get_global_variable_value(var)
      var.is_a?(Symbol) ? eval("#{var}") : nil
    rescue => e
      "[Error getting value for #{var}]"
    end

    def method_and_args_desc(method_info)
      object_name = safe_to_s(method_info[:object_name])
      args = safe_to_s(method_info[:args])
      return '' if object_name.empty? && args.empty?
      arg_str = args.empty? ? '' : "(#{args})"
      str = object_name + arg_str
      "\n#{Colors.green('Method: ')}#{Colors.blue(str)}\n"
    rescue
      ''
    end

    def variable_description(vars_hash)
      vars_hash.map do |name, value|
        "  #{Colors.purple(name)}: #{format_variable(value)}\n"
      end.join
    rescue
      ''
    end

    def format_variable(variable)
      if awesome_print_available? && Colors.enabled?
        variable.ai
      else
        safe_inspect(variable)
      end
    rescue => e
      var_str = safe_to_s(variable)
      "#{var_str}: [Inspection Error #{e.message}]"
    end

    def awesome_print_available?
      return @awesome_print_available unless @awesome_print_available.nil?
      @awesome_print_available = defined?(AwesomePrint)
    end

    def safe_inspect(variable)
      str = variable.inspect
      if str.length > 1200
        str[0...1200] + '...'
      else
        str
      end
    rescue
      safe_to_s(variable)
    end

    def safe_to_s(variable)
      str = variable.to_s
      if str.length > 120
        str[0...120] + '...'
      else
        str
      end
    rescue
      "[Unprintable variable]"
    end

    def safe_local_variable_get(binding_context, var_name)
      binding_context.local_variable_get(var_name)
    rescue
      "[Error accessing local variable #{var_name}]"
    end

    def safe_instance_variable_get(obj, var_name)
      obj.instance_variable_get(var_name)
    rescue
      "[Error accessing instance variable #{var_name}]"
    end

    def default_on_format(string)
      string
    end

    def default_on_capture(binding_info)
      EnhancedErrors.apply_skip_list(binding_info)
    end

    def default_eligible_for_capture(exception)
      ignored = ignored_exception?(exception)
      rspec = exception.class.name.start_with?('RSpec::Matchers')
      !ignored && !rspec
    end
  end
end
