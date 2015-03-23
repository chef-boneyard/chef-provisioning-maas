$:.unshift(File.dirname(__FILE__) + '/lib')
require 'chef/provisioning/maas_driver/version'

Gem::Specification.new do |s|
  s.name = 'chef-provisioning-maas'
  s.version = Chef::Provisioning::MAAS_DRIVER_VERSION
  s.platform = Gem::Platform::RUBY
  s.extra_rdoc_files = ['README.md', 'LICENSE' ]
  s.summary = 'Provisioner for creating MAAS in Chef Provisioning.'
  s.description = s.summary
  s.author = 'JJ Asghar'
  s.email = 'jj@chef.io'
  s.homepage = 'https://github.com/chef-partners/chef-provisioning-maas'

  s.add_dependency 'chef', '>= 12.0.0'
  s.add_dependency 'oauth'

  s.add_development_dependency 'rspec', '~> 3.0'
  s.add_development_dependency 'rake'
  s.add_development_dependency 'pry'

  s.bindir       = "bin"
  s.executables  = %w( )

  s.require_path = 'lib'
  s.files = %w(Rakefile LICENSE README.md) + Dir.glob("{distro,lib,tasks,spec}/**/*", File::FNM_DOTMATCH).reject {|f| File.directory?(f) }
end
