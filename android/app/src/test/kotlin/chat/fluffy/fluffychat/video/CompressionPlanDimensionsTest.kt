package chat.fluffy.fluffychat.video

import org.junit.Assert.assertEquals
import org.junit.Test

class CompressionPlanDimensionsTest {
    @Test fun landscapeAndRotatedPortraitUseTheirDisplayLimits() {
        assertEquals(1920 to 1080, CompressionPlan.outputSize(3840, 2160, false))
        // Encoded landscape with a 90-degree display rotation becomes 606 x 1080.
        assertEquals(1080 to 606, CompressionPlan.outputSize(3840, 2160, true))
        assertEquals(606 to 1080, CompressionPlan.outputSize(2160, 3840, false))
    }

    @Test fun alreadySmallDimensionsAreUnchanged() {
        assertEquals(640 to 480, CompressionPlan.outputSize(640, 480, false))
    }
}
