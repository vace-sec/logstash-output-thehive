Gem::Specification.new do |s|
  s.name          = 'logstash-output-thehive'
  s.version       = '0.1.0'
  s.licenses      = ['MIT']
  s.summary       = 'Sends events to a TheHive endpoint to create alerts'
  s.description   = 'This gem is a Logstash plugin required to be installed on top of the Logstash core pipeline using $LS_HOME/bin/logstash-plugin install gemname. This gem is not a stand-alone program'
  s.homepage      = 'https://github.com/vacesec/logstash-output-thehive'
  s.authors       = ['VACE SOC']
  s.email         = '<soc@vace.at>'
  s.require_paths = ['lib']

  # Files
  s.files = Dir['lib/**/*','spec/**/*','vendor/**/*','*.gemspec','*.md','CONTRIBUTORS','Gemfile','LICENSE','NOTICE.TXT']
   # Tests
  s.test_files = s.files.grep(%r{^(test|spec|features)/})

  # Special flag to let us know this is actually a logstash plugin
  s.metadata = { "logstash_plugin" => "true", "logstash_group" => "output" }

  # Gem dependencies
  s.add_runtime_dependency "logstash-core-plugin-api", "~> 2"
  s.add_runtime_dependency "logstash-mixin-http_client", "~> 6"
  s.add_runtime_dependency "logstash-codec-plain", "~> 3"
  s.add_development_dependency "logstash-devutils", "~> 1"
end
