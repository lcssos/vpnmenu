import Foundation

private func decode(_ json: String) -> Profile? {
    try? JSONDecoder().decode(Profile.self, from: Data(json.utf8))
}

func runProfileTests() {
    let legacy = decode(#"{"name":"公司 VPN","server":"vpn.example.com"}"#)
    check(legacy != nil, "旧配置可解码")
    checkEqual(legacy?.portValue, 4430, "默认端口 4430")
    checkEqual(legacy?.domainList.count, 0, "默认无域名")
    checkEqual(ProfileValidation.error(for: legacy!), nil, "旧配置通过校验")

    var badTun = legacy!; badTun.tunInterface = "en0"
    checkEqual(ProfileValidation.error(for: badTun), "隧道接口名不合法：en0", "非法 tun 被拒")

    let encoded = String(data: ProfileStore.encode(legacy!)!, encoding: .utf8)!
    let back = try? JSONDecoder().decode(Profile.self, from: Data(encoded.utf8))
    checkEqual(back?.server, "vpn.example.com", "编码往返保留字段")

    checkEqual(legacy?.backendID, "zju-connect", "缺省后端为 zju-connect")

    var other = legacy!; other.backend = "other"
    checkEqual(other.backendID, "other", "显式后端生效")

    let legacyJSON = String(data: ProfileStore.encode(legacy!)!, encoding: .utf8)!
    check(!legacyJSON.contains("\"backend\""), "backend 为 nil 时不写入 JSON")

    let otherJSON = String(data: ProfileStore.encode(other)!, encoding: .utf8)!
    check(otherJSON.contains("\"backend\" : \"other\""), "显式 backend 写入 JSON")

    var badName = legacy!; badName.name = ""
    checkEqual(ProfileValidation.commonError(for: badName), "配置名称不能为空", "通用校验：名称")
    checkEqual(ProfileValidation.zjuError(for: badTun), "隧道接口名不合法：en0", "后端校验：tun")
}
