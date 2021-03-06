{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}

-- | Interrupt support.
module RTL.IRQ where

import Clash.Prelude

import CFM.Types
import CFM.Inst
import RTL.IOBus (moorep)

data SIS = SIS
  { sisEn :: Bool
  , sisEnter :: Bool
  } deriving (Show)

instance Default SIS where def = SIS False False

-- | A simple interrupt controller supporting a single, active-high interrupt
-- input.
--
-- The controller contains an interrupt enable/disable register.  Interrupts
-- can be enabled by writing to any location within the controller's address
-- space. They are disabled when an interrupt occurs. Currently, there is no
-- way to disable interrupts programatically.
singleIrqController
  :: (HasClockReset d g s)
  => Signal d Bool    -- ^ Interrupt input, active high, level-sensitive.
  -> Signal d Bool    -- ^ CPU fetch signal, active high.
  -> Signal d (Maybe (BitVector 1, Maybe Cell))   -- ^ I/O bus request.
  -> ( Signal d Cell -> Signal d Cell
     , Signal d Cell
     )  -- ^ Memory-to-CPU alteration constructor and I/O response,
        -- respectively.
singleIrqController irqS fetchS reqS = (memCtor, respS)
  where
    (respS, entryS) = moorep datapathT
                             (repeat . zeroExtend . pack . sisEn)
                             sisEnter
                             (bundle (irqS, fetchS))
                             reqS

    -- Normally, pass mem. When entering the ISR, intervene in the next fetch
    -- cycle.
    memCtor = mux entryS (pure $ pack $ NotLit $ Call 1)

    datapathT (SIS en _) (req, (irq, fetch)) = SIS en' entry'
      where
        -- Interrupt entry happens on any fetch cycle where we're enabled and
        -- irq is asserted, whether or not we were entering on the previous
        -- cycle.
        entry' = fetch && en && irq
        -- Set enable when we're written. Clear it on entry.
        en' = not entry' && (written || en)
        written = case req of
          Just (_, Just _) -> True
          _                -> False

data MIS = MIS
  { misEn :: Bool
  , misStatus :: Vec Width Bool
  , misIEn :: Vec Width Bool
  , misAddr :: BitVector 2
  , misEnter :: Bool
  } deriving (Show)

instance Default MIS where
  def = MIS False (repeat False) (repeat False) 0 False

-- Registers:
-- 0: interrupt statuses on read; enable trigger on write
-- 2: literal enable bit (read/write)
-- 4: interrupt mask set enable
-- 6: interrupt mask clear enable
multiIrqController
  :: (HasClockReset d g s)
  => Vec Width (Signal d Bool)
      -- ^ Interrupt inputs, active high, level-sensitive.
  -> Signal d Bool    -- ^ CPU fetch signal, active high.
  -> Signal d (Maybe (BitVector 2, Maybe Cell))   -- ^ I/O bus request.
  -> ( Signal d Cell -> Signal d Cell
     , Signal d Cell
     )  -- ^ Memory-to-CPU alteration constructor and I/O response,
        -- respectively.
multiIrqController irqS fetchS reqS = (memCtor, respS)
  where
    (respS, entryS) = moorep datapathT datapathR misEnter
                             (bundle (bundle irqS, fetchS))
                             reqS

    -- Normally, pass mem. When entering the ISR, intervene in the next fetch
    -- cycle.
    memCtor = mux entryS (pure $ pack $ NotLit $ Call 1)

    datapathT s (req, (irqs, fetch)) = s'
      where
        s' = MIS
          { misEn = not entry' && case req of
              -- Any write to the enable-trigger register enables.
              Just (0, Just _) -> True
              -- The bottom bit of writes @ 1 gets copied into the enable bit.
              Just (1, Just v) -> unpack $ lsb v
              -- Anything else leaves matters unchanged.
              _                -> misEn s

          , misStatus = maskedIrqs
          , misIEn = case req of
              Just (2, Just v) -> zipWith (||) (misIEn s) (unpack v)
              Just (3, Just v) -> zipWith (&&) (misIEn s) (map not (unpack v))
              _                -> misIEn s
          , misAddr = case req of
              Just (a, Nothing) -> a
              _                 -> misAddr s
          , misEnter = entry'
          }

        maskedIrqs = zipWith (&&) irqs $ misIEn s
        entry' = fetch && misEn s && foldl1 (||) maskedIrqs

    datapathR s = pack (misStatus s) :>
                  zeroExtend (pack (misEn s)) :>
                  repeat (pack (misIEn s))
