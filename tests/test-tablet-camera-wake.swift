import Foundation

@main
struct TabletCameraWakeTests {
  static func main() async {
    let expected = TabletCameraWakeTarget.Point(x: 1440, y: 960)
    precondition(TabletCameraWakeTarget.parsePrompt(layout()) == .asleep(expected))
    precondition(TabletCameraWakeTarget.parsePrompt(layout(bundle: "unrelated.app")) == .clear)
    precondition(TabletCameraWakeTarget.parsePrompt(layout(key: "other_view")) == .clear)
    precondition(TabletCameraWakeTarget.parsePrompt(layout(visible: "false")) == .clear)
    precondition(TabletCameraWakeTarget.parsePrompt(layout(bounds: "[1569,981][1312,939]")) == .clear)
    precondition(TabletCameraWakeTarget.parsePrompt(Data()) == .unavailable)
    print("Tablet camera wake prompt checks passed.")
  }

  private static func layout(bundle: String = "com.huawei.hmos.camera", key: String = "SAVE_POWER_MODE_VIEW",
                             visible: String = "true", bounds: String = "[1312,939][1569,981]") -> Data {
    Data("""
      {"attributes":{},"children":[
        {"attributes":{"bundleName":"\(bundle)","visible":"true"},"children":[
          {"attributes":{"key":"\(key)","visible":"true"},"children":[
            {"attributes":{"text":"点击屏幕唤醒相机","visible":"\(visible)","bounds":"\(bounds)"}}
          ]}
        ]}
      ]}
      """.utf8)
  }
}
