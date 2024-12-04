require_relative '../lib/enhanced_errors'

RSpec.describe EnhancedErrors do
  before(:each) do
    EnhancedErrors.enhance!
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

    context 'variable capture' do
      it 'captures RSpec let variables when an exception is raised' do
        let_variable
        expect {
          raise 'Test exception'
        }.to raise_error(StandardError, /let_value/)
      end

      it 'captures instance variables when an exception is raised' do
        expect {
          raise 'Test exception'
        }.to raise_error(StandardError) do |e|
          binding_infos = e.instance_variable_get(:@binding_infos)
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
        EnhancedErrors.enhance!
        expect(EnhancedErrors.get_default_format_for_environment).to eq(:terminal)

        ENV['RAILS_ENV'] = 'production'
        EnhancedErrors.enhance!
        expect(EnhancedErrors.get_default_format_for_environment).to eq(:json)

        ENV.delete('RAILS_ENV')
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

            it 'sets @capture_events to [:raise, :rescue]' do
              EnhancedErrors.send(:validate_and_set_capture_events, nil)
              expect(EnhancedErrors.instance_variable_get(:@capture_events)).to eq([:raise, :rescue])
            end
          end

          context 'with Ruby version < 3.3.0' do
            before { stub_const('RUBY_VERSION', '3.2.0') }

            it 'sets @capture_events to [:raise] only' do
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
            }.to output(/Warning: :rescue capture_event is not supported/).to_stdout

            expect(EnhancedErrors.instance_variable_get(:@capture_events)).to eq([:raise])
          end

        end
      end
    end

    context 'multiple variable appends' do
      it 'only appends variables once' do
        EnhancedErrors.enhance!
        expect {
        @foo = 'bar'
        begin
          raise RuntimeError.new('Foo')
        rescue Exception => e
          boo = 'baz'
          begin
            raise e
          rescue => exception
            raise exception # RuntimeError.new "Exception: #{exception}"
            exception.message
          end
        end
        }.to raise_error(RuntimeError) do |e|
          expect(e.message).to include("@foo").once
        end
      end
    end

    context 'variable exclusion' do
      it 'excludes variables in the skip list from binding information' do
        @variable_to_skip = 'should be skipped'
        @variable_to_include = 'should be included'

        EnhancedErrors.enhance! do
          add_to_skip_list :@variable_to_skip
        end

        expect {
          raise 'Test exception'
        }.to raise_error(StandardError) do |e|
          binding_infos = e.instance_variable_get(:@binding_infos)
          last_binding_info = binding_infos.last
          instances = last_binding_info[:variables][:instances]

          expect(instances).to include(:@variable_to_include)
          expect(instances).not_to include(:@variable_to_skip)
        end
      end

      it 'skips @_ variables in info mode' do

        EnhancedErrors.enhance!
        expect {
          @_variable_to_skip = 'should be skipped'
          raise 'Test exception'
        }.to raise_error(StandardError) do |e|
          expect(e.message).not_to include('@_variable_to_skip')
        end
      end

      it 'includes @_ variables in debug mode' do
        @_variable_to_skip = 'should not be skipped'

        EnhancedErrors.enhance!(debug: true)
        expect {
          raise 'Test exception'
        }.to raise_error(StandardError) do |e|
          expect(e.message).to include('@_variable_to_skip')
        end
      end
    end

    context 'output truncation' do
      it 'truncates output according to max_length' do
        @large_variable = 'a' * 5000

        EnhancedErrors.enhance! do
          max_length 1000
        end

        expect {
          raise 'Test exception'
        }.to raise_error(StandardError) do |e|
          expect(e.message.length).to be <= 1500
        end
      end
    end

    context 'hooks' do
      before do
        EnhancedErrors.enhance!
        EnhancedErrors.on_capture = nil
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
      end

      describe 'variables_message method' do
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

          expect(@exception).to respond_to(:variables_message)
          expect(@exception.variables_message).to include('Locals:', 'local_var', 'test_value')
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

        it 'has capture_event set to "rescue" when an exception is rescued' do
          if Gem::Version.new(RUBY_VERSION) < Gem::Version.new('3.3.0')
            skip 'Ruby version does not support :rescue event in TracePoint'
          end

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
          expect(rescue_info).not_to be_nil
          expect(rescue_info[:capture_event]).to eq('rescue')
        end
      end
    end

    describe 'method and arguments capture' do
      before do
        class TestClass
          def self.class_method(arg1)
            raise 'Exception in class method'
          end

          def instance_method(arg1, arg2)
            raise 'Exception in instance method'
          end
        end
      end

      it 'captures class method and arguments' do
        expect {
          TestClass.class_method('value1')
        }.to raise_error(StandardError) do |e_class|
          binding_infos = e_class.instance_variable_get(:@binding_infos)
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
          binding_infos = e_instance.instance_variable_get(:@binding_infos)
          last_binding_info = binding_infos.last
          method_and_args = last_binding_info[:method_and_args]

          expect(method_and_args[:object_name]).to eq('TestClass#instance_method')
          expect(method_and_args[:args]).to include('arg1="value1"', 'arg2="value2"')
        end
      end
    end

    it 'captures binding information when exceptions are rescued and re-raised' do
      def method_with_rescue
        begin
          raise 'Initial exception'
        rescue
          raise
        end
      end

      expect {
        method_with_rescue
      }.to raise_error(StandardError) do |e|
        binding_infos = e.instance_variable_get(:@binding_infos)
        expect(binding_infos.size).to be >= 2

        first_binding_info = binding_infos.first
        last_binding_info = binding_infos.last

        expect(first_binding_info[:method_and_args][:object_name]).to include('method_with_rescue')
        expect(last_binding_info[:method_and_args][:object_name]).to include('method_with_rescue')
      end
    end

    context 'TracePoint management' do
      it 'manages TracePoint correctly when start_tracing is called multiple times' do
        first_trace = EnhancedErrors.trace
        EnhancedErrors.enhance!
        second_trace = EnhancedErrors.trace

        expect(first_trace).to eq(second_trace)
        expect(EnhancedErrors.trace.enabled?).to be true

        EnhancedErrors.enhance!(enabled: false)
        expect(EnhancedErrors.trace.enabled?).to be false
      end

      it 'remains disabled after being disabled until explicitly re-enabled' do
        EnhancedErrors.enhance!(enabled: false)
        expect(EnhancedErrors.enabled).to be false

        expect {
          raise 'Test exception while disabled'
        }.to raise_error(StandardError) do |e|
          expect(e.instance_variable_get(:@binding_infos)).to be_nil
        end

        expect(EnhancedErrors.enabled).to be false

        EnhancedErrors.enhance!(enabled: true)
        expect(EnhancedErrors.enabled).to be true
      end
    end

    context 'colorization based on format' do
      it 'enables and disables colorization in Colors based on format' do
        ENV['RAILS_ENV'] = 'development'
        EnhancedErrors.enhance!
        expect(EnhancedErrors.get_default_format_for_environment).to eq(:terminal)

        expect {
          raise 'Test exception with color'
        }.to raise_error(StandardError) do |e|
          e.message
          expect(Colors.enabled?).to be true
          expect(e.message).to include("\e[")
        end

        ENV['RAILS_ENV'] = 'production'
        EnhancedErrors.enhance!
        expect(EnhancedErrors.get_default_format_for_environment).to eq(:json)

        expect {
          raise 'Test exception without color'
        }.to raise_error(StandardError) do |e|
          e.message
          expect(Colors.enabled?).to be false
          expect(e.message).not_to include("\e[")
        end

        ENV.delete('RAILS_ENV')
      end
    end

    context 'tracing and exception enhancement' do
      it 'enables and disables tracing and checks exception enhancement' do
        EnhancedErrors.enhance!(enabled: false)
        expect(EnhancedErrors.enabled).to be false

        expect {
          raise 'Test exception without tracing'
        }.to raise_error(StandardError) do |e|
          binding_infos = e.instance_variable_get(:@binding_infos)
          expect(binding_infos).to be_nil
        end

        EnhancedErrors.enhance!(enabled: true)
        expect(EnhancedErrors.enabled).to be true

        expect {
          raise 'Test exception with tracing'
        }.to raise_error(StandardError) do |e|
          binding_infos = e.instance_variable_get(:@binding_infos)
          expect(binding_infos).not_to be_nil
        end
      end
    end

    context 'eligibility for capture' do
      before do
        EnhancedErrors.enhance!
        EnhancedErrors.on_capture = nil
      end

      after do
        EnhancedErrors.on_capture = nil
      end

      it 'captures eligible exceptions' do
        EnhancedErrors.enhance! do
          eligible_for_capture { |exception| true }
        end

        expect {
          raise 'Test exception'
        }.to raise_error(StandardError) do |e|
          expect(e.instance_variable_get(:@binding_infos)).to_not be_nil
        end
      end

      it 'ignores ineligible exceptions' do
        EnhancedErrors.enhance! do
          eligible_for_capture { |exception| false }
        end

        expect {
          raise 'Test exception'
        }.to raise_error(StandardError) do |e|
          expect(e.instance_variable_get(:@binding_infos)).to be_nil
        end
      end
    end

    describe '.on_format' do
      let(:default_formatted_output) do
        EnhancedErrors.binding_infos_array_to_string(captured_bindings, :terminal)
      end

      after do
        EnhancedErrors.on_format = nil
      end

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
        EnhancedErrors.on_format do |formatted_string|
          '---whatever---'
        end
        result_with_hook = EnhancedErrors.format(captured_bindings)
        expect(result_with_hook).to eq('---whatever---')

        EnhancedErrors.on_format = nil
        result_without_hook = EnhancedErrors.format(captured_bindings)
        expect(result_without_hook).to eq(default_formatted_output)
      end
    end

    context 'global variables' do
      before(:each) do
        EnhancedErrors.enhance!(debug: false)
      end

      describe 'Global Variable Capture with Shared Skip List' do
        it 'captures new global variables when in debug mode, ignoring the skip list' do
          $variable_to_skip = 'should not be captured in debug mode as was present before enhance! call'
          EnhancedErrors.enhance!(debug: true)
          $variable_to_include = 'should be included as happened after'

          expect {
            raise 'Test exception with global variables in debug mode'
          }.to raise_error(StandardError) do |e|
            expect(e.message).to_not include('$variable_to_skip')
            expect(e.message).to include('$variable_to_include')
          end
        ensure
          $variable_to_skip = nil
          $variable_to_include = nil
        end
      end
    end
  end
end
