require 'chef/json_compat'
require 'chef/knife'
require 'chef/provisioning/convergence_strategy/install_sh'
require 'chef/provisioning/driver'
require 'chef/provisioning/transport/ssh'
require 'chef/provisioning/machine/unix_machine'
require 'oauth'
require 'oauth/signature/plaintext'
require 'readline'

module Chef::Provisioning
  class MAASDriver < Chef::Provisioning::Driver

    def self.from_url(maas_url, config)
      MAASDriver.new(maas_url, config)
    end

    def self.canonicalize_url(url, config)
      scheme, maas_url = url.split(':' , 2)
      if maas_url.nil? || maas_url == ''
        maas_url = config[:knife][:maas_site]
      end
      "maas:" + maas_url
    end

    def initialize(maas_url, config)
      super(maas_url, config)
    end

    def maas_url
      scheme, maas_url = driver_url.split(':', 2)
      maas_url
    end

    def prepare_access_token(oauth_token, oauth_token_secret, consumer_key, consumer_secret)

      site = File.join(maas_url,"api/1.0/")

      consumer = OAuth::Consumer.new( consumer_key,
                                      consumer_secret,
                                      {
                                        :site => site,
                                        :scheme => :header,
                                        :signature_method => "PLAINTEXT"
                                      })

      access_token = OAuth::AccessToken.new( consumer,
                                             oauth_token,
                                             oauth_token_secret
                                           )
      return access_token
    end

    def access_token
      maas_key = "#{locate_config_value(:maas_api_key)}"
      customer_key = maas_key.split(":")[0]
      customer_secret = ""
      token_key = maas_key.split(":")[1]
      token_secret = maas_key.split(":")[2]
      prepare_access_token(token_key, token_secret, customer_key, customer_secret)
    end

    def locate_config_value(key)
      key = key.to_sym
      config[:knife][key]
    end

    def post(path, op, options = nil)
      path = File.join('/', path, '/')
      request_options = { 'op' => op }
      request_options.merge!(options) if options
      response = access_token.request(:post, path, request_options)
      JSON.parse(response.body)
    end

    def get(path, op = nil, options = nil)
      path = File.join('/', path, '/')
      request_options = {}
      request_options['op'] = op if op
      request_options.merge!(options) if options
      response = access_token.request(:get, path, request_options)
      JSON.parse(response.body)
    end

    def allocate_machine(action_handler, machine_spec, machine_options)

      # If we don't have an associated node, acquire one.
      if !machine_spec.reference || !machine_spec.reference['system_id']
        action_handler.perform_action "Acquiring server #{machine_spec.name} with options #{machine_options}" do

          node = post("/nodes", :acquire, machine_options[:deploy_options])

          machine_spec.reference = {
            'driver_url' => driver_url,
            'driver_version' => MAAS_DRIVER_VERSION,
            'system_id' => node['system_id']
          }

          machine_spec.save(action_handler)
        end

      else
        # If we have a system_id, but it does not exist in MAAS or is not in an acquired state, report that to the user.
        node = get("/nodes/#{machine_spec.reference['system_id']}")
        if !node
          raise "Node with ID #{machine_spec.reference['system_id']} does not exist!"
        end
        if !node['owner']
          raise "Node with ID #{machine_spec.reference['system_id']} is not owned by anyone anymore!"
        end
      end

      print(".")
      sleep 30
      print(".")

      # If the node has not been deployed (if it is in READY state), we get it up and deployed
      node = get("/nodes/#{machine_spec.reference['system_id']}")
      if node['substatus'] == 10
        post("/nodes/#{machine_spec.reference['system_id']}", :start)
      end
    end

    def ready_machine(action_handler, machine_spec, machine_options)

      print(".")
      sleep 30
      print(".")

      system_id = machine_spec.reference['system_id']
      node = get("/nodes/#{machine_spec.reference['system_id']}")
      # If the machine is in a stopped state, we start it. TODO
      if node['substatus'] == 10
        post("/nodes/#{machine_spec.reference['system_id']}", :start)
      end

      # Wait for the machine to be started / deployed / whatever
      system_info = get("/nodes/#{machine_spec.reference['system_id']}")

      until system_info['netboot'] == false && system_info['power_state'] == 'on' do
        print(".")
        sleep @initial_sleep_delay ||= 10
        system_info = get("/nodes/#{system_id}/")
      end

      # Return the Machine object
      machine_for(machine_spec, machine_options)
    end

    def machine_for(machine_spec, machine_options, instance = nil)
      system_info = get("/nodes/#{machine_spec.reference['system_id']}")
      server_id = machine_spec.reference['server_id']
      bootstrap_ip_address = system_info["ip_addresses"][0]
      username = `whoami`.delete!("\n")
      ssh_options = {
        :auth_methods => ['publickey']
      }
      options = {
        :prefix => 'sudo ',
        :ssh_pty_enable => true
      }

      transport = Chef::Provisioning::Transport::SSH.new(bootstrap_ip_address, username, ssh_options, options, config)
      convergence_strategy = Chef::Provisioning::ConvergenceStrategy::InstallSh.new(machine_options[:convergence_options], {})

      sleep 45

      Chef::Provisioning::Machine::UnixMachine.new(machine_spec, transport, convergence_strategy)
    end

    def destroy_machine(action_handler, machine_spec, machine_options)
      if machine_spec.reference
        server_id = machine_spec.reference['server_id']
        action_handler.perform_action "Release machine #{server_id}" do
          post("/nodes/#{machine_spec.reference['system_id']}/", :release)
          machine_spec.reference = nil
          machine_spec.delete(action_handler)
        end
      end
    end
  end
end
