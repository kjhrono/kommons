Pod::Spec.new do |s|
  s.name             = 'device_key'
  s.version          = '0.1.0'
  s.summary          = 'A non-exportable device key in the Secure Enclave.'
  s.description      = 'A non-exportable device key in the Secure Enclave.'
  s.homepage         = 'https://mediasart.com'
  s.license          = { :type => 'Proprietary' }
  s.author           = { 'kjhrono' => 'kjhrono' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform         = :ios, '13.0'
  s.swift_version    = '5.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
