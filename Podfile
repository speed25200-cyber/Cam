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
    end

    # Resource bundles have no signing identity of their own and fail the build
    # when Xcode tries to sign them. Frameworks are deliberately left signable:
    # they are re-signed during the app's embed phase, and disabling it there
    # produces an archive App Store Connect rejects.
    if target.respond_to?(:product_type) && target.product_type == 'com.apple.product-type.bundle'
      target.build_configurations.each do |config|
        config.build_settings['CODE_SIGNING_ALLOWED'] = 'NO'
      end
    end
  end
end
