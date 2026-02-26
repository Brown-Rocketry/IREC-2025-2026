with STM32G431xx.RCC;
use STM32G431xx.RCC;
with STM32G431xx.GPIO;
use STM32G431xx.GPIO;

procedure Blinky is
begin
   -- enable GPIOA clock (NOT GPIOB)
   RCC_Periph.AHB2ENR.GPIOAEN := 1;
   -- configure PA5 as output
   -- set to output mode
   GPIOA_Periph.MODER.Arr (5) := 2#01#;
   -- push pull using array
   GPIOA_Periph.OTYPER.OT.Arr(5) := 0;
   -- no pull
   GPIOA_Periph.PUPDR.Arr(5) := 2#00#;
   -- low speed
   GPIOA_Periph.OSPEEDR.Arr(5) := 2#00#;

   loop 
      -- Turn LED on (PB8 high)
      GPIOA_Periph.BSRR.BS.Arr(5) := 1;
      delay 1.0;
      -- Turn LED off (PB8 low)
      GPIOA_Periph.BSRR.BR.Arr(5) := 1;
      delay 1.0;
   end loop;
end Blinky;