module PoolParty
  class Chef < Base

    BOOTSTRAP_PACKAGES = %w( ruby ruby1.8-dev libopenssl-ruby1.8 rdoc
      ri irb build-essential wget ssl-cert 
      libxml-ruby zlib1g-dev libxml2-dev )
    BOOTSTRAP_PACKAGES_RUBYGEMS = %w( rubygems )
    BOOTSTRAP_RUBYGEMS_CMD = [
      "cd /tmp",
      "if [[ -f rubygems.1.3.6.tgz ]]; then rm -rf rubygems-1.3.6*; fi",
      "wget http://production.cf.rubygems.org/rubygems/rubygems-1.3.6.tgz",
      "tar xzvf rubygems-1.3.6.tgz",
      "cd rubygems-1.3.6",
      "ruby setup.rb",
      "cd /usr/bin",
      "ln -s gem1.8 gem"
   ].join('&&')

    BOOTSTRAP_GEMS = [ :chef ]

    # we dont specifically install these binaries, they installed by
    # packages and gems above, but we check for them
    BOOTSTRAP_BINS = %w( gem chef-solo chef-client )
    BOOTSTRAP_DIRS = %w( /var/log/chef /var/cache/chef /var/run/chef )

    # on ubuntu gems package generally is new enough, but on debian
    # lenny should be installed from a gem
    default_options( :quiet_bootstrap => true,
                     :rubygems_package => true
                     )

    def base_directory
      tmp_path/"etc"/"chef"
    end

    def compile!
      build_tmp_dir
    end

    def build_tmp_dir
      FileUtils.rm_rf base_directory
      FileUtils.mkdir_p base_directory   
    end

    def self.types
      return [:solo,:client]
    end
    
    def self.get_chef(type,cloud,&block)
      ("Chef" + type.to_s.capitalize).constantize(PoolParty).send(:new,type,:cloud => cloud,&block)
    end
    # Chef    
    
    def attributes(hsh={}, &block)
      @attributes ||= ChefAttribute.new(hsh, &block)
    end

    def override_attributes(hsh={}, &block)
      @override_attributes ||= ChefAttribute.new(hsh, &block)
    end


    # === Description
    #
    # Provides the ability to specify steps that can be
    # run via chef
    #
    # pool "mycluster" do
    #   cloud "mycloud" do
    #       
    #       on_step :download_install do
    #           recipe "myrecipes::download"
    #           recipe "myrecipes::install"
    #       end
    #
    #       on_step :run => :download_install do
    #           recipe "myrecipes::run"
    #       end
    #   end
    # end
    #
    # Then from the command line you can do
    #
    # cloud-configure --step=download_install 
    #
    # to only do the partial job or
    #
    # cloud-configure --step=run
    #
    # to do everything
    #
    def on_step action, &block
      if action.is_a? Hash
        t = action
        action = t.keys[0]
        depends = t.values[0]
      else
        depends = nil
      end
      change_attr :@_current_action, action do
        yield
        if depends
          # Merge the recipes of the dependency into
          # the current recipes
          _recipes(depends).each do |r|
            recipe r
          end
        end
      end
    end
    
    # Adds a chef recipe to the cloud
    #
    # The hsh parameter is inserted into the override_attributes.
    # The insertion is performed as follows. If
    # the recipe name = "foo::bar" then effectively the call is
    #
    # override_attributes.merge! { :foo => { :bar => hsh } }
    def recipe(recipe_name, hsh={})
      _recipes << recipe_name unless _recipes.include?(recipe_name)

      head = {}
      tail = head
      recipe_name.split("::").each do |key|
        unless key == "default"
          n = {}
          tail[key] = n
          tail = n
        end
      end
      tail.replace hsh

      override_attributes.merge!(head) unless hsh.empty?
    end
    
    def recipes(*recipes)
      recipes.each do |r|
        recipe(r)
      end
    end

    def node_run!(remote_instance)
      node_stop!(remote_instance)
      node_configure!(remote_instance)

      cmds = chef_cmd
      cmds = [cmds] unless cmds.respond_to? :each

      remote_instance.ssh(cmds.map{|c| c.strip.squeeze(' ')}, 
                          :env => gem_bin_envhash )
    end

    def node_stop!(remote_instance)
      remote_instance.ssh("[ -f /etc/init.d/chef-client ] && invoke-rc.d chef-client stop; killall -q chef-client chef-solo")
    end

    def node_configure!(remote_instance, quiet=quiet_bootstrap)
      cmds = node_configure_cmds
      return unless cmds && !cmds.empty?

      raise PoolParty::PoolPartyError.create("SSHError", "ssh went away") unless remote_instance.ssh_available?

      remote_instance.ssh(cmds,
                          :echo_command => !quiet, :env => gem_bin_envhash)
    end

    def node_configure_cmds
      nil
    end

    def bootstrap_bins
      BOOTSTRAP_BINS
    end

    def bootstrap_packages
      BOOTSTRAP_PACKAGES + 
        (rubygems_package ? BOOTSTRAP_PACKAGES_RUBYGEMS : [])
    end

    def bootstrap_rubygems_cmd
      rubygems_package ? nil : BOOTSTRAP_RUBYGEMS_CMD
    end

    def bootstrap_dirs
      BOOTSTRAP_DIRS
    end

    def bootstrap_gems(remote_instance)
      BOOTSTRAP_GEMS + remote_instance.bootstrap_gems
    end

    def node_bootstrapped?(remote_instance, quiet=quiet_bootstrap)
      # using which command instead of calling gem directly.  On
      # ubuntu, calling a command from package not installed
      # 'helpfully' prints message, which result confuses detection
      #
      cmds = []

      cmds << "which %s" % bootstrap_bins.join(' ')
      cmds << "dpkg -l %s " % bootstrap_packages.join(' ')
      cmds += bootstrap_gems(remote_instance).map do |gem_spec|
        gem, ver = gem_spec
        "gem search '^#{gem}$' | grep -v GEMS | wc -l | grep -q 1"
      end
      cmds += bootstrap_dirs.map{ |dir| "[[ -d #{dir} ]] " }

      if quiet
        cmds.map! { |cmd| cmd + " >/dev/null"} 
      end

      ssh_cmd = cmds.join('&&') + " && echo OK || echo MISSING"

      r = remote_instance.ssh(ssh_cmd,
                              :do_sudo => false, :echo_command => !quiet  )
      r.split("\n").to_a.last.chomp == "OK"
    end

    def node_bootstrap!(remote_instance, force=false, quiet=quiet_bootstrap)
      return if !force && node_bootstrapped?(remote_instance)

      gem_src='http://gems.opscode.com'

      cmds = []
      cmds +=
        [
         'apt-get update',
         'apt-get autoremove -y',
         'apt-get install -y %s' % bootstrap_packages.join(' '),
         bootstrap_rubygems_cmd,
         "gem source -l | grep -q #{gem_src} || gem source -a #{gem_src} "
        ]

      cmds += bootstrap_gems(remote_instance).map do |gem_spec| 
        gem, ver = gem_spec
        'gem install %s %s --no-rdoc --no-ri' % 
          [ ver ? "-v #{ver}" : '', gem ]
      end

      cmds << "apt-get install -y %s" % bootstrap_packages.join(' ')
      cmds << "mkdir -p %s" % bootstrap_dirs.join(' ')

      remote_instance.ssh(cmds.compact,
                          :do_sudo => true, :echo_command => !quiet  )

      # if we are using rubygems package, need to workaround for
      # gem_bin location
      if rubygems_package
        cmd = '[ -d "$ENV_BIN" ] && ln -sf $ENV_BIN/* /usr/local/bin'
        remote_instance.ssh(cmd,
                            :do_sudo => true, :echo_command => !quiet,
                            :env => gem_bin_envhash )
      end
    end

    
    def _recipes action = nil
      action = action.to_sym unless action.nil?
      @_recipes ||= {:default => [] }
      key = action || _current_action
      @_recipes[key] ||= []
    end

    private

    def _current_action
      @_current_action ||= :default
    end
    
    def chef_cmd

      if ENV["CHEF_DEBUG"]
        debug = "-l debug"
      else
        debug = ""
      end

      return <<-CMD
        PATH="$PATH:$GEM_BIN" #{chef_bin} -j /etc/chef/dna.json -c /etc/chef/client.rb -d -i 1800 -s 20 #{debug}
      CMD
    end

    def gem_bin_envhash
      envhash = {
        :GEM_BIN => %q%$(gem env | grep "EXECUTABLE DIRECTORY" | awk "{print \\$4}")%
      }
    end

    def method_missing(m,*args,&block)
      if cloud.respond_to?(m)
        cloud.send(m,*args,&block)
      else
        super
      end
    end
    
  end
end
