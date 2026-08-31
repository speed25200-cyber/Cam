platform :ios, '15.0'
use_frameworks!

target 'CamControl' do
  # RTSP/H.264/H.265 live playback — iOS has no native RTSP support in AVFoundation,
  # so we rely on the same engine most third-party camera apps use.
  pod 'MobileVLCKit', '~> 3.6'
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
    end
  end
end
