// The widgets' picture check: draws every widget in every size, light and dark, from the gallery's made-up week, into $1/*.png.
import SwiftUI
import WidgetKit
import ImageIO
import DatelineCore

@main enum RenderWidgets {
    @MainActor static func main() {
        let out = URL(fileURLWithPath: CommandLine.arguments[1])
        let now = cal.startOfDay(for: Date()).addingTimeInterval(10.5 * 3600)
        let sizes: [WidgetFamily: CGSize] = [.systemSmall: .init(width: 170, height: 170), .systemMedium: .init(width: 364, height: 170), .systemLarge: .init(width: 364, height: 382)]
        let all: [(String, [WidgetFamily], (Entry) -> AnyView)] = [
            ("today", [.systemSmall, .systemMedium, .systemLarge], { AnyView(TodayView(e: $0)) }),
            ("next", [.systemSmall], { AnyView(NextView(e: $0)) }),
            ("tasks", [.systemSmall, .systemMedium, .systemLarge], { AnyView(TasksView(e: $0)) }),
            ("week", [.systemMedium, .systemLarge], { AnyView(WeekView(e: $0)) }),
            ("month", [.systemSmall, .systemLarge], { AnyView(MonthView(e: $0)) }),
        ]
        for (name, families, make) in all {
            for f in families {
                for dark in [false, true] {
                    let e = Entry(date: now, snap: .sample(now), family: f)
                    let v = make(e).padding(16).frame(width: sizes[f]!.width, height: sizes[f]!.height, alignment: .topLeading)
                        .background(dark ? Color(white: 0.17) : .white).clipShape(RoundedRectangle(cornerRadius: 22))
                        .environment(\.colorScheme, dark ? .dark : .light).padding(12)
                    let r = ImageRenderer(content: v); r.scale = 2
                    let file = out.appendingPathComponent("\(name)-\(f)-\(dark ? "dark" : "light").png")
                    if let img = r.cgImage, let d = CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil) { CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d) }
                }
            }
        }
    }
}
