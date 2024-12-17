RSpec.describe EnhancedExceptionContext do

  let(:exception) { StandardError.new("Test exception") }

  before do
    EnhancedExceptionContext.clear_all
  end

  it 'stores context for an exception' do
    ctx = Context.new
    ctx.binding_infos << { detail: "Some info" }
    EnhancedExceptionContext.store_context(exception, ctx)

    retrieved_ctx = EnhancedExceptionContext.context_for(exception)
    expect(retrieved_ctx).to eq(ctx)
    expect(retrieved_ctx.binding_infos).to eq([{ detail: "Some info" }])
  end

  it 'clears context for a single exception' do
    ctx = Context.new
    ctx.binding_infos << { detail: "Some info" }
    EnhancedExceptionContext.store_context(exception, ctx)

    EnhancedExceptionContext.clear_context(exception)
    expect(EnhancedExceptionContext.context_for(exception)).to be_nil
  end

  it 'clears all stored contexts' do
    exc1 = StandardError.new("Exc1")
    exc2 = StandardError.new("Exc2")

    ctx1 = Context.new
    ctx1.binding_infos << { info: "Exc1 info" }
    EnhancedExceptionContext.store_context(exc1, ctx1)

    ctx2 = Context.new
    ctx2.binding_infos << { info: "Exc2 info" }
    EnhancedExceptionContext.store_context(exc2, ctx2)

    EnhancedExceptionContext.clear_all

    expect(EnhancedExceptionContext.context_for(exc1)).to be_nil
    expect(EnhancedExceptionContext.context_for(exc2)).to be_nil
  end
end
