package com.fieldar.plotfinder.ui.ar

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.fieldar.plotfinder.core.heading.HeadingConfidence
import com.fieldar.plotfinder.core.heading.HeadingSource
import com.fieldar.plotfinder.pose.HeadingStatus

/**
 * Persistent heading-confidence chip. Not optional.
 *
 * Without it the agent has no way to tell a heading good to 3 degrees from one
 * good to 25, and both look identical on screen - a confident overlay sitting on
 * the wrong field. The **Unreliable** state also carries the single most
 * valuable instruction in the app: "walk a few steps to lock direction" turns
 * the worst failure mode into a two-second user action.
 */
@Composable
fun HeadingChip(status: HeadingStatus, modifier: Modifier = Modifier) {
    val (dot, title) = when (status.confidence) {
        HeadingConfidence.LOCKED -> Color(0xFF4ADE80) to "Locked"
        HeadingConfidence.HOLDING -> Color(0xFFF59E0B) to "Holding"
        HeadingConfidence.UNRELIABLE -> Color(0xFF9CA3AF) to "Unreliable"
    }

    val detail = when (status.confidence) {
        HeadingConfidence.LOCKED -> when (status.source) {
            HeadingSource.COURSE_OVER_GROUND -> "from your walk  ±${status.expectedErrorDeg.toInt()}°"
            HeadingSource.LANDMARK_SNAP -> "from landmark snap  ±${status.expectedErrorDeg.toInt()}°"
            HeadingSource.MAGNETOMETER -> "compass  ±${status.expectedErrorDeg.toInt()}°"
        }

        HeadingConfidence.HOLDING -> "gyro-carried  ${status.ageSeconds}s since fix"
        HeadingConfidence.UNRELIABLE -> "compass only — walk a few steps to lock direction"
    }

    Column(
        modifier = modifier
            .clip(RoundedCornerShape(10.dp))
            .background(Color(0xCC0B0F14))
            .padding(horizontal = 12.dp, vertical = 8.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(modifier = Modifier.size(10.dp).clip(CircleShape).background(dot))
            Text(
                text = "  $title",
                color = Color.White,
                fontSize = 14.sp,
                fontWeight = FontWeight.SemiBold,
            )
        }
        Text(text = detail, color = Color(0xFFB6BEC9), fontSize = 11.sp)
    }
}
