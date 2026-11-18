import Foundation

func runNetworkTests() {
    let t0 = Date(timeIntervalSince1970: 1_000)
    let a = "en0=10.0.0.2|10.0.0.1"
    let b = "en0=192.168.1.5|192.168.1.1"

    var d = NetworkChangeDetector(settle: 3)
    check(!d.update(signature: a, satisfied: true, now: t0), "首次签名只做基线")
    check(!d.hasPending, "基线不产生候选")
    check(!d.update(signature: a, satisfied: true, now: t0.addingTimeInterval(1)),
          "签名不变不触发")

    check(!d.update(signature: b, satisfied: true, now: t0.addingTimeInterval(10)),
          "签名变化先等稳定")
    check(d.hasPending, "签名变化进入候选")
    check(!d.update(signature: b, satisfied: true, now: t0.addingTimeInterval(12)),
          "未满 settle 不触发")
    check(d.update(signature: b, satisfied: true, now: t0.addingTimeInterval(13)),
          "稳定后触发")
    check(!d.hasPending, "触发后清空候选")
    check(!d.update(signature: b, satisfied: true, now: t0.addingTimeInterval(20)),
          "触发后不重复")

    var u = NetworkChangeDetector(settle: 3)
    _ = u.update(signature: "A", satisfied: true, now: t0)
    _ = u.update(signature: "B", satisfied: true, now: t0.addingTimeInterval(1))
    _ = u.update(signature: "C", satisfied: true, now: t0.addingTimeInterval(2))
    check(!u.update(signature: "C", satisfied: true, now: t0.addingTimeInterval(4)),
          "候选中途变化要重新计时")
    check(u.update(signature: "C", satisfied: true, now: t0.addingTimeInterval(5)),
          "最终稳定签名触发")

    var o = NetworkChangeDetector(settle: 3)
    _ = o.update(signature: "A", satisfied: true, now: t0)
    check(!o.update(signature: "", satisfied: false, now: t0.addingTimeInterval(5)),
          "断网本身不触发")
    _ = o.update(signature: "A", satisfied: true, now: t0.addingTimeInterval(10))
    check(o.update(signature: "A", satisfied: true, now: t0.addingTimeInterval(13)),
          "断网后同签名恢复要触发")

    var offlineAtLaunch = NetworkChangeDetector(settle: 3)
    _ = offlineAtLaunch.update(signature: "", satisfied: false, now: t0)
    check(!offlineAtLaunch.update(signature: "A", satisfied: true,
                                  now: t0.addingTimeInterval(5)),
          "启动时离线，恢复只做基线")
}
