require "open3"

module CloudProviders
  module Connections
        
    # hostname or ip to use when running remote commands
    def host(n=nil)
      if n.nil? 
        @host ||= dns_name
      else
        @host = n
      end
    end

    def short_hostname
      dns_name.sub(/\..+$/, '')
    end
    
    # sockets need to be closed, or sshd runs out of available
    # concurrent sessions.  See sshd_config(5) under MaxStartups.
    # Closing socket to avoid holding ssh connection open.
    def ping_port(host, port=22, retry_times=400)
      connected = false
      retry_times.times do |i|
        begin
          socket = TCPSocket.new(host, port)
          connected = true
          break
        rescue Exception => e
          sleep(2)
        ensure
          socket.close if socket
        end
      end
      connected
    end
    
    def run(commands, o={})
      ssh(commands)
    end
  
    def shell_escape(str)
      String(str).gsub(/(?=["'\\$])/n, '\\').
        gsub(/\n/, "'\n'").
        sub(/^$/, "''")
    end

    def ssh( commands=[], extra_ssh_ops={})
      # commands can be single commands, as well as array
      commands = [commands].flatten

      # Get the environment hash out of
      # the extra_ssh_ops and then delete
      # the element
      ssh_error_msg="SSH is not available for this node. perhaps you need to authorize it?"
      raise PoolParty::PoolPartyError.create("SSHError", ssh_error_msg) unless ssh_available?
      env = extra_ssh_ops[:env] || {}
      extra_ssh_ops.delete :env

      # default to do_sudo=true if non-root user
      # never sudo if already root
      do_sudo = true
      if extra_ssh_ops.has_key? :do_sudo
        do_sudo = extra_ssh_ops[:do_sudo] 
        extra_ssh_ops.delete :do_sudo
      end
      do_sudo = false if user == 'root'

      if extra_ssh_ops.has_key? :echo_command
        echo_command = extra_ssh_ops[:echo_command] 
        extra_ssh_ops.delete :echo_command
      end

      envstring = env.collect {|k,v| "#{k}=#{v}"}.join ' && '
      envstring += " && " unless envstring.size == 0
      ssh_string = "ssh #{user}@#{host} #{ssh_options(extra_ssh_ops)}"

      if commands.empty?
        #TODO: replace this with a IO.popen call with read_nonblocking to show progress, and accept input
        Kernel.system(ssh_string)
      else
        r = nil
        commands.each do |command|

          cmd = "#{envstring}#{command}" 
          if do_sudo
            sudocmd = %Q% sudo sh -c "#{shell_escape cmd}" % 
          else
            sudocmd = cmd
          end

          escaped_cmd = shell_escape(sudocmd)
          ssh_cmd = ssh_string + %Q% "#{escaped_cmd}"% 

          puts "ssh command: %s" % escaped_cmd if echo_command
          puts "ssh_full: %s" % ssh_cmd if echo_command == :debug
          r = system_run ssh_cmd
        end
        r
      end
    end

    # remove hostname and corresponding from known_hosts file.  Avoids
    # warning when reusing hostnames, elastic_ip, and (in less likely
    # case) if amazon reassigns ips.  By default removes both
    # dns_name, first part of the hostname, and ip
    def ssh_cleanup_known_hosts!(hosts=[host, short_hostname, public_ip])
      hosts.flatten.compact.each do |name|
        system_run "ssh-keygen -R %s 2>/dev/null" % name
      end
    end
    
    # Take a hash of options and join them into a string, combined with default options.
    # Default options are -o StrictHostKeyChecking=no -i keypair.full_filepath -l user
    # {'-i'=>'keyfile, '-l' => 'fred' } would become
    # "-i keyfile -o StrictHostKeyChecking=no -i keypair.to_s -l fred"
    def ssh_options(opts={})
      return @ssh_options if @ssh_options && opts.empty?
      ssh_opts = {"-i" => keypair.full_filepath,
           "-o" =>"StrictHostKeyChecking=no",
           }.merge(opts)
      @ssh_options = ssh_opts.collect{ |k,v| "#{k} #{v}"}.join(' ')
    end
    
    def rsync( opts={} )
      raise StandardError.new("You must pass a :source=>uri option to rsync") unless opts[:source]
      ssh_error_msg="SSH is not available for this node. perhaps you need to authorize it?"
      raise PoolParty::PoolPartyError.create("SSHError", ssh_error_msg) unless ssh_available?
      destination_path = opts[:destination] || opts[:source]

      excludes = opts[:exclude] || []
      excludes = [excludes] unless excludes.respond_to? :each
      
      # alexg: local rsync runs as plain user, and -a without --no-o --no-g
      # would chown /etc, /tmp  and other included directories away from root.
      # makes for 'strange' behavior, to say the least
      rsync_opts = opts[:rsync_opts] || '-va --no-o --no-g'
      rsync_opts += %q% --rsync-path="sudo rsync"% unless user=="root"
      rsync_opts += %q% --exclude=.svn --exclude=.git --exclude=.cvs %
      rsync_opts += excludes.map {|path| '--exclude="%s"' % path }.join ' '
      cmd_string =  "rsync -L  -e 'ssh #{ssh_options}' #{rsync_opts} #{opts[:source]}  #{user}@#{host}:#{destination_path}"
      out = system_run(cmd_string, :quiet => true)
      out
    end
    
    def scp(opts={})
      source = opts[:source]
      destination_path = opts[:destination] || opts[:source]
      raise StandardError.new("You must pass a local_file to scp") unless source
      scp_opts = opts[:scp_opts] || ""
      cmd_string = "scp #{ssh_options(scp_opts)} #{source} #{user}@#{host}:#{destination_path}"
      out = system_run(cmd_string)
      out
    end
    
    private
    
    # Execute command locally.
    # This method is mainly broken out to ease testing in the other methods
    # It opens the 3 IO outputs (stdin, stdout, stderr) and print the output out
    # as the command runs, unless the quiet option is passed in
    #
    # TODO: this should to be replaced by systemu gem, since systemu
    # handles reading stderr cleaner.  Most likely below implementation will
    # hang when stderr buffer fills up.
    def system_run(cmd, o={})
      opts = {:quiet => false, :sysread => 1024}.merge(o)
      buf = ""
      # puts("Running command: #{cmd}")
      Open3.popen3(cmd) do |stdin, stdout, stderr|
        begin
          stdin.close
          while (chunk = stdout.readpartial(opts[:sysread]))
            buf << chunk
            unless chunk.nil? || chunk.empty?
              if not opts[:quiet]
                $stdout.write(chunk) #if debugging? || verbose?
              end
            end
          end
          err = stderr.readlines
          $stderr.write_nonblock(err)
        rescue SystemCallError => error
          err = stderr.readlines
          $stderr.write_nonblock(err)
        rescue EOFError => error
          err = stderr.readlines
          $stderr.write_nonblock(err)
          # used to do nothing
        end
      end
      unless $?.success?
        warn "Failed sshing. Check ~/.poolparty/ssh.log for details"
      end
      buf
    end
    
  end
end
