package com.fieldar.plotfinder.ui

/**
 * One place to decide how numbers read, so the list, the detail screen and the
 * AR label never disagree about what "120 m" looks like.
 */

fun formatDistance(metres: Double): String = when {
    !metres.isFinite() -> "—"
    metres < 1_000 -> "${metres.toInt()} m"
    else -> "%.1f km".format(metres / 1_000)
}

fun formatHectares(areaSqM: Double): String = "%.2f ha".format(areaSqM / 10_000.0)

fun formatLatLng(lat: Double, lng: Double): String = "%.6f, %.6f".format(lat, lng)

/**
 * How old the cached copy is.
 *
 * Worth showing: offline, the agent has no other way to tell whether the
 * boundary they are standing on was pulled this morning or three weeks ago.
 */
fun formatCacheAge(syncedAtMs: Long, nowMs: Long = System.currentTimeMillis()): String {
    val minutes = (nowMs - syncedAtMs) / 60_000
    return when {
        minutes < 1 -> "just now"
        minutes < 60 -> "$minutes min ago"
        minutes < 60 * 24 -> "${minutes / 60} h ago"
        else -> "${minutes / (60 * 24)} d ago"
    }
}

/** Trims the API's ISO timestamp to the date, which is all that is meaningful here. */
fun formatIsoDate(iso: String): String = iso.substringBefore('T').ifBlank { iso }
