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

def baz
  i.dontexist
end

def boo
    seeme = 'youshould'
    baz
  rescue => e
    puts e.message
end


puts "\n--- Example with raise ---\n\n\n"

foo

puts "\n--- Example with raise and rescue (requires ruby 3.2 or greater to see rescue) ---\n\n\n"

boo
