import SwiftUI

enum AppSupport {
    static let website = URL(string: "https://www.flyingrtx.com/asset-time-machine/support")!
    static let privacy = URL(string: "https://www.flyingrtx.com/asset-time-machine/privacy")!
    static var diagnostics: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "Asset Time Machine \(info["CFBundleShortVersionString"] as? String ?? "—") (\(info["CFBundleVersion"] as? String ?? "—"))\n"
            + ProcessInfo.processInfo.operatingSystemVersionString + "\n"
            + "Language: " + AppLocalization.currentLocale.identifier
    }
    static var feedback: URL {
        var url = URLComponents(string: "mailto:flyingrtx@gmail.com")!
        url.queryItems = [URLQueryItem(name: "subject", value: AppLocalization.string("资产时光机问题反馈")),
                         URLQueryItem(name: "body", value: "\n\n" + diagnostics)]
        return url.url!
    }
}

struct AppSupportView: View {
    var body: some View {
        List {
            Section(AppLocalization.string("帮助")) {
                DisclosureGroup(AppLocalization.string("备份与恢复")) {
                    Text(AppLocalization.string("在设置的本机备份与恢复中导出 JSON。恢复文件会先显示记录范围，确认后替换本机记录，并保留恢复前备份。"))
                }
                DisclosureGroup(AppLocalization.string("跨设备同步")) {
                    Text(AppLocalization.string("两端使用同一账户并保持应用在前台。先保存或放弃编辑；遇到差异请在云同步中确认。恢复旧备份后，需要核对并重新关联本机记录。"))
                }
                DisclosureGroup(AppLocalization.string("找回误删记录")) {
                    Text(AppLocalization.string("在云同步的备份列表选择删除之前的版本，核对日期与记录范围后恢复。恢复只替换本机记录，云端记录保持不变。"))
                }
            }
            Section(AppLocalization.string("支持")) {
                Link(destination: AppSupport.feedback) {
                    Label(AppLocalization.string("联系支持"), systemImage: "envelope")
                }
                Link(destination: AppSupport.website) {
                    Label(AppLocalization.string("支持网站"), systemImage: "questionmark.circle")
                }
                Link(destination: AppSupport.privacy) {
                    Label(AppLocalization.string("隐私政策"), systemImage: "hand.raised")
                }
            }
            Section {
                Text(AppSupport.diagnostics).font(.footnote).textSelection(.enabled)
                ShareLink(item: AppSupport.diagnostics) {
                    Label(AppLocalization.string("分享诊断信息"), systemImage: "square.and.arrow.up")
                }
            } header: {
                Text(AppLocalization.string("诊断信息"))
            } footer: {
                Text(AppLocalization.string("诊断信息仅包含应用版本、系统版本和语言。"))
            }
        }
        .navigationTitle(AppLocalization.string("帮助与反馈"))
        .tint(AssetTheme.gold)
    }
}
