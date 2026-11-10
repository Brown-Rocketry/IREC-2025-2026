--  logger_sensors.ads
--  Reading the IMU and barometer each tick. Part of flight_logger.
--
--  General plan:
--  The IMU FIFO is drained every tick, even when nothing is being logged,
--  so it never overflows. The barometer is read every 2nd tick (50 Hz, its
--  output rate). The raw baro values are kept for the log; the same values
--  compensated give the pressure the state machine needs. A failed read
--  keeps the previous values and adds to the error count.

with Baro_Types;
with Imu_Types;

package Logger_Sensors is

   --  Room for 38 ms of IMU samples at 833 Hz, so a tick that comes late
   --  after a flash erase can still take most of the backlog.
   subtype Imu_Batch is Imu_Types.Raw_Sample_Array (1 .. 32);

   --  Remember the accelerometer scale. Call after Payload.Initialize.
   procedure Start;

   --  Read the barometer if this tick is due for it.
   procedure Read_Baro_If_Due;

   --  Drain the IMU FIFO into Batch (1 .. Count).
   procedure Read_Imu (Batch : out Imu_Batch; Count : out Natural);

   --  Returns True once a barometer read has succeeded.
   function Have_Baro return Boolean;

   --  Returns the latest barometer reading, raw, for the log.
   function Baro_Raw return Baro_Types.Raw_Reading;

   --  Returns the latest pressure in pascals, compensated.
   function Pressure_Pa return Float;

   --  Returns the mean acceleration of Batch (1 .. Count), in g.
   function Mean_Accel_G (Batch : Imu_Batch; Count : Positive) return Float
     with Pre => Count <= Batch'Last;

end Logger_Sensors;
