--  imu_types.ads
--  Types shared by every IMU chip crate and the code that reads them.
--  Part of imu_generic. No hardware access.
--
--  General plan:
--  The application only sees these types and Imu_Interface. A chip crate
--  maps them onto its own register bits, so swapping the LSM6DSO32 for
--  another IMU is a new chip crate plus one instantiation in Payload, not a
--  rewrite of the mains. Anything only one chip has (magnetometer, tap
--  detection, interrupts) stays in that chip crate until a second chip
--  needs it.
--
--  Errors are reported with Ok flags, not exceptions. The light tasking
--  runtime has No_Exception_Propagation, so a raise anywhere below the
--  application goes straight to the last chance handler and stops logging.

with Interfaces; use Interfaces;

package Imu_Types
  with Pure
is
   type Axis is (X, Y, Z);

   --  one reading per axis, in raw chip counts
   type Raw_Vector is array (Axis) of Integer_16;

   --  Accelerometer full scale. A chip that lacks a range sets Ok to False
   --  in Init instead of rounding, so the log never claims a range it
   --  didn't use. The LSM6DSO32 has G4 to G32.
   type Accel_Range is (G2, G4, G8, G16, G24, G32);

   --  Gyroscope full scale, in degrees per second
   type Gyro_Range is
     (DPS_125, DPS_250, DPS_500, DPS_1000, DPS_2000, DPS_4000);

   --  Output data rate in Hz. The chip picks the nearest rate at or above
   --  the request. 0 powers that sensor down.
   subtype Rate_Hz is Natural range 0 .. 10_000;

   type Imu_Config is record
      Accel_Range  : Imu_Types.Accel_Range := G16;
      Gyro_Range   : Imu_Types.Gyro_Range  := DPS_2000;
      Accel_ODR_Hz : Rate_Hz := 104;
      Gyro_ODR_Hz  : Rate_Hz := 104;

      --  on: the chip's low pass filter stops motor vibration aliasing
      --  into the data. Off only for bench tests of the raw signal.
      Low_Pass     : Boolean := True;
   end record;

   --  what the fitted chip can do, so the application can check before
   --  relying on it
   type Imu_Caps is record
      Has_Mag         : Boolean := False;
      Has_Fifo        : Boolean := False;
      Fifo_Samples    : Natural := 0;  --  accel + gyro pairs the FIFO holds
      Max_Accel_Range : Accel_Range := G16;
      Max_Gyro_Range  : Gyro_Range  := DPS_2000;
   end record;

   --  One accel and gyro pair. Timestamp is microseconds since boot on the
   --  same clock as Payload.Clock_Us. FIFO chips convert their own sample
   --  timestamps to it, so loop jitter does not show up in the data.
   type Raw_Sample is record
      Timestamp : Unsigned_32 := 0;
      Accel     : Raw_Vector  := (others => 0);
      Gyro      : Raw_Vector  := (others => 0);
   end record;

   type Raw_Sample_Array is array (Positive range <>) of Raw_Sample;

end Imu_Types;
