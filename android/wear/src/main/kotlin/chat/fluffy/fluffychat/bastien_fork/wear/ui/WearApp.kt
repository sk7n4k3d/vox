package chat.fluffy.fluffychat.bastien_fork.wear.ui

import androidx.compose.runtime.Composable
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

@Composable
fun WearApp() {
    val navController = rememberSwipeDismissableNavController()

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
