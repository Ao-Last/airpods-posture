import SwiftUI

@main
struct AirPodsPostureApp: App {
    @StateObject private var model = PostureLabModel()

    var body: some Scene {
        Window("AirPods Posture Lab", id: "main") {
            ContentView(model: model)
                .frame(width: 760, height: 720)
                .onAppear {
                    model.start()
                }
                .onDisappear {
                    model.stop()
                }
        }
        .windowResizability(.contentSize)
    }
}
