import Foundation
import Testing
@testable import AgentAlarmCore

@Suite struct ProcessTreeTests {
    @Test func appBundlePathTakesOutermostApp() {
        #expect(ProcessTree.appBundlePath(in: "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper") == "/Applications/Claude.app")
        #expect(ProcessTree.appBundlePath(in: "/Applications/iTerm.app/Contents/MacOS/iTerm2") == "/Applications/iTerm.app")
        #expect(ProcessTree.appBundlePath(in: "/usr/bin/zsh") == nil)
    }

    @Test func detectHostUsesFirstAppAndOutermostPidOfSameBundle() {
        let ancestors = [
            ProcessTree.Ancestor(pid: 10, path: "/bin/sh"),
            ProcessTree.Ancestor(pid: 9, path: "/Users/jack/.nvm/versions/node/v22/bin/node"),
            ProcessTree.Ancestor(pid: 8, path: "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper"),
            ProcessTree.Ancestor(pid: 7, path: "/Applications/Claude.app/Contents/MacOS/Claude"),
            ProcessTree.Ancestor(pid: 1, path: "/sbin/launchd"),
        ]
        let host = ProcessTree.detectHost(from: ancestors) { bundlePath in
            bundlePath == "/Applications/Claude.app" ? ("com.anthropic.claudefordesktop", "Claude") : nil
        }
        #expect(host == HostInfo(bundleId: "com.anthropic.claudefordesktop", pid: 7, name: "Claude"))
        #expect(ProcessTree.detectHost(from: [ProcessTree.Ancestor(pid: 2, path: "/usr/bin/zsh")]) { _ in nil } == nil)
    }

    @Test func realAncestorsAreReadable() {
        let ancestors = ProcessTree.ancestors()
        #expect(!ancestors.isEmpty)
        #expect(ancestors.allSatisfy { $0.pid > 0 && $0.path.hasPrefix("/") })
        _ = ProcessTree.detectHost()
        #expect(ProcessTree.parentPid(of: 1) == nil || ProcessTree.parentPid(of: 1) == 0)
    }

    @Test func bundleWithoutIdentifierIsSkipped() {
        let ancestors = [
            ProcessTree.Ancestor(pid: 9, path: "/tmp/Broken.app/Contents/MacOS/Broken"),
            ProcessTree.Ancestor(pid: 5, path: "/Applications/iTerm.app/Contents/MacOS/iTerm2"),
            ProcessTree.Ancestor(pid: 1, path: "/sbin/launchd"),
        ]
        let host = ProcessTree.detectHost(from: ancestors) { bundlePath in
            bundlePath == "/Applications/iTerm.app" ? ("com.googlecode.iterm2", "iTerm") : nil
        }
        #expect(host == HostInfo(bundleId: "com.googlecode.iterm2", pid: 5, name: "iTerm"))
    }
}
