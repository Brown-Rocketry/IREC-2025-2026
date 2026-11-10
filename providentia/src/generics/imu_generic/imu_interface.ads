--  imu_interface.ads
--  The operations every IMU chip crate provides, gathered into one package.
--  Part of imu_generic. Payload instantiates it once with the fitted chip.
--
--  General plan:
--  The logger always reads with Read_Batch. A FIFO chip drains its FIFO; a
--  polling chip reads one sample and returns Count = 1. Either way the
--  logger code is the same.
--
--  Scale comes from the chip, not from a formula here. Datasheets don't
--  always match the nominal range: the LSM9DS1 "+/-16 g" setting is
--  0.732 mg/LSB, about +/-24 g of counts, which the bench check against
--  gravity confirmed (1314 counts at rest, not 2048).
--
--  Every operation is a rename of the chip's procedure, so this package
--  has no body and costs nothing at run time.

with Imu_Types; use Imu_Types;

generic
   with procedure Driver_Init (Cfg : Imu_Config; Ok : out Boolean);
   with function Driver_Check_Id return Boolean;
   with function Driver_Capabilities return Imu_Caps;
   with function Driver_Accel_Counts_Per_G (R : Accel_Range) return Float;
   with function Driver_Gyro_Counts_Per_Dps (R : Gyro_Range) return Float;
   with procedure Driver_Read_Accel (V : out Raw_Vector; Ok : out Boolean);
   with procedure Driver_Read_Gyro (V : out Raw_Vector; Ok : out Boolean);
   with procedure Driver_Read_Batch
     (Buf   : out Raw_Sample_Array;
      Count : out Natural;
      Ok    : out Boolean);
package Imu_Interface is

   --  Reset the chip and apply Cfg. Ok is False if the chip doesn't answer,
   --  rejects a setting (such as a range it doesn't have), or a setting
   --  doesn't read back. Call Check_Id first.
   procedure Init (Cfg : Imu_Config; Ok : out Boolean) renames Driver_Init;

   --  Returns True if the chip's identity register holds the expected value.
   --  This is the first wiring test.
   function Check_Id return Boolean renames Driver_Check_Id;

   --  Returns what this chip can do.
   function Capabilities return Imu_Caps renames Driver_Capabilities;

   --  Counts per g at range R, from the datasheet sensitivity.
   function Accel_Counts_Per_G (R : Accel_Range) return Float
     renames Driver_Accel_Counts_Per_G;

   --  Counts per degree per second at range R, from the datasheet.
   function Gyro_Counts_Per_Dps (R : Gyro_Range) return Float
     renames Driver_Gyro_Counts_Per_Dps;

   --  Read the latest accelerometer value. V is all zeros if Ok is False.
   --  For bench checks; the logger uses Read_Batch.
   procedure Read_Accel (V : out Raw_Vector; Ok : out Boolean)
     renames Driver_Read_Accel;

   --  Read the latest gyroscope value. V is all zeros if Ok is False.
   procedure Read_Gyro (V : out Raw_Vector; Ok : out Boolean)
     renames Driver_Read_Gyro;

   --  Fill Buf (Buf'First .. Buf'First + Count - 1) with every sample
   --  waiting, oldest first, up to Buf'Length. Count is 0 when nothing is
   --  new. If more were waiting than fit, the rest stay for the next call.
   --  Ok is False if the bus read fails or the FIFO overflowed since the
   --  last call (samples were lost); Count still says how many are valid.
   procedure Read_Batch
     (Buf   : out Raw_Sample_Array;
      Count : out Natural;
      Ok    : out Boolean)
     renames Driver_Read_Batch;

end Imu_Interface;
