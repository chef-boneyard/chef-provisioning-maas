# chef-provisioning-maas

An implementation of the MAAS driver for chef-provisioning.

An example of the recipe you can use:

```ruby
# coding: utf-8
require 'chef/provisioning'

with_driver 'maas'
Chef::Config.knife[:maas_site] = 'http://10.0.1.138/MAAS/'
Chef::Config.knife[:maas_api_key] = 'zmY4nQFAKE2EmfPP:RkDgWsAPI_KEYnfnKkG6:VBnvv3IS_HERE_gJ7MGSRkUX84npnY9Jg'

machine 'node1' do
  recipe 'base'
  chef_environment '_default'
  machine_options {
      deploy_options: {
      zone: zone2
    }
  }
  converge true
end
```
