Pod::Spec.new do |s|
  s.name             = 'palmtunes_hands'
  s.version          = '1.0.0'
  s.summary          = 'Hand landmark tracking for Palm Tunes on iOS.'
  s.description      = 'Runs the MediaPipe Hand Landmarker on camera frames sent from Flutter.'
  s.homepage         = 'https://example.com'
  s.license          = { :type => 'MIT' }
  s.author           = { 'Palm Tunes' => 'none@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.dependency 'MediaPipeTasksVision'
  s.platform         = :ios, '15.0'
  s.swift_version    = '5.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
