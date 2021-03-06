{-# LANGUAGE DeriveGeneric, OverloadedStrings #-}
module Lib.StdOutputs
  ( StdOutputs(..)
  , str, null
  ) where

import Data.Binary (Binary)
import Data.List (intersperse)
import Data.Monoid
import Data.String (IsString)
import GHC.Generics (Generic)
import Prelude hiding (null)

data StdOutputs a = StdOutputs
  { stdOut :: a
  , stdErr :: a
  } deriving (Generic, Show)
instance Binary a => Binary (StdOutputs a)

null :: (Eq a, Monoid a) => StdOutputs a -> Bool
null (StdOutputs out err) = mempty == out && mempty == err

str :: (Eq a, Monoid a, IsString a) => StdOutputs a -> Maybe a
str (StdOutputs out err)
  | mempty == out && mempty == err = Nothing
  | otherwise = Just $ mconcat $ intersperse "\n" $ concat
  [ [ out | mempty /= out ]
  , [ err | mempty /= err ]
  ]
