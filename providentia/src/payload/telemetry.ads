--  telemetry.ads
--  What one log record and the journal header look like in flash. Part of
--  providentia_payload. No hardware access.
--
--  General plan:
--  The layouts are representation clauses, not hand-written packing, so
--  the compiler enforces the offsets and the writer and reader can't drift
--  apart. fileprocess.py reads the same bytes using the tables below.
--
--  Sample, 22 bytes, all values LSB first:
--     0-3    Timestamp, microseconds since boot, 32-bit, wraps about every
--            71 minutes (the page trailer's Epoch counts the wraps)
--     4-9    Accel X, Y, Z, signed 16-bit raw (scale in the header)
--    10-15   Gyro X, Y, Z, signed 16-bit raw (scale in the header)
--    16-18   Pressure, raw 24-bit ADC value from the barometer
--    19-21   Temperature, raw 24-bit ADC value from the barometer
--
--  11 samples per page (242 bytes), then the 14-byte trailer from
--  flight_journal.ads, with no padding. Baro values are logged raw, as the
--  terrarium_pico log was, so the original data is never lost: the
--  decoder compensates them with the calibration bytes in the header and
--  the formula for the chip named there (BMP390 datasheet 8.5 and 8.6).
--  On board, the same raw values are compensated for the state machine,
--  but the result is not stored. No magnetometer: the LSM6DSO32 doesn't
--  have one.
--
--  Header, 88 bytes, at offset 8 of page 0:
--     0-15   Board id, ASCII, space padded
--    16-19   Loop tick in microseconds
--    20-21   Accel output rate, Hz
--    22-23   Gyro output rate, Hz
--    24-25   Baro output rate, Hz
--    26      Accel range (Imu_Types.Accel_Range'Pos)
--    27      Gyro range (Imu_Types.Gyro_Range'Pos)
--    28      Low pass on, 1 or 0
--    29      Pressure oversampling (Baro_Types.Oversampling'Pos)
--    30      Temperature oversampling
--    31      Baro IIR filter on, 1 or 0
--    32-35   Accel counts per g, IEEE 754 single
--    36-39   Gyro counts per degree per second, IEEE 754 single
--    40-51   Log every Nth IMU sample, 16-bit, one per phase Idle .. Landed
--            (0 = not logged in that phase)
--    52      Calibration length in bytes
--    53      Baro chip id (16#60# BMP390, 16#50# BMP388), which says how
--            to read the calibration and compensate the raw values
--    54-55   Reserved, zero
--    56-87   Baro factory calibration, Length bytes used. Needed to turn
--            the raw baro values into pascals and degrees.

with Interfaces; use Interfaces;
with System;
with System.Storage_Elements; use System.Storage_Elements;

with Baro_Types;
with Imu_Types;

package Telemetry
  with Preelaborate
is
   --  change this whenever Sample or Header changes layout
   Format_Version : constant Unsigned_8 := 16#02#;

   Sample_Size : constant := 22;
   Header_Size : constant := 88;

   type Sample is record
      Timestamp   : Unsigned_32 := 0;
      Accel       : Imu_Types.Raw_Vector := (others => 0);
      Gyro        : Imu_Types.Raw_Vector := (others => 0);
      Pressure    : Baro_Types.Raw_Count := 0;
      Temperature : Baro_Types.Raw_Count := 0;
   end record
     with Bit_Order            => System.Low_Order_First,
          Scalar_Storage_Order => System.Low_Order_First,
          Size                 => 8 * Sample_Size;

   for Sample use record
      Timestamp   at  0 range 0 .. 31;
      Accel       at  4 range 0 .. 47;
      Gyro        at 10 range 0 .. 47;
      Pressure    at 16 range 0 .. 23;
      Temperature at 19 range 0 .. 23;
   end record;

   --  Returns the timestamp, for Flight_Journal.Timestamp_Of.
   function Timestamp_Of (S : Sample) return Unsigned_32 is (S.Timestamp);

   --  Returns a sample from one IMU reading and the latest raw baro
   --  reading.
   function Make
     (Imu  : Imu_Types.Raw_Sample;
      Baro : Baro_Types.Raw_Reading) return Sample
   is ((Timestamp   => Imu.Timestamp,
        Accel       => Imu.Accel,
        Gyro        => Imu.Gyro,
        Pressure    => Baro.Pressure,
        Temperature => Baro.Temperature));

   subtype Board_Id_String is String (1 .. 16);

   --  how many IMU samples per logged sample, per phase, indexed by
   --  Flight_State.Phase'Pos
   type Decimation_Table is array (0 .. 5) of Unsigned_16;

   type Header is record
      Board_Id            : Board_Id_String := (others => ' ');
      Tick_Us             : Unsigned_32 := 0;
      Accel_ODR_Hz        : Unsigned_16 := 0;
      Gyro_ODR_Hz         : Unsigned_16 := 0;
      Baro_Rate_Hz        : Unsigned_16 := 0;
      Accel_Range         : Unsigned_8  := 0;
      Gyro_Range          : Unsigned_8  := 0;
      Low_Pass            : Unsigned_8  := 0;
      Pressure_OSR        : Unsigned_8  := 0;
      Temperature_OSR     : Unsigned_8  := 0;
      Baro_Filter         : Unsigned_8  := 0;
      Accel_Counts_Per_G  : Float       := 0.0;
      Gyro_Counts_Per_Dps : Float       := 0.0;
      Log_Every           : Decimation_Table := (others => 0);
      Cal_Length          : Unsigned_8  := 0;
      Baro_Chip_Id        : Unsigned_8  := 0;
      Reserved            : Storage_Array (1 .. 2) := (others => 0);
      Calibration         : Storage_Array
        (1 .. Baro_Types.Max_Calibration_Size) := (others => 0);
   end record
     with Bit_Order            => System.Low_Order_First,
          Scalar_Storage_Order => System.Low_Order_First,
          Size                 => 8 * Header_Size;

   for Header use record
      Board_Id            at  0 range 0 .. 127;
      Tick_Us             at 16 range 0 .. 31;
      Accel_ODR_Hz        at 20 range 0 .. 15;
      Gyro_ODR_Hz         at 22 range 0 .. 15;
      Baro_Rate_Hz        at 24 range 0 .. 15;
      Accel_Range         at 26 range 0 .. 7;
      Gyro_Range          at 27 range 0 .. 7;
      Low_Pass            at 28 range 0 .. 7;
      Pressure_OSR        at 29 range 0 .. 7;
      Temperature_OSR     at 30 range 0 .. 7;
      Baro_Filter         at 31 range 0 .. 7;
      Accel_Counts_Per_G  at 32 range 0 .. 31;
      Gyro_Counts_Per_Dps at 36 range 0 .. 31;
      Log_Every           at 40 range 0 .. 95;
      Cal_Length          at 52 range 0 .. 7;
      Baro_Chip_Id        at 53 range 0 .. 7;
      Reserved            at 54 range 0 .. 15;
      Calibration         at 56 range 0 .. 255;
   end record;

end Telemetry;
