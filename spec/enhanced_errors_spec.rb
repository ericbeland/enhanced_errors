# spec/enhanced_errors_spec.rb

require_relative '../lib/enhanced_errors'
require_relative 'spec_helper'

class TestClass
  def self.class_method(arg1)
    raise 'Exception in class method'
  end

  def instance_method(arg1, arg2)
    raise 'Exception in instance method'
  end
end

def configure_rspec
  RSpec.configure do |config|
    config.before(:example) do |_example|
      EnhancedErrors.start_rspec_binding_capture
    end

    config.after(:example) do |example|
      EnhancedErrors.override_rspec_message(example, EnhancedErrors.stop_rspec_binding_capture)
    end
  end
end

RSpec.describe EnhancedErrors do
  before(:each) do
    # Enable exception enhancements and RSpec enhancements so let variables are captured
    EnhancedErrors.enhance_exceptions!(override_messages: false)
  end

  # Helper method to strip ANSI color codes from strings
  def strip_color_codes(str)
    str.gsub(/\e\[\d+(;\d+)*m/, '')
  end

  describe 'Exception enhancement' do
    let(:let_variable) { 'let_value' }
    let(:captured_bindings) do
      [
        {
          source: "spec/enhanced_errors_spec.rb:10",
          object: self,
          library: false,
          method_and_args: {
            object_name: "RSpec.describe",
            args: "EnhancedErrors"
          },
          variables: {
            locals: { example: "test" },
            instances: {},
            lets: {},
            globals: {}
          },
          exception: "StandardError",
          capture_event: "raise"
        }
      ]
    end

    before(:each) do
      @instance_variable = 'instance_value'
    end

    after(:each) do
      EnhancedErrors.enhance_exceptions!(enabled: false)
    end

    context 'override_messages option' do
      it 'does not override the exception message if override_messages: false' do
        EnhancedErrors.enhance_exceptions!(override_messages: false)
        expect {
          raise 'Original message'
        }.to raise_error(StandardError) do |e|
          # The captured_variables should appear only if printed out by the user; message should remain unchanged
          expect(e.message).to eq('Original message')
          # captured_variables should still be callable
          expect(e.captured_variables).to_not be_empty
        end
      end

      it 'overrides the exception message if override_messages: true' do
        EnhancedErrors.enhance_exceptions!(override_messages: true)
        expect {
          local_var = 'hello' # to ensure something is captured
          raise 'Original message'
        }.to raise_error(StandardError) do |e|
          msg = strip_color_codes(e.message)
          # Now the message should include the captured variables
          expect(msg).to include('Original message')
          expect(msg).to include('Locals:')
          expect(msg).to include("local_var: \"hello\"") # Updated to match actual format
        end
      end
    end

    context 'RSpec bindings capture without exceptions' do
      before(:all) do
        EnhancedErrors.start_rspec_binding_capture
      end

      after(:all) do
        EnhancedErrors.stop_rspec_binding_capture
      end

      it 'captures bindings from RSpec test blocks via start/stop methods' do
        test_local = true
      end
    end

    context 'EnhancedErrors.stop_rspec_binding_capture' do

      it 'does not capture bindings if start_rspec_binding_capture was not called' do
        EnhancedErrors.stop_rspec_binding_capture
        binding_info = EnhancedErrors.stop_rspec_binding_capture
        expect(binding_info).to be_nil
      end

    end

    context 'variable capture' do

      it 'captures instance variables when an exception is raised' do
        expect {
          raise 'Test exception'
        }.to raise_error(StandardError) do |e|
          binding_infos = e.binding_infos
          last_binding_info = binding_infos.last
          instances = last_binding_info[:variables][:instances]
          expect(instances).to include(:@instance_variable)
          expect(instances[:@instance_variable]).to eq('instance_value')
        end
      end
    end

    context 'environment defaults' do
      it 'applies correct defaults based on environment' do
        ENV['RAILS_ENV'] = 'development'
        EnhancedErrors.enhance_exceptions!
        expect(EnhancedErrors.get_default_format_for_environment).to eq(:terminal)

        ENV['RAILS_ENV'] = 'production'
        EnhancedErrors.enhance_exceptions!
        expect(EnhancedErrors.get_default_format_for_environment).to eq(:json)

        ENV.delete('RAILS_ENV')
      ensure
        EnhancedErrors.enhance_exceptions!(enabled: false)
      end
    end

    context 'capture_events' do
      let(:original_ruby_version) { RUBY_VERSION }

      before do
        EnhancedErrors.instance_variable_set(:@capture_events, nil)
        allow(EnhancedErrors).to receive(:start_tracing)
      end

      after do
        stub_const('RUBY_VERSION', original_ruby_version)
      end

      describe 'capture_events behavior' do
        context 'when capture_events is not provided (default behavior)' do
          context 'with Ruby version >= 3.3.0' do
            before { stub_const('RUBY_VERSION', '3.3.0') }

            it 'sets @capture_events containing :raise' do
              EnhancedErrors.capture_rescue = false
              EnhancedErrors.send(:validate_and_set_capture_events, nil)
              expect(EnhancedErrors.instance_variable_get(:@capture_events)).to eq([:raise])
            end
          end

          context 'with Ruby version < 3.3.0' do
            before { stub_const('RUBY_VERSION', '3.2.0') }

            it 'sets @capture_events to Set containing :raise only' do
              EnhancedErrors.send(:validate_and_set_capture_events, nil)
              expect(EnhancedErrors.instance_variable_get(:@capture_events)).to eq([:raise])
            end
          end
        end

        context 'when capture_events is provided as an array' do
          it 'captures only :raise' do
            EnhancedErrors.send(:validate_and_set_capture_events, [:raise])
            expect(EnhancedErrors.instance_variable_get(:@capture_events)).to eq([:raise])
          end

          it 'captures only :rescue with Ruby >= 3.3.0' do
            stub_const('RUBY_VERSION', '3.3.0')
            EnhancedErrors.send(:validate_and_set_capture_events, [:rescue])
            expect(EnhancedErrors.instance_variable_get(:@capture_events)).to eq([:rescue])
          end

          it 'captures both :raise and :rescue with Ruby >= 3.3.0' do
            stub_const('RUBY_VERSION', '3.3.0')
            EnhancedErrors.send(:validate_and_set_capture_events, [:raise, :rescue])
            expect(EnhancedErrors.instance_variable_get(:@capture_events)).to eq([:raise, :rescue])
          end

          it 'ignores :rescue with Ruby < 3.3.0 and prints a warning' do
            stub_const('RUBY_VERSION', '3.2.0')
            expect {
              EnhancedErrors.send(:validate_and_set_capture_events, [:raise, :rescue])
            }.to output(/EnhancedErrors: Warning: :rescue capture_event not supported below Ruby 3.3.0, ignoring it./).to_stdout

            expect(EnhancedErrors.instance_variable_get(:@capture_events)).to eq([:raise])
          end
        end
      end
    end

    context 'multiple variable appends' do
      after(:each) do
        EnhancedErrors.enhance_exceptions!(enabled: false)
      end

      it 'only appends variables once' do
        EnhancedErrors.enhance_exceptions!
        expect {
          @foo = 'bar'
          begin
            raise RuntimeError.new('Foo')
          rescue => e
            boo = 'baz'
            begin
              raise e
            rescue => exception
              raise exception
              exception.captured_variables
            end
          end
        }.to raise_error(RuntimeError) do |e|
          expect(e.captured_variables.scan('@foo').size).to eq(1)
        end
      end
    end

    context 'variable exclusion' do

      after(:each) do
        EnhancedErrors.enhance_exceptions!(enabled: false)
      end

      it 'excludes variables in the skip list from binding information' do
        @variable_to_skip = 'should be skipped'
        @variable_to_include = 'should be included'

        EnhancedErrors.enhance_exceptions! do
          add_to_skip_list :@variable_to_skip
        end

        expect {
          raise 'Test exception'
        }.to raise_error(StandardError) do |e|
          binding_infos = e.binding_infos
          last_binding_info = binding_infos.last
          instances = last_binding_info[:variables][:instances]

          expect(instances).to include(:@variable_to_include)
          expect(instances).not_to include(:@variable_to_skip)
        end
      end

      it 'skips @_ variables in info mode' do
        EnhancedErrors.enhance_exceptions!
        expect {
          @_variable_to_skip = 'should be skipped'
          raise 'Test exception'
        }.to raise_error(StandardError) do |e|
          expect(e.captured_variables).not_to include('@_variable_to_skip')
        end
      end

      it 'includes @_ variables in debug mode' do
        @_variable_to_not_skip = 'should not be skipped'

        EnhancedErrors.enhance_exceptions!(debug: true)
        expect {
          raise 'Test exception'
        }.to raise_error(StandardError) do |e|
          expect(e.captured_variables).to include('@_variable_to_not_skip')
        end
      end
    end

    context 'output truncation' do
      it 'truncates output according to max_length' do
        @large_variable = 'a' * 5000

        EnhancedErrors.enhance_exceptions! do
          max_length 1000
        end

        expect {
          raise 'Test exception'
        }.to raise_error(StandardError) do |e|
          expect(e.captured_variables.length).to be <= 1500
        end
      end
    end

    context 'hooks' do
      before do
        EnhancedErrors.enhance_exceptions!
        EnhancedErrors.on_capture = nil
        EnhancedErrors.on_format = nil
      end

      describe 'on_capture hook' do
        it 'allows modification of the binding info structures' do
          captured_binding_infos = []
          EnhancedErrors.on_capture do |binding_info|
            binding_info[:variables][:locals].transform_values! do |value|
              value == 'super_secret' ? '[REDACTED]' : value
            end
            captured_binding_infos << binding_info
            binding_info
          end

          begin
            username = 'test_user'
            password = 'super_secret'
            raise 'Authentication failed'
          rescue => e
            @exception = e
          end

          expect(captured_binding_infos).not_to be_empty
          locals = captured_binding_infos.first[:variables][:locals]
          expect(locals[:username]).to eq('test_user')
          expect(locals[:password]).to eq('[REDACTED]')
        end

        it 'handles exceptions raised in the on_capture block' do
          exception_in_on_capture = RuntimeError.new('Error in on_capture')

          EnhancedErrors.on_capture do |binding_info|
            raise exception_in_on_capture
          end

          expect {
            foo = 'bar'
            raise 'Test exception'
          }.to raise_error(StandardError) do |e|
            # Ensure the original exception is raised, not the one from on_capture
            expect(e.captured_variables).to_not include('bar')
            # Ensure that no binding_infos were captured
            binding_infos = e.binding_infos
            expect(binding_infos).to be_nil.or be_empty
            # Ensure that the exception from on_capture does not cause a reentrant exception
            expect {
              e.captured_variables
            }.not_to raise_error
          end
        end

        it 'does not capture data if on_capture raises an exception' do
          EnhancedErrors.on_capture do |binding_info|
            raise 'Error in on_capture'
          end

          expect {
            raise 'Test exception'
          }.to raise_error(StandardError) do |e|
            # Ensure that no binding_infos were captured
            binding_infos = e.binding_infos
            expect(binding_infos).to be_nil.or be_empty
          end
        end
      end

      describe 'on_format hook' do
        it 'receives a string in the on_format hook' do
          received_string = nil

          EnhancedErrors.on_format do |formatted_string|
            received_string = formatted_string
            formatted_string
          end

          EnhancedErrors.format(captured_bindings)

          expect(received_string).to be_a(String)
          expect(received_string).to_not be_empty
        end

        it 'replaces the formatted string in the result' do
          EnhancedErrors.on_format do |formatted_string|
            '---whatever---'
          end
          result = EnhancedErrors.format(captured_bindings)
          expect(result).to eq('---whatever---')
        end

        it 'resets on_format to nil and uses the default formatted output' do
          default_formatted_output = EnhancedErrors.binding_infos_array_to_string(captured_bindings, :terminal)

          EnhancedErrors.on_format do |formatted_string|
            '---whatever---'
          end
          result_with_hook = EnhancedErrors.format(captured_bindings)
          expect(result_with_hook).to eq('---whatever---')

          EnhancedErrors.on_format = nil
          result_without_hook = EnhancedErrors.format(captured_bindings)
          expect(result_without_hook).to eq(default_formatted_output)
        end

        it 'handles exceptions raised in the on_format block' do
          EnhancedErrors.on_format do |formatted_string|
            raise 'Error in on_format'
          end

          expect {
            raise 'Test exception'
          }.to raise_error(StandardError) do |e|
            # Ensure the original exception message is preserved
            expect(e.captured_variables).to eq('')
            expect {
              e.captured_variables
            }.not_to raise_error
          end
        end

        it 'does not display data if on_format raises an exception' do
          EnhancedErrors.on_format do |formatted_string|
            raise 'Error in on_format'
          end

          expect {
            local_var = 'test_value'
            raise 'Test exception'
          }.to raise_error(StandardError) do |e|
            # The captured_variables should be empty
            expect(e.captured_variables).to eq('')
            expect {
              e.captured_variables
            }.not_to raise_error
          end
        end
      end

      describe 'captured_variables method' do
        it 'captures binding information' do
          captured_binding_infos = []
          EnhancedErrors.on_capture do |binding_info|
            captured_binding_infos << binding_info
            binding_info
          end

          expect {
            raise 'Test exception'
          }.to raise_error(StandardError) do |e|
            @exception = e
          end

          expect(captured_binding_infos).not_to be_empty
        end

        it 'returns the variable message separately' do
          expect {
            local_var = 'test_value'
            raise 'An error occurred'
          }.to raise_error(StandardError) do |e|
            @exception = e
          end

          expect(@exception).to respond_to(:captured_variables)
          expect(@exception.captured_variables).to include('Locals:', 'local_var', 'test_value')
        end
      end

      describe 'capture_event field in binding info' do
        it 'has capture_event set to "raise" when an exception is raised' do
          captured_binding_infos = []
          EnhancedErrors.on_capture do |binding_info|
            captured_binding_infos << binding_info
            binding_info
          end

          expect {
            raise 'Test exception'
          }.to raise_error(StandardError) do |e|
            @exception = e
          end

          expect(captured_binding_infos.first[:capture_event]).to eq('raise')
        end

        it 'does not capture "rescue" events by default' do
          captured_binding_infos = []
          EnhancedErrors.on_capture do |binding_info|
            captured_binding_infos << binding_info
            binding_info
          end

          begin
            raise 'Test exception'
          rescue
            # Exception is rescued here
          end

          rescue_info = captured_binding_infos.find { |info| info[:capture_event] == 'rescue' }
          expect(rescue_info).to be_nil
        end

        it 'captures "rescue" events when capture_rescue is true' do
          if Gem::Version.new(RUBY_VERSION) < Gem::Version.new('3.3.0')
            skip 'Ruby version does not support :rescue event in TracePoint'
          end

          EnhancedErrors.enhance_exceptions!(capture_rescue: true)

          captured_binding_infos = []
          EnhancedErrors.on_capture do |binding_info|
            captured_binding_infos << binding_info
            binding_info
          end

          begin
            raise 'Test exception'
          rescue
            # Exception is rescued here
          end

          expect(EnhancedErrors.capture_rescue).to be_truthy
          rescue_info = captured_binding_infos.find { |info| info[:capture_event] == 'rescue' }
          expect(rescue_info).not_to be_nil
          expect(rescue_info[:capture_event]).to eq('rescue')

        ensure
          EnhancedErrors.capture_rescue = false
        end
      end
    end

    describe 'method and arguments capture' do


      it 'captures class method and arguments' do
        expect {
          TestClass.class_method('value1')
        }.to raise_error(StandardError) do |e_class|
          binding_infos = e_class.binding_infos
          last_binding_info = binding_infos.last
          method_and_args = last_binding_info[:method_and_args]

          expect(method_and_args[:object_name]).to eq('TestClass.class_method')
          expect(method_and_args[:args]).to include('arg1="value1"')
        end
      end

      it 'captures instance method and arguments' do
        expect {
          obj = TestClass.new
          obj.instance_method('value1', 'value2')
        }.to raise_error(StandardError) do |e_instance|
          binding_infos = e_instance.binding_infos
          last_binding_info = binding_infos.last
          method_and_args = last_binding_info[:method_and_args]

          expect(method_and_args[:object_name]).to eq('TestClass#instance_method')
          expect(method_and_args[:args]).to include('arg1="value1"', 'arg2="value2"')
        end
      end

    end

    it 'captures binding information when exceptions are rescued and re-raised' do
      EnhancedErrors.enhance_exceptions!
      def method_with_rescue
        begin
          raise 'Initial exception'
        rescue => e
          raise e
        end
      end

      expect {
        method_with_rescue
      }.to raise_error(StandardError) do |e|
        binding_infos = e.binding_infos

        if Gem::Version.new(RUBY_VERSION) >= Gem::Version.new('3.3.0')
          expect(binding_infos.size).to be >= 2
        else
          expect(binding_infos.size).to be >= 1
        end

        first_binding_info = binding_infos.first
        last_binding_info = binding_infos.last

        expect(first_binding_info[:method_and_args][:object_name]).to include('method_with_rescue')
        expect(last_binding_info[:method_and_args][:object_name]).to include('method_with_rescue')
      end
    end

    context 'TracePoint management' do
      before(:each) do
        # Ensure EnhancedErrors is disabled before each test
        EnhancedErrors.enhance_exceptions!(enabled: false)
        # Reset trace to ensure a clean state
        EnhancedErrors.trace = nil
      end

      it 'manages TracePoint correctly when enhance_exceptions! is called multiple times' do
        # After disabling, @trace should be nil
        expect(EnhancedErrors.trace).to be_nil

        # Call enhance_exceptions! to enable tracing
        EnhancedErrors.enhance_exceptions!
        first_trace = EnhancedErrors.trace
        expect(first_trace).not_to be_nil
        expect(first_trace.enabled?).to be true

        # Call enhance_exceptions! again to ensure idempotency
        EnhancedErrors.enhance_exceptions!
        second_trace = EnhancedErrors.trace

        # Disable EnhancedErrors
        EnhancedErrors.enhance_exceptions!(enabled: false)
        disabled_trace = EnhancedErrors.trace
        # we have switched to cleaning it up, as it seems safer
        expect(disabled_trace && disabled_trace.enabled).to be_falsey
      end

      it 'caps max binding_infos to track at 10' do
        EnhancedErrors.enhance_exceptions!
        exception = StandardError.new('I got raised 15 times')
        15.times do
          begin
            raise exception
          rescue => e
            # EnhancedErrors processes the exception here
          end
        end
        expect(exception.binding_infos.size).to eq(3)
      ensure
        EnhancedErrors.enhance_exceptions!(enabled: false)
      end

      it 'remains disabled after being disabled until explicitly re-enabled' do
        # Ensure EnhancedErrors is disabled
        EnhancedErrors.enhance_exceptions!(enabled: false)
        EnhancedErrors.trace = nil
        expect(EnhancedErrors.enabled).to be false

        # Ensure the TracePoint for the current thread is nil
        trace = EnhancedErrors.trace
        expect(trace).to be_nil

        # Raise an exception and ensure @binding_infos is not set
        expect {
          raise 'Test exception while disabled'
        }.to raise_error(StandardError) do |e|
          expect(e.binding_infos).to eq([])
        end

        # Re-enable EnhancedErrors
        EnhancedErrors.enhance_exceptions!(enabled: true)
        expect(EnhancedErrors.enabled).to be true

        # Ensure TracePoint is enabled
        trace = EnhancedErrors.trace
        expect(trace).not_to be_nil
        expect(trace.enabled?).to be true

        # Raise an exception and ensure @binding_infos is set
        expect {
          raise 'Test exception while enabled'
        }.to raise_error(StandardError) do |e|
          expect(e.binding_infos).not_to be_nil
        end
      end
    end

    context 'colorization based on format' do
      it 'enables and disables colorization in ::Enhanced::Colors based on format' do
        ENV['RAILS_ENV'] = 'development'
        EnhancedErrors.enhance_exceptions!
        expect(EnhancedErrors.get_default_format_for_environment).to eq(:terminal)

        expect {
          raise 'Test exception with color'
        }.to raise_error(StandardError) do |e|
          e.captured_variables
          expect(::Enhanced::Colors.enabled?).to be true
          expect(e.captured_variables).to include("\e[")
        end

        ENV['RAILS_ENV'] = 'production'
        EnhancedErrors.enhance_exceptions!
        expect(EnhancedErrors.get_default_format_for_environment).to eq(:json)

        expect {
          raise 'Test exception without color'
        }.to raise_error(StandardError) do |e|
          e.captured_variables
          expect(::Enhanced::Colors.enabled?).to be false
          expect(e.captured_variables).not_to include("\e[")
        end

        ENV.delete('RAILS_ENV')
      end
    end

    context 'tracing and exception enhancement' do
      it 'enables and disables tracing and checks exception enhancement' do
        EnhancedErrors.enhance_exceptions!(enabled: false)
        expect(EnhancedErrors.enabled).to be false

        expect {
          raise 'Test exception without tracing'
        }.to raise_error(StandardError) do |e|
          binding_infos = e.binding_infos
          expect(binding_infos).to eq([])
        end

        EnhancedErrors.enhance_exceptions!(enabled: true)
        expect(EnhancedErrors.enabled).to be true

        expect {
          raise 'Test exception with tracing'
        }.to raise_error(StandardError) do |e|
          binding_infos = e.binding_infos
          expect(binding_infos).not_to be_nil
        end
      end
    end

    context 'eligibility for capture' do
      before do
        EnhancedErrors.enhance_exceptions!
        EnhancedErrors.on_capture = nil
      end

      after do
        EnhancedErrors.on_capture = nil
      end

      it 'captures eligible exceptions' do
        EnhancedErrors.enhance_exceptions! do
          eligible_for_capture { |exception| true }
        end

        expect {
          raise 'Test exception'
        }.to raise_error(StandardError) do |e|
          expect(e.binding_infos).to_not be_nil
        end
      end

      it 'ignores ineligible exceptions' do
        EnhancedErrors.enhance_exceptions! do
          eligible_for_capture { |exception| false }
        end

        expect {
          raise 'Test exception'
        }.to raise_error(StandardError) do |e|
          expect(e.captured_variables).to eq('')
        end
      end
    end

    context 'global variables' do
      before(:each) do
        EnhancedErrors.enhance_exceptions!(debug: false)
      end

      describe 'Global Variable Capture with Shared Skip List' do
        it 'captures new global variables when in debug mode, ignoring the skip list' do
          $variable_to_skip = 'should not be captured in debug mode as was present before enhance! call'
          EnhancedErrors.enhance_exceptions!(debug: true)
          $variable_to_include = 'should be included as happened after'

          expect {
            raise 'Test exception with global variables in debug mode'
          }.to raise_error(StandardError) do |e|
            expect(e.captured_variables).to_not include('$variable_to_skip')
            expect(e.captured_variables).to include('$variable_to_include')
          end
        ensure
          $variable_to_skip = nil
          $variable_to_include = nil
        end
      end
    end


    describe 'Edge cases with unusual exceptions and objects' do
      context 'exceptions raised in BasicObject instances' do
        it 'handles exceptions raised in BasicObject instances without methods' do
          basic_object_class = Class.new(BasicObject) do
            def raise_exception
              ::Kernel.raise 'Error from BasicObject'
            end
          end

          obj = basic_object_class.new

          expect {
            obj.raise_exception
          }.to raise_error(RuntimeError, 'Error from BasicObject') do |e|
            expect(e.message).to include('Error from BasicObject')
            expect(e.binding_infos).not_to be_nil
          end
        end
      end

      context 'exceptions that do not inherit from StandardError' do
        it 'handles exceptions that do not inherit from StandardError' do
          class CustomException < Exception
            def initialize(msg='Custom exception')
              super(msg)
            end
          end

          expect {
            raise CustomException.new('Non-StandardError exception')
          }.to raise_error(CustomException) do |e|
            expect(e.binding_infos).not_to be_nil
          end
        end
      end

      context 'exceptions with faulty message methods' do
        it 'handles exceptions where message method raises an exception' do
          class FaultyMessageException < StandardError
            def message
              raise 'Exception in message method'
            end
          end

          expect {
            raise FaultyMessageException.new
          }.to raise_error(FaultyMessageException) do |e|
            expect {
              e.captured_variables
            }.not_to raise_error
            message_without_colors = strip_color_codes(e.captured_variables)
            expect(message_without_colors).to include('Instances:')
            expect(e.binding_infos).not_to be_nil
          end
        end
      end

      context 'variables that raise exceptions when inspected' do
        it 'handles variables that raise exceptions when inspected' do
          class UninspectableObject
            def inspect
              raise 'Exception in inspect method'
            end

            def to_s
              raise 'Exception in to_s method'
            end
          end

          uninspectable_variable = UninspectableObject.new

          expect {
            begin
              local_variable = uninspectable_variable
              raise 'Test exception with uninspectable variable'
            rescue => e
              # Simulate variable in the binding that raises exception when inspected
              raise e
            end
          }.to raise_error(RuntimeError) do |e|
            expect(e.binding_infos).not_to be_nil
            message_without_colors = strip_color_codes(e.captured_variables)
            expect(message_without_colors).to match(/local_variable: \[Unprintable variable\]/)
          end
        end
      end
    end
  end



end


RSpec.describe EnhancedErrors, 'max_capture_events functionality' do
  before(:each) do
    # Fully reset the environment before each test
    EnhancedErrors.enhance_exceptions!(enabled: false)
    EnhancedErrors.reset_capture_events_count
    EnhancedErrors.max_capture_events = -1
    EnhancedErrors.trace = nil

    # Re-enable with a restricted eligible_for_capture
    EnhancedErrors.enhance_exceptions!(enabled: true, override_messages: false) do
      # Only capture exceptions that start with known test phrases to avoid interference
      eligible_for_capture do |ex|
        ex.is_a?(StandardError) && ex.message =~ /^(Test|First|Second|Third|Hit|Now capturing|Exception)/
      end
    end
  end

  after(:each) do
    # Disable after each test to avoid state leaking into subsequent tests
    EnhancedErrors.enhance_exceptions!(enabled: false)
    EnhancedErrors.reset_capture_events_count
    EnhancedErrors.max_capture_events = -1
    EnhancedErrors.trace = nil
  end

  it 'disables capturing after exceeding the max capture limit' do
    EnhancedErrors.max_capture_events = 2
    expect(EnhancedErrors.capture_events_count).to eq(0)

    # Raise first exception
    expect {
      raise 'First exception'
    }.to raise_error(StandardError)
    expect(EnhancedErrors.capture_events_count).to eq(1)

    # Raise second exception
    expect {
      raise 'Second exception'
    }.to raise_error(StandardError)
    expect(EnhancedErrors.capture_events_count).to eq(2)

    # Raise third exception - should exceed limit and disable capturing
    expect {
      raise 'Third exception'
    }.to raise_error(StandardError)

    # Capturing should be disabled now, no increment
    expect(EnhancedErrors.capture_events_count).to eq(2)
    expect(EnhancedErrors.enabled).to be false
  end

  it 'does not increase capture_events_count once disabled' do
    EnhancedErrors.max_capture_events = 1

    # Hit the limit
    expect {
      raise 'Test exception'
    }.to raise_error(StandardError)
    expect(EnhancedErrors.capture_events_count).to eq(1)
    expect(EnhancedErrors.enabled).to be false

    # Another exception should not increment the count
    expect {
      raise 'Test exception'
    }.to raise_error(StandardError)
    expect(EnhancedErrors.capture_events_count).to eq(1)
  end

  it 'resets capture_events_count to 0 and allows capturing again' do
    EnhancedErrors.max_capture_events = 1

    # Hit the limit
    expect {
      raise 'Hit the limit'
    }.to raise_error(StandardError)
    expect(EnhancedErrors.capture_events_count).to eq(1)
    expect(EnhancedErrors.enabled).to be false

    # Reset the count
    EnhancedErrors.reset_capture_events_count
    expect(EnhancedErrors.capture_events_count).to eq(0)
    EnhancedErrors.max_capture_events = 1

    # Now we should be able to capture again
    expect {
      raise 'Now capturing again'
    }.to raise_error(StandardError)
    expect(EnhancedErrors.capture_events_count).to eq(1)
    # Should be disabled again after hitting the limit
    expect(EnhancedErrors.enabled).to be false
  end

  it 'allows unlimited capturing when max_capture_events = -1' do
    EnhancedErrors.reset_capture_events_count
    expect(EnhancedErrors.capture_events_count).to eq(0)

    # this is doubled as each raise is both an RSpec expectation
    # failure, and also a StandardError
    5.times do |i|
      expect {
        raise "Exception #{i}"
      }.to raise_error(StandardError)
    end

    # With unlimited capturing, count should equal number of captures
    expect(EnhancedErrors.capture_events_count).to eq(5)
    expect(EnhancedErrors.enabled).to be true
  end
end
