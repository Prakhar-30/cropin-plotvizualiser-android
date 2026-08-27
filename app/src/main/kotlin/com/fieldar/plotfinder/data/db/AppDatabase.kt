package com.fieldar.plotfinder.data.db

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase

@Database(
    entities = [PlotEntity::class, TelemetryEntity::class, HealthEntity::class],
    version = 3,
    exportSchema = true,
)
abstract class AppDatabase : RoomDatabase() {
    abstract fun plots(): PlotDao
    abstract fun telemetry(): TelemetryDao
    abstract fun health(): HealthDao

    companion object {
        /**
         * Adds the boundary colour and the stabiliser telemetry columns.
         *
         * A real migration rather than a destructive fallback: the cache is the
         * only copy of the plots an agent has once they are out of signal, and
         * wiping it on upgrade would strand someone mid-visit. Existing rows get
         * colour slot 0 and zeroed telemetry, which is honest - those sessions
         * genuinely did not measure anchor shift.
         */
        val MIGRATION_1_2 = object : Migration(1, 2) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE plots ADD COLUMN colourIndex INTEGER NOT NULL DEFAULT 0")
                db.execSQL("ALTER TABLE telemetry ADD COLUMN sessionId TEXT NOT NULL DEFAULT ''")
                db.execSQL("ALTER TABLE telemetry ADD COLUMN headingConfidence TEXT NOT NULL DEFAULT ''")
                db.execSQL("ALTER TABLE telemetry ADD COLUMN anchorShiftM REAL NOT NULL DEFAULT 0.0")
                db.execSQL("ALTER TABLE telemetry ADD COLUMN anchorAgeS REAL NOT NULL DEFAULT 0.0")
                db.execSQL("ALTER TABLE telemetry ADD COLUMN deviceModel TEXT NOT NULL DEFAULT ''")
                db.execSQL("ALTER TABLE telemetry ADD COLUMN appVersion TEXT NOT NULL DEFAULT ''")
            }
        }

        /**
         * Adds the crop-health raster cache.
         *
         * A pure addition: no existing column moves, so every cached boundary
         * survives untouched. The table starts empty and fills on the next
         * sync, which is the honest state - the device has genuinely never been
         * told anything about this plot's crop health.
         */
        val MIGRATION_2_3 = object : Migration(2, 3) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL(
                    """
                    CREATE TABLE IF NOT EXISTS plot_health (
                        plotId TEXT NOT NULL PRIMARY KEY,
                        capturedOn TEXT NOT NULL,
                        synthetic INTEGER NOT NULL,
                        snapshotJson TEXT NOT NULL,
                        syncedAtMs INTEGER NOT NULL
                    )
                    """.trimIndent(),
                )
            }
        }

        @Volatile
        private var instance: AppDatabase? = null

        fun get(context: Context): AppDatabase = instance ?: synchronized(this) {
            instance ?: Room.databaseBuilder(
                context.applicationContext,
                AppDatabase::class.java,
                "plotfinder.db",
            ).addMigrations(MIGRATION_1_2, MIGRATION_2_3).build().also { instance = it }
        }
    }
}
