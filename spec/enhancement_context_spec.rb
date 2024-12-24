require_relative '../lib/enhanced_errors'
require_relative '../lib/enhanced/exception'

RSpec.describe Enhanced::ExceptionContext do

  let(:exception) { StandardError.new("Test exception") }


  before do
    Enhanced::ExceptionContext.clear_all
  end

  it 'stores context for an exception' do
    ctx = Enhanced::Context.new
    ctx.binding_infos << { detail: "Some info" }
    Enhanced::ExceptionContext.store_context(exception, ctx)

    retrieved_ctx = Enhanced::ExceptionContext.context_for(exception)
    expect(retrieved_ctx).to eq(ctx)
    expect(retrieved_ctx.binding_infos).to eq([{ detail: "Some info" }])
  end

  it 'clears context for a single exception' do
    ctx = Enhanced::Context.new
    ctx.binding_infos << { detail: "Some info" }
    Enhanced::ExceptionContext.store_context(exception, ctx)

    Enhanced::ExceptionContext.clear_context(exception)
    expect(Enhanced::ExceptionContext.context_for(exception)).to be_nil
  end

  it 'clears all stored contexts' do
    exc1 = StandardError.new("Exc1")
    exc2 = StandardError.new("Exc2")

    ctx1 = Enhanced::Context.new
    ctx1.binding_infos << { info: "Exc1 info" }
    Enhanced::ExceptionContext.store_context(exc1, ctx1)

    ctx2 = Enhanced::Context.new
    ctx2.binding_infos << { info: "Exc2 info" }
    Enhanced::ExceptionContext.store_context(exc2, ctx2)

    Enhanced::ExceptionContext.clear_all

    expect(Enhanced::ExceptionContext.context_for(exc1)).to be_nil
    expect(Enhanced::ExceptionContext.context_for(exc2)).to be_nil
  end
end
