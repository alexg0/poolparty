module PoolParty

  class BootstrapRule < Base
    attr_accessor :parent

    # actual attributes of the BootstrapRule
    attr_accessor :phase, :priority, :name, :owner_obj, :block

    # attributes of bootstrap rule:
    # phase - one of :compile, :bootstrap, :configure.
    # priority - range is between 0 and 100, default is 50.
    # name - name of the bootstrap rule
    # owner_obj - owner, which is object created this rule.  nil implies created rule
    def initialize(set,phase,priority,name,owner_obj,&block)
      self.class.check_phase phase
      self.class.check_priority priority

      @parent=set
      @phase=phase
      @priority = priority
      @name  = name
      @owner_obj = owner_obj
      @block = block
    end

    def cloud
      parent.cloud
    end

    def user? 
      ! owner_obj
    end

    def run(node)
      tmp_path = nil unless phase == :compile
      instance_eval { | | block.call(node) }
    end

    def <=>(other)
      to_sortable_a <=> other.to_sortable_a
    end
    
    #
    # helper methods, to be accessable to bootstrap block
    #
    def cloud_provider
      cloud.cloud_provider
    end

    def tmp_path
      cloud.tmp_path
    end


    # TODO: maybe provide access to cloud methods directly?

    # static methods
    def self.check_phase(*args)
      BootstrapSet.check_phase *args
    end

    def self.check_priority(*args)
      BootstrapSet.check_priority *args
    end


  protected
    # array use for sorting
    def to_sortable_a
      @sortable_a ||= [priority, user? ? 1 : 0, name]
    end

  end


  class BootstrapSet < Base

    unless defined? PHASES
      PHASES = [ :compile, :bootstrap, :configure ] 
      PRIORITY_RANGE = 0..100
      DEFAULT_PRIORITY = 50
    end

    attr_accessor :parent, :rules

    def initialize(parent)
      @parent = parent
    end

    def cloud
      parent
    end

    def register_bootstrap(phase,priority,name,owner_obj,&block)
      raise PoolPartyError.create("StandardError", 
                                  "Please provide a block of bootstraps") unless block

      # create BootstrapRule object first, since creating object,
      # check all args, including phase, saving us from checking phase
      # again
      priority = DEFAULT_PRIORITY unless priority
      phase = phase.to_sym unless phase.is_a? Symbol

      rule = BootstrapRule.new(self,phase,priority,name,owner_obj,&block)

      @rules ||= {}
      @rules[phase] ||= []
      @rules[phase] << rule
      rule
    end

    # Register user bootstrap for user.  Same as register_bootstrap,
    # other then no owner_obj is expected
    def register_user_bootstrap(phase,priority,name,&block)
      register_bootstrap(phase,priority,name,nil,&block)
    end

    def rules(phase)
      (@rules[phase.to_sym] || []).sort
    end

    # run bootstraps for node
    def run(phase,node,quiet=false)
      self.class.check_phase phase

      puts "----> Bootstraps (:#{phase}) for node: #{node.instance_id}"
      rules(phase).each do |rule| 
        rule.run(node)
      end
    end

    #
    # statics
    #
    # static methods
    def self.check_phase(phase)
      raise PoolParty::PoolPartyError.create(
        "BootstrapError",
        "phase must be one of :#{PHASES.join(',:')}") unless 
        PHASES.include?(phase)
    end

    def self.check_priority(priority)
      raise PoolParty::PoolPartyError.create(
        "BootstrapError",
        "priority must be one in range of :#{PRIORITY_RANGE}") unless 
        PRIORITY_RANGE.include?(priority)
    end

  end
end
