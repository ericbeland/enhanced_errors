# EnhancedErrors

## Overview

**EnhancedErrors** is a pure Ruby gem that enhances exceptions by capturing variables and their values from the scope where the error was raised.

**EnhancedErrors** leverages Ruby's built-in [TracePoint](https://ruby-doc.org/core-3.1.0/TracePoint.html) feature to provide detailed context for exceptions, making debugging easier without significant performance overhead.

When an exception is raised, EnhancedErrors captures the surrounding context.  It works like this:
<br>

#### Enhanced Exception In Code:

```ruby

require 'enhanced_errors'
require 'awesome_print' # Optional, for better output

# Enable capturing of variables at exception at raise-time. The .captured_variables method
# is added to all Exceptions and gets populated with in-scope variables and values on `raise`

EnhancedErrors.enhance_exceptions!

def foo
  begin
    myvar = 0
    @myinstance = 10
    foo = @myinstance / myvar
  rescue => e
    puts e.captured_variables
  end
end

foo
```

##### Output:

<img src="./doc/images/enhanced-error.png" style="height: 215px; width: 429px;"></img>
<br>


#### Enhanced Exception In Specs:

```ruby
describe 'sees through' do

  let(:the_matrix) { 'code rains, dramatically' }

  before(:each) do
    @spoon = 'there is no spoon'
  end

  it 'the matrix' do
    #activate memoized item
    the_matrix
    stop = 'bullets'
    raise 'No!'
  end
end
```

#### Output:

<img src="./doc/images/enhanced-spec.png" style="height: 369px; width: 712px;"></img>

# RSpec Setup

The simplest way to get started with EnhancedErrors is to use it for RSpec
exception capturing. To get variable output into RSpec, the approach below
enables capturing, but also gives nice output by formatting the failure message
with the variable capture.

The advantage of this approach is that it is only active for your spec runs.
This approach is ideal for CI and local testing because it doesn't make
any changes that should bleed through to production--it doesn't enhance
exceptions except those that pass by during the RSpec run.

```ruby

RSpec.configure do |config|
  config.before(:example) do |_example|
    EnhancedErrors.start_rspec_binding_capture
  end

  config.after(:example) do |example|
    example.metadata[:expect_binding] = EnhancedErrors.stop_rspec_binding_capture
    EnhancedErrors.override_exception_message(example.exception, example.metadata[:expect_binding])
  end
end
```

## TODO: Minitest


## Enhancing .message

EnhancedErrors can also append the captured variable description into the Exception's
.message method output if the override_messages argument is true. 

This can be very convenient as it lets you capture and diagnose 
the context of totally unanticipated exceptions without modifying all your error handlers. 

The downside to this approach is that if you have expectations in your tests/specs 
around exception messages, those may break. Also, if you are doing something with the error messages, 
like storing them in a database, they could be *much* longer and that may pose an issue.

Ideally, use exception.captured_variables instead.

```ruby
EnhancedErrors.enhance_exceptions!(override_messages: true)
```


## Features

- **Pure Ruby**: No external dependencies, C extensions, or C API calls.
- **Customizable Output**: Supports multiple output formats (`:json`, `:plaintext`, `:terminal`).
- **Flexible Hooks**: Redact or modifying captured data via the `on_capture` hook. Update the final string with on_format.
- **Environment-Based Defaults**: For Rails apps, automatically adjusts settings based on the environment (`development`, `test`, `production`, `ci`).
- **Pre-Populated Skip List**: Comes with predefined skip lists to exclude irrelevant variables from being captured.
- **Capture Levels**: Supports `info` and `debug` levels, where `debug` level ignores the skip lists for more comprehensive data capture.
- **Capture Types**: Captures variables from the first `raise` and the last `rescue` for an exception by default.
- **No dependencies**:  EnhancedErrors does not ___require___ any dependencies--it uses [awesome_print](https://github.com/awesome-print/awesome_print) for nicer output if it is installed and available.
- **Lightweight**: Minimal performance impact, as tracing is only active during exception raising.

EnhancedErrors has a few big use-cases:

* **Catch Data-driven bugs**. For example, if, while processing a 10 gig file, you get an error, you can't just re-run the code with a debugger.
You also can't just print out all the data, because it's too big. You want to know what the data was the cause of the error.
Ideally, without long instrument-re-run-fix loops. If your logging didn't capture the data, normally, you'd be stuck. 

* **Debug** a complex application erroring deep in the stack when you can't tell where the error originates.

* **Reduce MTTR** Reduce mean time to resolution.

* **Faster CI -> Fix loop**. When a bug happens in CI, usually there's a step where you first reproduce it locally.
  EnhancedErrors can help you skip that step.

* **Faster TDD**. In general, you can skip the add-instrumentation step and jump to the fix. Usually, you won't have to re-run to see an error.

* **Heisenbugs** - bugs that disappear when you try to debug them. EnhancedErrors can help you capture the data that causes the bug before it disappears.

* **Unknown Unknowns** - you can't pre-emptively log variables from failure cases you never imagined.

* **Cron jobs** and **daemons** - when it fails for unknown reasons at 4am, check the log and fix--it probably has what you need. Note that 

## Installation

Add this line to your `Gemfile`:

```ruby
gem 'enhanced_errors'
```

Then execute:

```shell
$ bundle install
```

Or install it yourself with:

```shell
$ gem install enhanced_errors
```

## Basic Usage

To enable EnhancedErrors, call the `enhance_exceptions!` method:

```ruby
# For a rails app, you may put this in an initializer, or spec_helper.rb
# ex:  config/initializers/enhanced.rb
# you should immediately see nice errors with variables in your logs
 
require 'awesome_print' # Optional, for better output
EnhancedErrors.enhance_exceptions!(override_messages: true)


```

The approach above activates the TracePoint to start capturing exceptions and their surrounding context.
It also overrides the .message to have the variables.

If modifying your exception handlers is an option, it is better *not* to use
override_messages: true, but instead just use the exception.captured_variables, which is
a string describing what was found, that is available regardless. 

Note that a minimalistic approach is taken to generating the string--if no qualifying variables were present, you won't see any message!

### Configuration Options

You can pass configuration options to `enhance_exceptions!`:

```ruby

EnhancedErrors.enhance_exceptions!(enabled: true, max_length: 2000) do
  # Additional configuration here
  add_to_skip_list :@instance_variable_to_skip, :local_to_skip
end

```
- `add_to_skip_list`: Variables to ignore, as symbols. ex:  :@instance_variable_to_skip, :local_to_skip`
- `enabled`: Enables or disables the enhancement (default: `true`).
- `max_length`: Sets the maximum length of the captured_variables string (default: `2500`).

Currently, the first `raise` exception binding is presented. 
This may be changed in the future to allow more binding data to be presented.


### Environment-Based Defaults

EnhancedErrors adjusts its default settings based on the environment:

- **Development/Test**:
    - Default Output format: `:terminal`
    - Terminal Color output: Enabled
- **Production**:
    - Output format: `:json`
    - Terminal Color output: Disabled
- **CI Environment**:
    - Output format: `:plaintext`
    - Color output: Disabled

The environment is determined by `ENV['RAILS_ENV']`, `ENV['RACK_ENV']`, or detected CI environment variables like:
- `CI=true`

### Output Formats

You can customize the output format:

- **`:json`**: Outputs the captured data in JSON format.
- **`:plaintext`**: Outputs plain text without color codes.
- **`:terminal`**: Outputs text with terminal color codes.

Example:

```ruby
EnhancedErrors.format(captured_bindings, :json)
```

### Customizing Data Capture

#### Using `on_capture`

The `on_capture` hook allows you to modify or redact data as it is captured. For each captured binding
it yields out a hash with the structure below. Modify it as needed and return the modified hash.

```ruby 
{
  source: source_location,
  object: Object source of error,
  library: true or false,
  method_and_args: method_and_args,
  variables: {
    locals: locals,
    instances: instances,
    lets: lets,
    globals: globals
  },
  exception: exception.class.name,
  capture_event: capture_event # 'raise' or 'rescue'
}
```


```ruby
EnhancedErrors.on_capture do |binding_info|
  # Redact sensitive data
  if binding_info[:variables][:locals][:password]
    binding_info[:variables][:locals][:password] = '[REDACTED]'
  end
  binding_info  # Return the modified binding_info
end
```


#### Using `eligible_for_capture`

The `eligible_for_capture` hook yields an Exception, and allows you to decide whether you want to capture it or not.
By default, all exceptions are captured. When the block result is true, the error will be captured.
Error capture is relatively cheap, but ignoring errors you don't care about makes it almost totally free.
One use-case for eligible_for_capture is to run a string or regexp off a setting flag, which 
lets you turn on and off what you capture without redeploying.

```ruby 
EnhancedErrors.eligible_for_capture do |exception|
  exception.class.name == 'ExceptionIWantTOCatch'
end


```

#### Using `on_format`

`on_format` is the last stop for the message string that will be `exception.captured_variables`.

Here it can be encrypted, rewritten, or otherwise modified.


```ruby
EnhancedErrors.on_format do |formatted_string|
  "---whatever--- #{formatted_string} ---whatever---"
end

```


#### Applying a Variable Skip List

EnhancedErrors comes with predefined skip lists to exclude sensitive or irrelevant variables. 
By default, the skip list is used to remove a lot of framework noise from Rails and RSpec.
You can add additional variables to the skip list as needed:

```ruby
 
EnhancedErrors.enhance_exceptions! do
  add_to_skip_list :@variable_to_skip
end

```

The skip list is pre-populated with common variables to exclude and can be extended based on your application's requirements. 


#### Capture Rules

These exceptions are always ignored:

```ruby
SystemExit NoMemoryError SignalException Interrupt
ScriptError LoadError NotImplementedError SyntaxError
RSpec::Expectations::ExpectationNotMetError
RSpec::Matchers::BuiltIn::RaiseError
SystemStackError Psych::BadAlias
```

While this is close to "Things that don't descend from StandardError", it's not exactly that.

In Info mode, variables starting with @_ are also ignored.


### Capture Levels

EnhancedErrors supports different capture levels to control the verbosity of the captured data:

- **Info Level**: Respects the skip list, excluding predefined sensitive or irrelevant variables. Global variables are ignored.
- **Debug Level**: Ignores the skip lists, capturing all variables including those typically excluded and global variables.
  Global variables are only captured in debug mode, and they exclude the default Ruby global variables.

**Default Behavior**: By default, `info` level is used, which excludes variables in the skip list to protect sensitive information. In `debug` mode, the skip lists are ignored to provide more comprehensive data, which is useful during development but should be used cautiously to avoid exposing sensitive data.
The info mode is recommended.


### Capture Types

EnhancedErrors differentiates between two types of capture events:

- **`raise`**: Captures the context when an exception is initially raised.
- **`rescue`**: Captures the context when an exception is last rescued.

**Default Behavior**: By default, EnhancedErrors starts with rescue capture off.
The `rescue` exception is only available in Ruby 3.2+ as it was added to TracePoint events in Ruby 3.2.
If enabled, it returns the first `raise` and the last `rescue` event for each exception. 


### Example: Redacting Sensitive Information

```ruby
EnhancedErrors.on_capture do |binding_info|
  sensitive_keys = [:password, :ssn, :health_info]
  sensitive_keys.each do |key|
    if binding_info[:variables][:locals][key]
      binding_info[:variables][:locals][key] = '[REDACTED]'
    end
  end
  binding_info
end
```

## How It Works

EnhancedErrors uses Ruby's `TracePoint` to listen for `:raise` and `:rescue` events. 
When an exception is raised or rescued, it captures:

- **Local Variables**: Variables local to the scope where the exception occurred.
- **Instance Variables**: Instance variables of the object.
- **Method and Arguments**: The method name and its arguments.
- **Let Variables**: RSpec let variables, if applicable. Only memoized (evaluated) let variables are captured.
- **Global Variables**: Global variables, in debug mode.

The captured data includes a `capture_event` field indicating whether the data was captured during a `raise` or `rescue` event. By default, EnhancedErrors returns the first `raise` and the last `rescue` event for each exception, providing a clear trace of the exception lifecycle.

The captured data is available in .captured_variables, to provide context for debugging.

* EnhancedErrors does not persist captured data--it only keep it in memory for the lifetime of the exception.
* There are benchmarks around Tracepoint in the benchmark folder. Targeted tracepoints
seem to be very cheap--as in, you can hit them ten thousand+ times a second
without heavy overhead.
* 

## Awesome Print

EnhancedErrors automatically uses the [awesome_print](https://github.com/awesome-print/awesome_print) 
gem to format the captured data, ___if___ it is installed and available.
If not, error enhancement will work, but the output may be less pretty (er, awesome).
AwesomePrint is not required directly by EnhancedErrors, so you will need to add it to your Gemfile 
if you want to use it.

```ruby
gem 'awesome_print'
```


## Alternatives

Why not use:

[binding_of_caller](https://github.com/banister/binding_of_caller) or [Pry](https://github.com/pry/pry) or [better_errors](https://github.com/BetterErrors/better_errors)?

First off, these gems are, I cannot stress this enough, a-m-a-z-i-n-g!!! I use them every day--kudos to their creators and maintainers!

This is intended for different use-cases. In sum, the goal of this gem is an every-day driver for __non-interactive__ variable inspection. 

With EnhancedErrors is that I want extra details when I run into a problem I __didn't anticipate ahead of time__.
To make that work, it has to be able to safely be 'on' all the time, and it has to gather the data in
a way I naturally will see it without requiring extra preparation I obviously didn't know to do.

- That won't interrupt CI, but also, that lets me know what happened without reproduction
- That could, theoretically, also be fine in production (if data security, redaction, access, and encryption concerns were all addressed--Ok, big
list, but another option is to selectively enable targeted capture)
- Has decent performance characteristics
- **Only** becomes active in exception raise/rescue scenarios

This gem could have been implemented using binding_of_caller, or the gem it depends on, [debug_inspector](https://rubygems.org/gems/debug_inspector/versions/1.1.0?locale=en). 
However, the recommendation is not to use those in production as they use C API extensions. This doesn't. This selectively uses 
Ruby's TracePoint binding capture very narrowly with no other C API or dependencies, and only to target Exceptions--not to allow universal calls to the prior binding. It doesn't work as a debugger, but that also means it can, with care, operate safely in a narrow scope--becoming active only when exceptions are raised.


## Performance Considerations

- **Minimal Overhead**: Since TracePoint is only activated during exception raising and rescuing, the performance impact is negligible during normal operation. (Benchmark included)

- **TBD**: Memory considerations. This does capture data when an exception happens. EnhancedErrors hides under the bed when it sees **NoMemoryError**.

- **Goal: Production Safety**: The gem is designed to, eventually, be made safe for production use, giving you valuable insights without compromising performance.
I would not enable it in production *yet*.

## Contributing

Bug reports and pull requests are welcome on GitHub at [https://github.com/your_username/enhanced_errors](https://github.com/your_username/enhanced_errors).

## License

The gem is available as open-source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

