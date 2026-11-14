import Foundation

var failures = 0

func check(_ cond: Bool, _ name: String, file: String = #file, line: Int = #line) {
    if cond { print("ok   \(name)") }
    else { failures += 1; print("FAIL \(name)  (\(file):\(line))") }
}

func checkEqual<T: Equatable>(_ got: T, _ want: T, _ name: String,
                              file: String = #file, line: Int = #line) {
    check(got == want, "\(name) (got \(got), want \(want))", file: file, line: line)
}

/// 测试用：构造只带必填字段的 Profile（避免依赖 memberwise init 的可选参数列表）。
func makeProfile(name: String, server: String) -> Profile {
    let json = #"{"name":"\#(name)","server":"\#(server)"}"#
    return try! JSONDecoder().decode(Profile.self, from: Data(json.utf8))
}

runProfileTests()
exit(failures == 0 ? 0 : 1)
