with STM32G431xx.RCC;
use STM32G431xx.RCC;
with STM32G431xx.GPIO;
use STM32G431xx.GPIO;

procedure Blinky is
begin
   -- enable GPIOB clock
   RCC_Periph.AHB2ENR.GPIOBEN := 1;
   -- set to output mode
   GPIOB_Periph.MODER.Arr (8) := 2#01#;
   -- push pull using array
   GPIOB_Periph.OTYPER.OT.Arr(8) := 0;
   -- no pull
   GPIOB_Periph.PUPDR.Arr(8) := 2#00#;
   -- low speed
   GPIOB_Periph.OSPEEDR.Arr(8) := 2#00#;
   loop 
      -- Turn LED on (PB8 high)
      GPIOB_Periph.BSRR.BS.Arr(8) := 1;
      delay 0.1;
      -- Turn LED off (PB8 low)
      GPIOB_Periph.BSRR.BR.Arr(8) := 1;
      delay 0.1;
   end loop;
end Blinky;