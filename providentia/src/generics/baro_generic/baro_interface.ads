--  baro_interface.ads
--  The operations every barometer chip crate provides, gathered into one
--  package. Part of baro_generic. Payload instantiates it once with the
--  fitted chip.
--
--  General plan:
--  Read_Raw returns the chip's ADC values, which is what gets logged.
--  Compensate turns them into the units from baro_types.ads with the
--  chip's own datasheet formula, for anything on board that needs real
--  units (the state machine's altitude). Read does both in one call.
--
--  Init soft resets the chip and writes every setting explicitly, then
--  reads the mode back. The BMP390 keeps power across an MCU reset and was
--  seen ignoring a mode change, which froze its readings for a whole bench
--  run (ada-flight-logger, November 2026). The chip crate must not trust
--  reset defaults or a single write.
--
--  Every operation is a rename of the chip's procedure, so this package
--  has no body.

with Baro_Types; use Baro_Types;

generic
   with procedure Driver_Init (Cfg : Baro_Config; Ok : out Boolean);
   with function Driver_Check_Id return Boolean;
   with function Driver_Data_Ready return Boolean;
   with procedure Driver_Read (R : out Reading; Ok : out Boolean);
   with procedure Driver_Read_Raw (R : out Raw_Reading; Ok : out Boolean);
   with function Driver_Compensate (Raw : Raw_Reading) return Reading;
   with procedure Driver_Read_Calibration
     (Cal : out Calibration_Blob;
      Ok  : out Boolean);
package Baro_Interface is

   --  Soft reset, apply Cfg, read the factory calibration and wait for the
   --  first new result. Blocks for up to about 100 ms. Ok is False if the
   --  chip doesn't answer, rejects the combination, the mode doesn't read
   --  back, or no new result arrives.
   procedure Init (Cfg : Baro_Config; Ok : out Boolean) renames Driver_Init;

   --  Returns True if the chip id register holds the expected value.
   function Check_Id return Boolean renames Driver_Check_Id;

   --  Returns True if a result newer than the last Read is waiting.
   function Data_Ready return Boolean renames Driver_Data_Ready;

   --  Read the latest pressure and temperature, compensated. Both are 0 if
   --  Ok is False.
   procedure Read (R : out Reading; Ok : out Boolean) renames Driver_Read;

   --  Read the latest pressure and temperature as raw ADC values. Both are
   --  0 if Ok is False.
   procedure Read_Raw (R : out Raw_Reading; Ok : out Boolean)
     renames Driver_Read_Raw;

   --  Returns Raw compensated with the calibration Init read. All zero
   --  before Init has read it.
   function Compensate (Raw : Raw_Reading) return Reading
     renames Driver_Compensate;

   --  Return the factory calibration bytes, for the journal header.
   procedure Read_Calibration (Cal : out Calibration_Blob; Ok : out Boolean)
     renames Driver_Read_Calibration;

end Baro_Interface;
