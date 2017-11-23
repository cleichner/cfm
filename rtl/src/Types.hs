{-# LANGUAGE BinaryLiterals #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Types where

import Clash.Prelude hiding (Word, cycle, v)
import GHC.Generics

import Control.DeepSeq (NFData)
import Control.Lens hiding ((:>))

type Width = 16
type Word = BitVector Width
type WordAddr = BitVector (Width - 1)
type SP = BitVector 8
type SDelta = Signed 2

data IS = IS
  { _isMData :: Word
  , _isDData :: Word
  , _isRData :: Word
  } deriving (Show, Generic, ShowX, NFData)
makeLenses ''IS

data MS = MS
  { _msDPtr :: SP
  , _msRPtr :: SP
  , _msPC :: WordAddr
  , _msT :: Word
  , _msLoadFlag :: Bool
  } deriving (Show, Generic, ShowX, NFData)
makeLenses ''MS

-- At reset, pretend we're in the second phase of a load. The undefined initial
-- memory contents will overwrite T and then we'll fetch 0.
instance Default MS where
  def = MS
    { _msDPtr = 0
    , _msRPtr = 0
    , _msPC = 0
    , _msT = 0
    , _msLoadFlag = True
    }

data OS = OS
  { _osMWrite :: Maybe (WordAddr, Word)
  , _osMRead :: WordAddr
  , _osDOp :: (SP, SDelta, Maybe Word)
  , _osROp :: (SP, SDelta, Maybe Word)
  } deriving (Show, Generic, ShowX, NFData)
makeLenses ''OS


data Inst = NotLit FlowOrAluInst
          | Lit (BitVector 15)
          deriving (Show)

instance BitPack Inst where
  type BitSize Inst = 16

  pack (NotLit i) = 0 ++# pack i
  pack (Lit v) = 1 ++# v

  unpack v = case msb v of
    0 -> NotLit $ unpack $ slice d14 d0 v
    _ -> Lit $ slice d14 d0 v

data FlowOrAluInst = Jump (BitVector 13)
                   | JumpZ (BitVector 13)
                   | Call (BitVector 13)
                   | ALU Bool TMux Bool Bool Bool (BitVector 2) (BitVector 2)
                   deriving (Show)

instance BitPack FlowOrAluInst where
  type BitSize FlowOrAluInst = 15

  pack (Jump v) = 0b00 ++# v
  pack (JumpZ v) = 0b01 ++# v
  pack (Call v) = 0b10 ++# v
  pack (ALU rpc t' tn tr nm rd dd) = 0b11 ++#
                                     pack (rpc, t', tn, tr, nm, low, rd, dd)

  unpack v = case slice d14 d13 v of
    0b00 -> Jump tgt
    0b01 -> JumpZ tgt
    0b10 -> Call tgt
    _    -> ALU rpc t' tn tr nm rd dd
    where
      tgt = slice d12 d0 v
      (rpc, t', tn, tr, nm, _ :: Bit, rd, dd) = unpack tgt

data TMux = T
          | N
          | TPlusN
          | TAndN
          | TOrN
          | TXorN
          | NotT
          | NEqT
          | NLtT
          | NRshiftT
          | NMinusT
          | R
          | MemAtT
          | NLshiftT
          | Depth
          | NULtT
          deriving (Eq, Enum, Bounded, Show)

instance BitPack TMux where
  type BitSize TMux = 4
  pack = fromIntegral . fromEnum
  unpack = toEnum . fromIntegral
