Pod::Spec.new do |s|
  s.name             = 'lan_input'
  s.version          = '0.1.0'
  s.summary          = 'Native desktop input capture and injection for LAN Bridge.'
  s.description      = 'Explicitly enabled, permission-gated keyboard and mouse sharing between paired computers.'
  s.homepage         = 'https://example.invalid/lan-bridge'
  s.license          = { :type => 'Proprietary' }
  s.author           = { 'LAN Bridge contributors' => 'contributors@example.invalid' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'FlutterMacOS'
  s.platform = :osx, '10.15'
  s.swift_version = '5.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.frameworks = 'Cocoa', 'ApplicationServices'
end
