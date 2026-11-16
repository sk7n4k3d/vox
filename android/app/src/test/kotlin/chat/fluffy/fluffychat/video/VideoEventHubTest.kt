package chat.fluffy.fluffychat.video

import org.junit.Assert.assertEquals
import org.junit.Test
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class VideoEventHubTest {
    @Test fun concurrentSubscriptionAndPublishingDoNotCorruptListenerMap() {
        val hub = VideoEventHub()
        val pool = Executors.newFixedThreadPool(6)
        val tasks = (0 until 6).map { index -> pool.submit {
            repeat(20000) {
                val owner = Any()
                hub.subscribe(owner) { }
                if (index % 2 == 0) hub.publish(mapOf("kind" to "progress"))
                hub.unsubscribe(owner)
            }
        } }
        try {
            tasks.forEach { it.get(30, TimeUnit.SECONDS) }
        } finally {
            pool.shutdownNow()
        }
    }
    @Test fun subscribersAreIndependentAndLateCancellationDoesNotDisconnectOthers() {
        val hub = VideoEventHub()
        val ui = mutableListOf<String>()
        val background = mutableListOf<String>()
        val first = Any()
        val second = Any()
        hub.subscribe(first) { ui.add(it["kind"] as String) }
        hub.subscribe(second) { background.add(it["kind"] as String) }
        hub.publish(mapOf("kind" to "progress"))
        hub.unsubscribe(second)
        hub.publish(mapOf("kind" to "done"))
        assertEquals(listOf("progress", "done"), ui)
        assertEquals(listOf("progress"), background)
    }
}
