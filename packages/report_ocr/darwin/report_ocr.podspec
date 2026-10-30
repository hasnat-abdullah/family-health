Pod::Spec.new do |s|
  s.name             = 'report_ocr'
  s.version          = '0.0.1'
  s.summary          = 'On-device text recognition for medical reports (Apple Vision).'
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Medi Archive' => 'noreply@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'report_ocr/Sources/report_ocr/**/*.swift'
  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'
  s.ios.deployment_target = '15.0'
  s.osx.deployment_target = '12.0'
  s.frameworks = 'Vision'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end
