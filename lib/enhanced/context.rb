module Enhanced
  class Context
    attr_accessor :binding_infos

    def initialize
      @binding_infos = []
    end
  end
end
