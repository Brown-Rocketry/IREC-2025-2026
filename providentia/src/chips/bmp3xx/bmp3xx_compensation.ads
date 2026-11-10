--  bmp3xx_compensation.ads
--  BMP3xx compensation in 64-bit integer arithmetic. Part of the bmp3xx
--  chip crate. Pure math, no bus access, so it is tested on a host machine
--  against reference vectors.
--
--  General plan:
--  Temperature follows Bosch's integer algorithm exactly: t_lin is the
--  linearized temperature in units of 2^-16 degree C. Pressure evaluates
--  the datasheet polynomial (DS 8.6) on the raw trim registers. Bosch's own
--  integer grouping overflows 64 bits for some legal trims (par_p5 near
--  65535 with par_p6 * t_lin positive) and above about 128 degree C, so
--  every term is carried at one scale of 2^36 per pascal, with each
--  product split so it fits.
--
--  Integers rather than Float even though the G4 has an FPU: the result is
--  bit-for-bit the same on the board and on the host, which is what makes
--  the reference tests mean something, and SPARK proves it can't overflow.
--  An overflow would raise, and a raise stops the board on this runtime.
--
--  Ported unchanged in arithmetic from Ada-Device-Drivers
--  (Devices.BMP3XX.Integer_Compensation), where it is proved free of
--  overflow for every trim value and every 24-bit raw sample.
--
--  Reference: BMP390 datasheet, 3.11.1 (Table 24), 8.5 (temperature), 8.6
--             (pressure); Bosch BMP3 SensorAPI integer compensation

with Interfaces; use Interfaces;
with System.Storage_Elements; use System.Storage_Elements;

with BMP3XX_Types; use BMP3XX_Types;

package BMP3XX_Compensation
  with Pure, SPARK_Mode
is
   --  t_lin bound for every trim and raw value: |d1| < 2^24, so
   --  |t2 d1 2^18 + t3 d1^2| < 2^58 + 2^55
   T_Lin_Bound : constant := 2**26 + 2**23;
   subtype Linear_Temperature is Integer_64 range -T_Lin_Bound .. T_Lin_Bound;

   --  Trim field I bytes into Raw, counting from 0 like the datasheet:
   --  unsigned 16-bit, signed 16-bit (both LSB first), signed 8-bit.
   function U16_At (Raw : Storage_Array; I : Natural) return Trim_U16 is
     (Integer (Raw (Raw'First + Storage_Offset (I)))
      + 256 * Integer (Raw (Raw'First + Storage_Offset (I) + 1)))
     with Pre => Raw'Length = Calib_Data_Len and then I < 20;

   function S16_At (Raw : Storage_Array; I : Natural) return Trim_S16 is
     (if U16_At (Raw, I) >= 2**15 then U16_At (Raw, I) - 2**16
      else U16_At (Raw, I))
     with Pre => Raw'Length = Calib_Data_Len and then I < 20;

   function S8_At (Raw : Storage_Array; I : Natural) return Trim_S8 is
     (if Integer (Raw (Raw'First + Storage_Offset (I))) >= 2**7
      then Integer (Raw (Raw'First + Storage_Offset (I))) - 2**8
      else Integer (Raw (Raw'First + Storage_Offset (I))))
     with Pre => Raw'Length = Calib_Data_Len and then I < 21;

   --  Copy the 21-byte trim block (0x31 .. 0x45) into its register fields,
   --  at the offsets of DS Table 24.
   function Parse_Trim (Raw : Storage_Array) return Trim_Registers
     with Pre => Raw'Length = Calib_Data_Len;

   --  DS 8.5 in integers: t_lin = (t2 d1 2^18 + t3 d1^2) / 2^32 with
   --  d1 = raw - 256 t1, truncated toward zero.
   function Temperature_Linear
     (Trim : Trim_Registers; Uncomp_Temp : Raw_Sample)
      return Linear_Temperature;

   --  t_lin to 0.01 degree C: t_lin * 100 / 2^16, truncated toward zero.
   function To_Centi_Celsius (T_Lin : Linear_Temperature) return Centi_Celsius
     with Post => Integer_64 (To_Centi_Celsius'Result) = T_Lin * 25 / 2**14;

   --  DS 8.6 in integers, in 0.01 Pa. Needs t_lin from the same sample.
   function Pressure_Centi_Pa
     (Trim         : Trim_Registers;
      T_Lin        : Linear_Temperature;
      Uncomp_Press : Raw_Sample) return Centi_Pascal;

   --  Both steps, temperature first since pressure depends on it.
   function Compensate
     (Trim : Trim_Registers; Uncomp_Temp, Uncomp_Press : Raw_Sample)
      return Fixed_Reading;

end BMP3XX_Compensation;
