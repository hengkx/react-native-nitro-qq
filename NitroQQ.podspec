require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

Pod::Spec.new do |s|
  s.name         = "NitroQQ"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = package["homepage"]
  s.license      = package["license"]
  s.authors      = package["author"]
  s.source       = { :git => "https://github.com/tomxu/react-native-nitro-qq.git", :tag => "#{s.version}" }

  s.platforms = { :ios => "13.4" }
  s.swift_version = "5.9"

  s.source_files = [
    "ios/**/*.{swift,m,mm,h}",
    "cpp/**/*.{hpp,cpp}",
  ]
  s.exclude_files = "ios/Vendor/**/*"
  s.vendored_frameworks = "ios/Vendor/TencentOpenAPI.xcframework"
  s.resources = "ios/Vendor/TencentOpenApi_IOS_Bundle.bundle"

  s.frameworks = "CoreTelephony", "Security", "SystemConfiguration", "UIKit", "WebKit"
  s.libraries = "z", "c++"
  s.pod_target_xcconfig = {
    "OTHER_LDFLAGS" => "$(inherited) -ObjC -all_load",
  }

  load "nitrogen/generated/ios/NitroQQ+autolinking.rb"
  add_nitrogen_files(s)

  s.dependency "React-jsi"
  s.dependency "React-callinvoker"
  if respond_to?(:install_modules_dependencies)
    install_modules_dependencies(s)
  else
    s.dependency "React-Core"
  end
end
