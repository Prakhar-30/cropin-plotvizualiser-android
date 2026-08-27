package com.fieldar.plotfinder.core.geo

import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * The three-by-three linear algebra the overlay needs, and nothing more.
 *
 * Deliberately free of Android imports: every line in `core.geo` runs on a plain
 * JVM so the projection can be tested against hand-computed values.
 */

data class Vec3(val x: Double, val y: Double, val z: Double) {
    val length: Double get() = sqrt(x * x + y * y + z * z)
}

/** Row-major 3x3 matrix. `m01` is row 0, column 1. */
data class Mat3(
    val m00: Double, val m01: Double, val m02: Double,
    val m10: Double, val m11: Double, val m12: Double,
    val m20: Double, val m21: Double, val m22: Double,
) {
    operator fun times(v: Vec3): Vec3 = Vec3(
        m00 * v.x + m01 * v.y + m02 * v.z,
        m10 * v.x + m11 * v.y + m12 * v.z,
        m20 * v.x + m21 * v.y + m22 * v.z,
    )

    operator fun times(o: Mat3): Mat3 = Mat3(
        m00 * o.m00 + m01 * o.m10 + m02 * o.m20,
        m00 * o.m01 + m01 * o.m11 + m02 * o.m21,
        m00 * o.m02 + m01 * o.m12 + m02 * o.m22,

        m10 * o.m00 + m11 * o.m10 + m12 * o.m20,
        m10 * o.m01 + m11 * o.m11 + m12 * o.m21,
        m10 * o.m02 + m11 * o.m12 + m12 * o.m22,

        m20 * o.m00 + m21 * o.m10 + m22 * o.m20,
        m20 * o.m01 + m21 * o.m11 + m22 * o.m21,
        m20 * o.m02 + m21 * o.m12 + m22 * o.m22,
    )

    /** For a rotation matrix this is also the inverse. */
    fun transpose(): Mat3 = Mat3(
        m00, m10, m20,
        m01, m11, m21,
        m02, m12, m22,
    )

    companion object {
        val IDENTITY = Mat3(
            1.0, 0.0, 0.0,
            0.0, 1.0, 0.0,
            0.0, 0.0, 1.0,
        )

        /** Reads the row-major 9-element array `SensorManager` fills in. */
        fun fromRowMajor(a: FloatArray): Mat3 {
            require(a.size >= 9) { "rotation matrix needs 9 elements, got ${a.size}" }
            return Mat3(
                a[0].toDouble(), a[1].toDouble(), a[2].toDouble(),
                a[3].toDouble(), a[4].toDouble(), a[5].toDouble(),
                a[6].toDouble(), a[7].toDouble(), a[8].toDouble(),
            )
        }

        /** Rotation about the device x axis (screen right). */
        fun rotationX(radians: Double): Mat3 {
            val c = cos(radians)
            val s = sin(radians)
            return Mat3(
                1.0, 0.0, 0.0,
                0.0, c, -s,
                0.0, s, c,
            )
        }

        /** Rotation about the device z axis (out of the screen). */
        fun rotationZ(radians: Double): Mat3 {
            val c = cos(radians)
            val s = sin(radians)
            return Mat3(
                c, -s, 0.0,
                s, c, 0.0,
                0.0, 0.0, 1.0,
            )
        }
    }
}
