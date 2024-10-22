require './lib/enhanced_errors'
require 'awesome_print' # Optional, for better output

EnhancedErrors.enhance!

def foo
  begin
    myvar = 0
    @myinstance = 10
    foo = @myinstance / myvar
  rescue => e
    puts e.message
  end
end

foo
