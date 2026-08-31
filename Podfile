platform :ios, '17.0'
use_frameworks!

target 'CamControl' do
  # RTSP with H.264/H.265 decoding. AVFoundation cannot open RTSP at all, so this
  # is the same engine every third-party camera app ends up shipping.
  pod 'MobileVLCKit', '~> 3.6'
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '17.0'
      # CocoaPods targets inherit the workspace's signing otherwise, which breaks
      # local builds on a free Apple developer account.
      config.build_settings['CODE_SIGNING_ALLOWED'] = 'NO'
    end
  end
end
