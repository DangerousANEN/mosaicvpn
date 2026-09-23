package ru.mosaicvpn.mosaic_vpn

import java.util.UUID

/**
 * Robust non-VPN underlying network selection and handover policy.
 *
 * Implements:
 * 1. Strict priority hierarchy:
 *    - Active Android default network has absolute priority (+10000).
 *    - Validated connectivity beats unvalidated across transports (+5000).
 *      (e.g., validated LTE always beats captive / unvalidated / dead Wi-Fi).
 *    - Transport preference when validation status is equal:
 *      Ethernet (+1000) > Wi-Fi (+500) > Cellular (+300).
 *    - Quality tie-breakers: unmetered (+50), unconstrained (+20).
 *    - Sticky current network bias (+15) to prevent flap ping-pong.
 * 2. Strict non-VPN exclusion (excludes VPN transports and TUN/PPP/P2P virtual interfaces).
 * 3. Excludes carrier-internal networks without internet capability (e.g. IMS, MMS, FOTA).
 *    A network is eligible only if it has NET_CAPABILITY_INTERNET or is the active default.
 * 4. Deduplication: updates libbox and increments fingerprint generation ONLY when selected
 *    interface, index, metered, or loss status actually changes (prevents restart storms).
 * 5. onLost handling: cleans up disconnected network and smoothly falls back to the next best
 *    underlying network, or signals loss (-1) without dropping VPN service runtime state.
 * 6. Opaque network fingerprint tracking (nonce:generation) starting with initial no-network identity.
 */
class UnderlyingNetworkPolicy(
    val processNonce: String = UUID.randomUUID().toString().replace("-", "").take(8),
) {
    data class NetworkRecord(
        val networkKey: Long,
        val interfaceName: String,
        val interfaceIndex: Int,
        val isWifi: Boolean = false,
        val isCellular: Boolean = false,
        val isEthernet: Boolean = false,
        val isVpn: Boolean = false,
        val hasInternet: Boolean = false,
        val isMetered: Boolean = false,
        val isConstrained: Boolean = false,
        val isValidated: Boolean = false,
        val isActiveDefault: Boolean = false,
    )

    sealed class PolicyAction {
        data class Select(val record: NetworkRecord, val fingerprint: String) : PolicyAction()
        data class Lost(val fingerprint: String) : PolicyAction()
        object NoChange : PolicyAction()
    }

    private val trackedNetworks = mutableMapOf<Long, NetworkRecord>()
    private var selectedRecord: NetworkRecord? = null
    private var generation: Long = 0L

    @Synchronized
    fun currentFingerprint(): String = "$processNonce:$generation"

    @Synchronized
    fun getSelectedNetwork(): NetworkRecord? = selectedRecord

    @Synchronized
    fun getTrackedNetworks(): List<NetworkRecord> = trackedNetworks.values.toList()

    /**
     * Called on onAvailable, onCapabilitiesChanged, onLinkPropertiesChanged.
     */
    @Synchronized
    fun onNetworkUpdated(record: NetworkRecord): PolicyAction {
        trackedNetworks[record.networkKey] = record
        return evaluateSelection()
    }

    /**
     * Called on onLost.
     */
    @Synchronized
    fun onNetworkLost(networkKey: Long): PolicyAction {
        val removed = trackedNetworks.remove(networkKey)
        if (removed == null && selectedRecord?.networkKey != networkKey) {
            return PolicyAction.NoChange
        }
        return evaluateSelection()
    }

    /**
     * Clears all tracking state and resets selection.
     */
    @Synchronized
    fun reset(): PolicyAction {
        trackedNetworks.clear()
        if (selectedRecord != null) {
            selectedRecord = null
            generation++
            return PolicyAction.Lost(currentFingerprint())
        }
        return PolicyAction.NoChange
    }

    @Synchronized
    fun updateSnapshot(records: List<NetworkRecord>): PolicyAction {
        trackedNetworks.clear()
        records.forEach { trackedNetworks[it.networkKey] = it }
        return evaluateSelection()
    }

    private fun evaluateSelection(): PolicyAction {
        val candidates = trackedNetworks.values.filter { isEligibleUnderlying(it) }
        val best = candidates.maxWithOrNull(candidateComparator(selectedRecord))

        if (best == null) {
            if (selectedRecord != null) {
                selectedRecord = null
                generation++
                return PolicyAction.Lost(currentFingerprint())
            }
            return PolicyAction.NoChange
        }

        val current = selectedRecord
        if (current != null && isSamePhysicalInterface(current, best)) {
            // Same physical interface; update attributes without changing generation or triggering restart
            selectedRecord = best
            return PolicyAction.NoChange
        }

        // Selected interface changed
        selectedRecord = best
        generation++
        return PolicyAction.Select(best, currentFingerprint())
    }

    private fun isEligibleUnderlying(record: NetworkRecord): Boolean {
        if (record.isVpn) return false
        val iface = record.interfaceName.lowercase()
        if (iface.isBlank() || iface.startsWith("tun") || iface.startsWith("ppp") || iface.startsWith("p2p")) {
            return false
        }
        if (record.interfaceIndex <= 0) return false
        // Must have internet capability or be the active system default.
        // Rejects non-internet cellular APNs (e.g. IMS-only, MMS, FOTA).
        return record.hasInternet || record.isActiveDefault
    }

    private fun isSamePhysicalInterface(a: NetworkRecord, b: NetworkRecord): Boolean {
        return a.networkKey == b.networkKey &&
                a.interfaceName == b.interfaceName &&
                a.interfaceIndex == b.interfaceIndex &&
                a.isMetered == b.isMetered &&
                a.isConstrained == b.isConstrained
    }

    private fun candidateComparator(current: NetworkRecord?): Comparator<NetworkRecord> {
        return Comparator { a, b ->
            val scoreA = scoreRecord(a, current)
            val scoreB = scoreRecord(b, current)
            if (scoreA != scoreB) {
                scoreA.compareTo(scoreB)
            } else {
                // Secondary tie-breaker: keep current if either matches to prevent ping-pong
                when {
                    current != null && a.networkKey == current.networkKey -> 1
                    current != null && b.networkKey == current.networkKey -> -1
                    else -> a.networkKey.compareTo(b.networkKey)
                }
            }
        }
    }

    private fun scoreRecord(record: NetworkRecord, current: NetworkRecord?): Int {
        var score = 0

        // 1. Active default network has absolute priority
        if (record.isActiveDefault) score += 10000

        // 2. Validated internet connectivity beats unvalidated across all transports
        // (e.g. validated LTE beats dead / captive Wi-Fi)
        if (record.isValidated) score += 5000

        // 3. Transport hierarchy (when validation tier is equal)
        if (record.isEthernet) score += 1000
        if (record.isWifi) score += 500
        if (record.isCellular) score += 300

        // 4. Quality tie-breakers
        if (!record.isMetered) score += 50
        if (!record.isConstrained) score += 20

        // 5. Sticky bias to current network to avoid jitter flaps
        if (current != null && record.networkKey == current.networkKey) {
            score += 15
        }
        return score
    }
}
