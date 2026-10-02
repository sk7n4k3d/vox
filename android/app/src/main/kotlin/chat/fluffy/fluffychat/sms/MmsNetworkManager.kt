package chat.fluffy.fluffychat.sms

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.util.Log

/**
 * Owns a SINGLE shared cellular-MMS network, reference-counted and serialized —
 * mirrors AOSP / klinker41 `MmsNetworkManager`. Multiple sends share one network
 * instead of each firing its own requestNetwork (which, under back-to-back
 * sends, raced into "connect timeout" / "Binding socket to network failed EPERM"
 * as one send tore the PDN down while the next bound to it).
 *
 * Callers wrap work in [withNetwork], which acquires the network (bringing the
 * MMS PDN up if needed), runs the block with the [Network], then releases it.
 * The whole acquire/release is `synchronized(this)`-guarded so sends serialize.
 */
object MmsNetworkManager {

    private const val ACQUIRE_TIMEOUT_MS = 60_000L

    private var network: Network? = null
    private var callback: ConnectivityManager.NetworkCallback? = null
    private var refCount = 0

    /**
     * Vrai pendant qu'un thread est dans `requestNetwork` + attente du callback.
     * Le monitor est relâché par `lock.wait()`, donc un 2e thread pouvait entrer,
     * voir `network == null` et lancer une 2e acquisition en écrasant `callback`
     * (fuite de NetworkCallback). Ce flag l'en empêche.
     */
    private var acquiring = false
    private val lock = Object()

    /**
     * Runs [block] with an acquired MMS [Network]. Serialized: only one send is
     * in flight at a time, and the network is kept alive across overlapping
     * calls via reference counting. Returns block's result, or null if the
     * network couldn't be acquired.
     */
    fun <T> withNetwork(context: Context, block: (Network) -> T): T? {
        val net = acquire(context) ?: return null
        val cm = context.getSystemService(ConnectivityManager::class.java)
        // Bind THIS PROCESS to the MMS network for the duration of the send, so a
        // plain url.openConnection() in MmsHttpClient routes over cellular MMS
        // without per-socket binding (which raced into EPERM). Serialized, so the
        // global process binding is safe. Restored afterwards.
        val previous = cm?.boundNetworkForProcess
        runCatching { cm?.bindProcessToNetwork(net) }
        return try {
            block(net)
        } finally {
            runCatching { cm?.bindProcessToNetwork(previous) }
            release(context)
        }
    }

    private fun acquire(context: Context): Network? {
        synchronized(lock) {
            refCount += 1
            // Réseau déjà up, ou acquisition en cours par un autre thread : on
            // attend la fin de l'acquisition (le monitor est relâché par wait(),
            // d'où la boucle de garde) au lieu de lancer un 2e requestNetwork.
            while (network == null && acquiring) {
                try {
                    lock.wait(ACQUIRE_TIMEOUT_MS)
                } catch (e: InterruptedException) {
                    break
                }
            }
            network?.let {
                Log.i(SmsBridge.TAG, "MmsNetworkManager: réseau déjà acquis")
                return it
            }
            val cm = context.getSystemService(ConnectivityManager::class.java)
                ?: run { refCount -= 1; return null }
            val request = NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_CELLULAR)
                .addCapability(NetworkCapabilities.NET_CAPABILITY_MMS)
                .build()
            val cb = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(n: Network) {
                    synchronized(lock) {
                        network = n
                        acquiring = false
                        lock.notifyAll()
                    }
                }

                override fun onUnavailable() {
                    synchronized(lock) {
                        network = null
                        acquiring = false
                        lock.notifyAll()
                    }
                }

                override fun onLost(n: Network) {
                    synchronized(lock) {
                        if (network == n) network = null
                    }
                }
            }
            callback = cb
            acquiring = true
            runCatching { cm.requestNetwork(request, cb) }
                .onFailure {
                    Log.e(SmsBridge.TAG, "requestNetwork(MMS) failed: ${it.message}")
                    refCount -= 1
                    callback = null
                    acquiring = false
                    return null
                }
            // Wait for onAvailable (up to the acquire timeout).
            val deadline = System.nanoTime() + ACQUIRE_TIMEOUT_MS * 1_000_000
            while (network == null) {
                val remainingMs = (deadline - System.nanoTime()) / 1_000_000
                if (remainingMs <= 0) break
                try {
                    lock.wait(remainingMs)
                } catch (e: InterruptedException) {
                    break
                }
            }
            if (network == null) {
                Log.e(SmsBridge.TAG, "MmsNetworkManager: timeout acquisition réseau MMS")
                refCount -= 1
                runCatching { cm.unregisterNetworkCallback(cb) }
                callback = null
                acquiring = false
            }
            return network
        }
    }

    private fun release(context: Context) {
        synchronized(lock) {
            refCount -= 1
            if (refCount > 0) return
            refCount = 0
            val cm = context.getSystemService(ConnectivityManager::class.java)
            callback?.let { cb -> runCatching { cm?.unregisterNetworkCallback(cb) } }
            callback = null
            network = null
            Log.i(SmsBridge.TAG, "MmsNetworkManager: réseau MMS libéré")
        }
    }
}
