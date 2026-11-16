package chat.fluffy.fluffychat.video

/** Independent listeners belong to different Flutter engines. */
internal class VideoEventHub {
    private val listeners = mutableMapOf<Any, (Map<String, Any?>) -> Unit>()

    fun subscribe(owner: Any, listener: (Map<String, Any?>) -> Unit) {
        synchronized(listeners) { listeners[owner] = listener }
    }

    fun unsubscribe(owner: Any) {
        synchronized(listeners) { listeners.remove(owner) }
    }

    fun publish(event: Map<String, Any?>) {
        val snapshot = synchronized(listeners) { listeners.values.toList() }
        snapshot.forEach { it(event) }
    }
}
