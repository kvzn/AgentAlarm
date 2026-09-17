import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            IntegrationsTab().tabItem { Label("接入", systemImage: "link") }
            SoundsTab().tabItem { Label("声音与语音", systemImage: "speaker.wave.2") }
            RulesTab().tabItem { Label("规则", systemImage: "slider.horizontal.3") }
            GeneralTab().tabItem { Label("通用", systemImage: "gear") }
        }
        .frame(width: 600, height: 480)
    }
}
