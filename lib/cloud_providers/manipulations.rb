module CloudProviders

  # Manipulations over a connection.
  # Destructive manipulations, like changing the machine hostname.
  #
  module Manipulations

    def hostname
      @hostname ||= ssh("hostname -f").chomp
    end

    def change_hostname(fqdn, ip='127.0.1.1')
      name, domain = fqdn.split('.', 2)
      # raise "dont use dots in hostnames" if name =~ /\./

      etc_hosts = '/etc/hosts'
      cmds = 
        ['echo "%s" > /etc/hostname' % name,
         '[ -f %s.orig ] || cp %s %s.org' % ([etc_hosts]*3),
         'perl -i.bak -ne "print unless /^%s/" %s' % [ip, etc_hosts],
         'echo "%s %s %s" >> /etc/hosts' % [ip, fqdn, name],
         'hostname %s' % name
        ]

      # following gets run as one command. Avoids sudo complaints
      # about "unable to resolve host" new hostname
      ssh cmds.join('&&')
    ensure
      @hostname = nil
    end
  end
end
