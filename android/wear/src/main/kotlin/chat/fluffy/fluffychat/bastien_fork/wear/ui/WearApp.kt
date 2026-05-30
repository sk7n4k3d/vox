package chat.fluffy.fluffychat.bastien_fork.wear.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.navigation.NavType
import androidx.navigation.navArgument
import androidx.wear.compose.material3.AppScaffold
import androidx.wear.compose.navigation.SwipeDismissableNavHost
import androidx.wear.compose.navigation.composable
import androidx.wear.compose.navigation.rememberSwipeDismissableNavController

object Routes {
    const val ROOM_LIST = "rooms"
    const val ROOM_DETAIL = "room/{roomId}"
    fun roomDetail(roomId: String) = "room/$roomId"
}

/**
 * @param initialRoomId room à ouvrir directement (deep-link depuis une notif).
 *   null = démarrage normal sur la liste.
 * @param onInitialRoomConsumed appelé une fois la navigation déclenchée, pour que
 *   l'hôte ne re-navigue pas sur recomposition / changement de config.
 */
@Composable
fun WearApp(
    initialRoomId: String? = null,
    onInitialRoomConsumed: () -> Unit = {}
) {
    val navController = rememberSwipeDismissableNavController()

    // Deep-link notif : navigue vers la room demandée une seule fois.
    LaunchedEffect(initialRoomId) {
        val roomId = initialRoomId ?: return@LaunchedEffect
        navController.navigate(Routes.roomDetail(roomId))
        onInitialRoomConsumed()
    }

    AppScaffold {
        SwipeDismissableNavHost(
            navController = navController,
            startDestination = Routes.ROOM_LIST
        ) {
            composable(Routes.ROOM_LIST) {
                RoomListScreen(
                    onRoomClick = { room ->
                        navController.navigate(Routes.roomDetail(room.id))
                    }
                )
            }
            composable(
                Routes.ROOM_DETAIL,
                arguments = listOf(navArgument("roomId") { type = NavType.StringType })
            ) { backStackEntry ->
                val roomId = backStackEntry.arguments?.getString("roomId") ?: return@composable
                RoomDetailScreen(
                    roomId = roomId,
                    onBack = { navController.popBackStack() }
                )
            }
        }
    }
}
