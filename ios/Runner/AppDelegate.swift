import Flutter
import UIKit
import DuanjuCore
import CFNetwork
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var keepAlivePlayer: AVAudioPlayer?
  private var keepAliveConfigured = false

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    ZgjEnsureCoreLinked()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// 静音音频保活：DLNA 投屏时电视自行拉流，本机仅需保持进程存活以继续提供局域网流代理。
  /// 熄屏后普通 App 会被挂起，播放静音音频可维持后台运行。
  private func beginBackgroundPlayback() {
    if !keepAliveConfigured {
      let session = AVAudioSession.sharedInstance()
      do {
        try session.setCategory(.playback, mode: .moviePlayback)
        try session.setActive(true)
        keepAliveConfigured = true
      } catch {
        keepAliveConfigured = false
      }
    }
    guard keepAliveConfigured, keepAlivePlayer == nil else { return }
    let silent = makeSilentWave()
    guard let player = try? AVAudioPlayer(data: silent) else { return }
    player.numberOfLoops = -1
    player.volume = 0
    player.prepareToPlay()
    player.play()
    keepAlivePlayer = player
  }

  private func endBackgroundPlayback() {
    keepAlivePlayer?.stop()
    keepAlivePlayer = nil
    guard keepAliveConfigured else { return }
    keepAliveConfigured = false
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  /// 生成约 0.5 秒的 8kHz 单声道静音 WAV，避免引入额外音频资源。
  private func makeSilentWave() -> Data {
    let sampleRate = 8000
    let seconds = 1
    let samples = sampleRate * seconds
    let dataSize = samples * 2
    var data = Data()
    func append(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
    func append32(_ value: UInt32) {
      withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    func append16(_ value: UInt16) {
      withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    append("RIFF")
    append32(UInt32(36 + dataSize))
    append("WAVE")
    append("fmt ")
    append32(16)
    append16(1)
    append16(1)
    append32(UInt32(sampleRate))
    append32(UInt32(sampleRate * 2))
    append16(2)
    append16(16)
    append("data")
    append32(UInt32(dataSize))
    data.append(Data(count: dataSize))
    return data
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "BackgroundPlayback") {
      let channel = FlutterMethodChannel(name: "duanju/background", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { [weak self] call, result in
        switch call.method {
        case "beginPlayback":
          self?.beginBackgroundPlayback()
          result(self?.keepAlivePlayer != nil)
        case "endPlayback":
          self?.endBackgroundPlayback()
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "DeviceSettings") {
      let channel = FlutterMethodChannel(name: "duanju/device", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        guard call.method == "systemProxy" else {
          result(FlutterMethodNotImplemented)
          return
        }
        let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] ?? [:]
        func address(_ prefix: String) -> String {
          guard (settings["\(prefix)Enable"] as? NSNumber)?.boolValue == true,
                let host = settings["\(prefix)Proxy"] as? String,
                let port = settings["\(prefix)Port"] as? NSNumber,
                !host.isEmpty, port.intValue > 0 else { return "" }
          let name = host.contains(":") ? "[\(host)]" : host
          return "http://\(name):\(port.intValue)"
        }
        let http = address("HTTP")
        let https = address("HTTPS")
        result(["http": http, "https": https.isEmpty ? http : https,
                "bypass": settings["ExceptionsList"] as? [String] ?? [],
                "pac": (settings["ProxyAutoConfigEnable"] as? NSNumber)?.boolValue == true])
      }
    }
  }
}
