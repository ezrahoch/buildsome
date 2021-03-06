module Lib.PriorityQueue
  ( Priority(..)
  , PriorityQueue
  , empty, null, enqueue, dequeue
  ) where

import Prelude hiding (null)

import Control.Applicative ((<$>), (<|>))
import Control.Arrow ((***))
import Lib.Fifo (Fifo)
import qualified Lib.Fifo as Fifo

data Priority = PriorityLow | PriorityHigh
  deriving (Eq, Ord, Show)

data PriorityQueue a = PriorityQueue
  { _fifoLowPriority :: Fifo a
  , _fifoHighPriority :: Fifo a
  }
empty :: PriorityQueue a
empty = PriorityQueue Fifo.empty Fifo.empty

null :: PriorityQueue a -> Bool
null (PriorityQueue low high) = Fifo.null low && Fifo.null high

enqueue :: Priority -> a -> PriorityQueue a -> PriorityQueue a
enqueue PriorityLow x (PriorityQueue low high) = PriorityQueue (Fifo.enqueue x low) high
enqueue PriorityHigh x (PriorityQueue low high) = PriorityQueue low (Fifo.enqueue x high)

dequeue :: PriorityQueue a -> Maybe (PriorityQueue a, (Priority, a))
dequeue (PriorityQueue low high) =
  ((( PriorityQueue  low ) *** (,) PriorityHigh) <$> Fifo.dequeue high) <|>
  (((`PriorityQueue` high) *** (,) PriorityLow ) <$> Fifo.dequeue low)
