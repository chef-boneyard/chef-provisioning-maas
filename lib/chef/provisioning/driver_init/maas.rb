require 'chef/provisioning/maas_driver'

Chef::Provisioning.register_driver_class('maas', Chef::Provisioning::MAASDriver)
