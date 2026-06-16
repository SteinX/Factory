Pod::Spec.new do |s|
  s.name         = "Factory"
  s.version      = "3.2.0"
  s.summary      = "A Modern Dependency Injection / Service Locator framework for Swift on iOS."
  s.homepage     = "https://github.com/hmlongco/Factory"
  s.license      = "MIT"
  s.author       = "Michael Long"
  s.source       = { :git => "https://github.com/hmlongco/Factory.git", :tag => "#{s.version}" }
  s.source_files  = "Sources/FactoryKit/**/*.swift"
  s.resource_bundles = { "Factory" => "Sources/FactoryKit/**/*.xcprivacy" }
  s.swift_version = '6.0'

  s.ios.deployment_target = "13.0"
  s.ios.framework  = 'UIKit'

  s.osx.deployment_target = "10.15"
  s.osx.framework  = 'AppKit'
end
