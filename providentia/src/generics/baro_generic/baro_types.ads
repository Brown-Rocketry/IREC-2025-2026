--  baro_types.ads
--  Types shared by every barometer chip crate and the code that reads them.
--  Part of baro_generic. No hardware access.
--
--  General plan:
--  Two forms of a reading:
--     Raw_Reading  the ADC values as the chip gives them. This is what is
--                  logged, so the original data is never lost and can be
--                  compensated again later. Only meaningful together with
--                  the chip's calibration, which the journal header holds.
--                  Up to 24 bits each, which covers the BMP3xx (24), the
--                  BMP280 (20) and the LPS22 (16-bit temperature).
--     Reading      compensated, in the same physical units whatever chip
--                  is fitted. Used on board by the state machine and the
--                  bench check.
--  The compensation formula stays inside the chip crate, because it is
--  different for every chip.
--
--  Units of Reading are fixed point:
--     Pressure     1/64 Pa, 24-bit unsigned. 0.016 Pa resolution, about
--                  the BMP390's own, up to 262 kPa.
--     Temperature  1/100 degree C, 16-bit signed, -327.68 to 327.67.
--
--  Altitude is not here: it doesn't depend on the chip, so it lives in
--  Flight_State.

with Interfaces; use Interfaces;
with System.Storage_Elements; use System.Storage_Elements;

package Baro_Types
  with Pure
is
   Pressure_Counts_Per_Pa : constant := 64;
   Temperature_Counts_Per_C : constant := 100;

   subtype Pressure_Count    is Unsigned_32 range 0 .. 2**24 - 1;
   subtype Temperature_Count is Integer_16;

   --  ADC values straight from the chip, before compensation
   subtype Raw_Count is Unsigned_32 range 0 .. 2**24 - 1;

   type Raw_Reading is record
      Pressure    : Raw_Count := 0;
      Temperature : Raw_Count := 0;
   end record;

   --  one compensated reading
   type Reading is record
      Pressure    : Pressure_Count    := 0;
      Temperature : Temperature_Count := 0;
   end record;

   --  Returns the pressure in pascals.
   function To_Pa (P : Pressure_Count) return Float is
     (Float (P) / Float (Pressure_Counts_Per_Pa));

   --  Returns the temperature in degrees C.
   function To_C (T : Temperature_Count) return Float is
     (Float (T) / Float (Temperature_Counts_Per_C));

   --  Returns Pa in counts, rounded and held inside the range, so an out of
   --  range value can't raise (any raise stops the board on this runtime).
   function From_Pa (Pa : Float) return Pressure_Count is
     (if Pa <= 0.0 then 0
      elsif Pa >= Float (Pressure_Count'Last) / Float (Pressure_Counts_Per_Pa)
      then Pressure_Count'Last
      else Pressure_Count (Pa * Float (Pressure_Counts_Per_Pa)));

   --  Returns C in counts, rounded and held inside the range.
   function From_C (C : Float) return Temperature_Count is
     (if C <= Float (Temperature_Count'First)
                / Float (Temperature_Counts_Per_C)
      then Temperature_Count'First
      elsif C >= Float (Temperature_Count'Last)
                   / Float (Temperature_Counts_Per_C)
      then Temperature_Count'Last
      else Temperature_Count (C * Float (Temperature_Counts_Per_C)));

   type Oversampling is (X1, X2, X4, X8, X16, X32);

   type Baro_Config is record
      Pressure_OSR    : Oversampling := X8;
      Temperature_OSR : Oversampling := X1;

      --  The chip picks the nearest rate at or below this. Init sets Ok to
      --  False if the oversampling can't finish inside one output period:
      --  terrarium_pico left the BMP390 in that state, which the datasheet
      --  warns against.
      Rate_Hz         : Positive := 50;

      --  The IIR filter smooths noise but adds lag at apogee. Off for
      --  flight.
      Filter_On       : Boolean := False;
   end record;

   --  The chip's factory calibration, as the bytes it stores (21 on the
   --  BMP390). Stored in the journal header: the log holds raw readings,
   --  and these bytes are what turns them into pascals and degrees.
   Max_Calibration_Size : constant := 32;

   type Calibration_Blob is record
      Length : Natural range 0 .. Max_Calibration_Size := 0;
      Data   : Storage_Array (1 .. Max_Calibration_Size) := (others => 0);
   end record;

end Baro_Types;
