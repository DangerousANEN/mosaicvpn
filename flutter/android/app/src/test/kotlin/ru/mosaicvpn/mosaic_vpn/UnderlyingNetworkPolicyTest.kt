package ru.mosaicvpn.mosaic_vpn

fun main() {
    println("=== STARTING UNDERLYING NETWORK POLICY REGRESSION SUITE ===")
    val policy = UnderlyingNetworkPolicy(processNonce = "testproc")

    // Test 1: Initial state has opaque nonce and generation 0
    check(policy.currentFingerprint() == "testproc:0") {
        "Initial fingerprint should be testproc:0, got ${policy.currentFingerprint()}"
    }
    println("Test 1: Initial fingerprint: PASS (${policy.currentFingerprint()})")

    // Test 2: Cellular initial connection (validated)
    val cellValidated = UnderlyingNetworkPolicy.NetworkRecord(
        networkKey = 1001L,
        interfaceName = "rmnet_data0",
        interfaceIndex = 8,
        isCellular = true,
        hasInternet = true,
        isValidated = true,
        isMetered = true,
    )
    val action1 = policy.onNetworkUpdated(cellValidated)
    check(action1 is UnderlyingNetworkPolicy.PolicyAction.Select)
    check(action1.record.interfaceName == "rmnet_data0")
    check(action1.fingerprint == "testproc:1")
    println("Test 2: Cellular initial selection: PASS (${action1.fingerprint})")

    // Test 3: Deduplication / storm prevention on capability flaps
    for (i in 1..10) {
        val flapAction = policy.onNetworkUpdated(cellValidated)
        check(flapAction is UnderlyingNetworkPolicy.PolicyAction.NoChange)
    }
    check(policy.currentFingerprint() == "testproc:1") {
        "Flaps should not increment generation, got ${policy.currentFingerprint()}"
    }
    println("Test 3: Capability flap storm prevention (dedup): PASS")

    // Test 4: Dead / captive / unvalidated Wi-Fi arrives -> Validated Cellular MUST stay selected!
    val deadWifi = UnderlyingNetworkPolicy.NetworkRecord(
        networkKey = 1002L,
        interfaceName = "wlan0",
        interfaceIndex = 16,
        isWifi = true,
        hasInternet = true,
        isValidated = false, // captive or no upstream internet
        isMetered = false,
        isActiveDefault = false,
    )
    val actionWifiUnvalidated = policy.onNetworkUpdated(deadWifi)
    check(actionWifiUnvalidated is UnderlyingNetworkPolicy.PolicyAction.NoChange) {
        "Unvalidated Wi-Fi should NOT preempt validated cellular! Got $actionWifiUnvalidated"
    }
    check(policy.getSelectedNetwork()?.interfaceName == "rmnet_data0")
    println("Test 4: Dead/unvalidated Wi-Fi rejected against validated Cellular: PASS")

    // Test 5: Active Cellular default -> Secondary Wi-Fi arrives but Cellular is active default
    val activeCell = cellValidated.copy(isActiveDefault = true)
    policy.onNetworkUpdated(activeCell)
    val secondaryWifi = deadWifi.copy(isValidated = true, isActiveDefault = false)
    val actionSecWifi = policy.onNetworkUpdated(secondaryWifi)
    check(actionSecWifi is UnderlyingNetworkPolicy.PolicyAction.NoChange) {
        "Secondary Wi-Fi should NOT preempt active default cellular! Got $actionSecWifi"
    }
    check(policy.getSelectedNetwork()?.interfaceName == "rmnet_data0")
    println("Test 5: Active default cellular beats secondary Wi-Fi: PASS")

    // Test 6: Wi-Fi becomes active default and validated -> Handover to Wi-Fi
    val activeWifi = secondaryWifi.copy(isActiveDefault = true)
    val actionWifiDefault = policy.onNetworkUpdated(activeWifi)
    check(actionWifiDefault is UnderlyingNetworkPolicy.PolicyAction.Select)
    check(actionWifiDefault.record.interfaceName == "wlan0")
    check(actionWifiDefault.fingerprint == "testproc:2")
    println("Test 6: Active validated Wi-Fi selected: PASS (${actionWifiDefault.fingerprint})")

    // Test 7: Wi-Fi lost -> Fallback to Validated Cellular
    val actionWifiLost = policy.onNetworkLost(1002L)
    check(actionWifiLost is UnderlyingNetworkPolicy.PolicyAction.Select)
    check(actionWifiLost.record.interfaceName == "rmnet_data0")
    check(actionWifiLost.fingerprint == "testproc:3")
    println("Test 7: Fallback to Cellular on Wi-Fi lost: PASS (${actionWifiLost.fingerprint})")

    // Test 8: Carrier IMS-only APN (no INTERNET capability, not active default) must be rejected
    val imsRecord = UnderlyingNetworkPolicy.NetworkRecord(
        networkKey = 1005L,
        interfaceName = "rmnet_ims0",
        interfaceIndex = 12,
        isCellular = true,
        hasInternet = false, // IMS has no internet
        isValidated = false,
        isActiveDefault = false,
    )
    val actionIms = policy.onNetworkUpdated(imsRecord)
    check(actionIms is UnderlyingNetworkPolicy.PolicyAction.NoChange)
    check(policy.getSelectedNetwork()?.interfaceName == "rmnet_data0")
    println("Test 8: IMS-only cellular without INTERNET capability rejected: PASS")

    // Test 9: Strict VPN interface (tun0) exclusion
    val vpnRecord = UnderlyingNetworkPolicy.NetworkRecord(
        networkKey = 1003L,
        interfaceName = "tun0",
        interfaceIndex = 25,
        isVpn = true,
        hasInternet = true,
    )
    val actionVpn = policy.onNetworkUpdated(vpnRecord)
    check(actionVpn is UnderlyingNetworkPolicy.PolicyAction.NoChange)
    check(policy.getSelectedNetwork()?.interfaceName == "rmnet_data0")
    println("Test 9: Strict VPN interface (tun0) exclusion: PASS")

    // Test 10: Total loss when Cellular is also lost
    val actionTotalLoss = policy.onNetworkLost(1001L)
    check(actionTotalLoss is UnderlyingNetworkPolicy.PolicyAction.Lost)
    check(actionTotalLoss.fingerprint == "testproc:4")
    check(policy.getSelectedNetwork() == null)
    println("Test 10: Total network loss handled with Lost action: PASS (${actionTotalLoss.fingerprint})")

    // Test 11: Free LTE / unvalidated cellular recovery when it becomes active default
    val freeLteRecord = UnderlyingNetworkPolicy.NetworkRecord(
        networkKey = 1004L,
        interfaceName = "rmnet_data1",
        interfaceIndex = 9,
        isCellular = true,
        hasInternet = true,
        isValidated = false, // Free LTE captive portal / zero-balance
        isActiveDefault = true,
        isMetered = true,
    )
    val actionFreeLte = policy.onNetworkUpdated(freeLteRecord)
    check(actionFreeLte is UnderlyingNetworkPolicy.PolicyAction.Select)
    check(actionFreeLte.record.interfaceName == "rmnet_data1")
    check(actionFreeLte.fingerprint == "testproc:5")
    println("Test 11: Free LTE / unvalidated cellular selection via active default: PASS (${actionFreeLte.fingerprint})")

    val snapshotPolicy = UnderlyingNetworkPolicy("snapshot")
    snapshotPolicy.updateSnapshot(listOf(cellValidated, secondaryWifi))
    val before = snapshotPolicy.currentFingerprint()
    check(snapshotPolicy.updateSnapshot(listOf(secondaryWifi, cellValidated)) is UnderlyingNetworkPolicy.PolicyAction.NoChange)
    check(snapshotPolicy.currentFingerprint() == before)
    check(snapshotPolicy.updateSnapshot(emptyList()) is UnderlyingNetworkPolicy.PolicyAction.Lost)
    println("Atomic reordered snapshots and total loss: PASS")
    println("=== ALL UNDERLYING NETWORK POLICY REGRESSION TESTS PASSED (GREEN) ===")
}
