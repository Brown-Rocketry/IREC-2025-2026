--  bmp3xx_compensation.adb
--  Arithmetic unchanged from Ada-Device-Drivers'
--  Devices.BMP3XX.Integer_Compensation; see the spec for the plan.

package body BMP3XX_Compensation
  with SPARK_Mode
is

   --  A * B for |A| <= Max_A and |B| <= Max_B, with the bound on the result
   --  stated. Each instance gives the provers one product with constant
   --  bounds; the callers then only add and divide.
   generic
      Max_A, Max_B : Integer_64;
   function Bounded_Product (A, B : Integer_64) return Integer_64
     with Pre  => A in -Max_A .. Max_A and then B in -Max_B .. Max_B,
          Post => Bounded_Product'Result = A * B
            and then Bounded_Product'Result
                       in -(Max_A * Max_B) .. Max_A * Max_B;

   function Bounded_Product (A, B : Integer_64) return Integer_64 is
   begin
      return A * B;
   end Bounded_Product;

   --  bounds of the inputs: |d1| <= 2^24, trims are 8 or 16 bits, the
   --  2^14-offset p1 and p2 lie within +-(2^15 + 2^14), raw < 2^24
   D1_Max  : constant := 2**24;
   T_Max   : constant := T_Lin_Bound;
   U16_Max : constant := 2**16;
   S8_Max  : constant := 2**7;
   P12_Max : constant := 2**15 + 2**14;
   Raw_Max : constant := 2**24;

   --  bounds of the temperature powers: T^2 at 2^32 and T^3 at 2^21
   T2_Max  : constant := T_Max * T_Max;
   T2s_Max : constant := T2_Max / 2**17;
   T3_Max  : constant := 3 * 2**50;
   Q_Max   : constant := 2**34;

   function Mul_T2_D1   is new Bounded_Product (U16_Max, D1_Max);
   function Mul_D1_D1   is new Bounded_Product (D1_Max, D1_Max);
   function Mul_D1sq_T3 is new Bounded_Product (2**48, S8_Max);
   function Mul_T_T     is new Bounded_Product (T_Max, T_Max);
   function Mul_T2s_T   is new Bounded_Product (T2s_Max, T_Max);
   function Mul_U16_T   is new Bounded_Product (U16_Max, T_Max);
   function Mul_S8_T2   is new Bounded_Product (S8_Max, T2_Max);
   function Mul_S8_T3   is new Bounded_Product (S8_Max, T3_Max);
   function Mul_P12_T   is new Bounded_Product (P12_Max, T_Max);
   function Mul_S8_T    is new Bounded_Product (S8_Max, T_Max);
   function Mul_Sens_R  is new Bounded_Product (2**37, Raw_Max);
   function Mul_Q_R     is new Bounded_Product (Q_Max, Raw_Max);
   function Mul_38_R    is new Bounded_Product (2**38, Raw_Max);
   function Mul_R_R     is new Bounded_Product (Raw_Max, Raw_Max);
   function Mul_S8_R2   is new Bounded_Product (S8_Max, 2**48);

   function Parse_Trim (Raw : Storage_Array) return Trim_Registers is
   begin
      --  register layout from DS Table 24, no scaling
      return
        (Par_T1  => U16_At (Raw, 0),
         Par_T2  => U16_At (Raw, 2),
         Par_T3  => S8_At (Raw, 4),
         Par_P1  => S16_At (Raw, 5),
         Par_P2  => S16_At (Raw, 7),
         Par_P3  => S8_At (Raw, 9),
         Par_P4  => S8_At (Raw, 10),
         Par_P5  => U16_At (Raw, 11),
         Par_P6  => U16_At (Raw, 13),
         Par_P7  => S8_At (Raw, 15),
         Par_P8  => S8_At (Raw, 16),
         Par_P9  => S16_At (Raw, 17),
         Par_P10 => S8_At (Raw, 19),
         Par_P11 => S8_At (Raw, 20));
   end Parse_Trim;

   function Temperature_Linear
     (Trim : Trim_Registers; Uncomp_Temp : Raw_Sample)
      return Linear_Temperature
   is
      --  raw minus the 2^8-scaled par_t1
      D1 : constant Integer_64 :=
        Integer_64 (Uncomp_Temp) - 256 * Integer_64 (Trim.Par_T1);
      --  linear term t2 d1, < 2^40
      Linear : constant Integer_64 := Mul_T2_D1 (Integer_64 (Trim.Par_T2), D1);
      --  square term t3 d1^2, <= 2^55
      Square : constant Integer_64 :=
        Mul_D1sq_T3 (Mul_D1_D1 (D1, D1), Integer_64 (Trim.Par_T3));
   begin
      --  temperature times 2^48, then down to 2^16 like Bosch
      return (Linear * 2**18 + Square) / 2**32;
   end Temperature_Linear;

   function To_Centi_Celsius (T_Lin : Linear_Temperature) return Centi_Celsius
   is
   begin
      return Centi_Celsius (T_Lin * 25 / 2**14);
   end To_Centi_Celsius;

   function Pressure_Centi_Pa
     (Trim         : Trim_Registers;
      T_Lin        : Linear_Temperature;
      Uncomp_Press : Raw_Sample) return Centi_Pascal
   is
      --  every term below is in units of 2^-36 Pa
      Scale : constant := 2**36;

      T : constant Integer_64 := T_Lin;
      R : constant Integer_64 := Integer_64 (Uncomp_Press);

      --  powers of temperature: T^2 at 2^32, T^3 at 2^21
      T_2 : constant Integer_64 := Mul_T_T (T, T);
      T_3 : constant Integer_64 := Mul_T2s_T (T_2 / 2**17, T) / 2**10;

      --  offset (DS: p5 + p6 t + p7 t^2 + p8 t^3), Table 24 scales:
      --  p5 2^-3, p6 2^6, p7 2^8, p8 2^15
      Offset : constant Integer_64 :=
        Integer_64 (Trim.Par_P5) * 2**39
        + Mul_U16_T (Integer_64 (Trim.Par_P6), T) * 2**14
        + Mul_S8_T2 (Integer_64 (Trim.Par_P7), T_2) / 2**4
        + Mul_S8_T3 (Integer_64 (Trim.Par_P8), T_3);

      --  sensitivity per raw count (DS: p1 + p2 t + p3 t^2 + p4 t^3),
      --  scales p1 2^20 and p2 2^29 both offset by 2^14, p3 2^32, p4 2^37
      Sensitivity : constant Integer_64 :=
        (Integer_64 (Trim.Par_P1) - 2**14) * 2**16
        + Mul_P12_T (Integer_64 (Trim.Par_P2) - 2**14, T) / 2**9
        + Mul_S8_T2 (Integer_64 (Trim.Par_P3), T_2) / 2**28
        + Mul_S8_T3 (Integer_64 (Trim.Par_P4), T_3) / 2**22;

      --  second order (DS: (p9 + p10 t) raw^2), both scaled 2^48
      Q : constant Integer_64 :=
        Integer_64 (Trim.Par_P9) * 2**16
        + Mul_S8_T (Integer_64 (Trim.Par_P10), T);
      Square : constant Integer_64 :=
        Mul_38_R (Mul_Q_R (Q, R) / 2**20, R) / 2**8;

      --  third order (DS: p11 raw^3), scaled 2^65
      Cube : constant Integer_64 :=
        Mul_38_R
          (Mul_S8_R2 (Integer_64 (Trim.Par_P11), Mul_R_R (R, R)) / 2**17, R)
        / 2**12;

      Total : constant Integer_64 :=
        Offset + Mul_Sens_R (Sensitivity, R) + Square + Cube;
   begin
      --  to 0.01 Pa, splitting off whole pascals so the multiply fits
      return Centi_Pascal
        ((Total / Scale) * 100 + ((Total rem Scale) * 100) / Scale);
   end Pressure_Centi_Pa;

   function Compensate
     (Trim : Trim_Registers; Uncomp_Temp, Uncomp_Press : Raw_Sample)
      return Fixed_Reading
   is
      T_Lin : constant Linear_Temperature :=
        Temperature_Linear (Trim, Uncomp_Temp);
   begin
      return (Pressure    => Pressure_Centi_Pa (Trim, T_Lin, Uncomp_Press),
              Temperature => To_Centi_Celsius (T_Lin));
   end Compensate;

end BMP3XX_Compensation;
