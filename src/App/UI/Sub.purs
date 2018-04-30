module App.UI.Sub where

import Prelude hiding (sub)

import Control.Monad.Eff (Eff)
import Control.Monad.Eff.Console (CONSOLE, log)
import Data.Argonaut (Json)
import Data.Maybe (Maybe(..))
import Spork.EventQueue (EventQueueInstance, EventQueueAccum)
import Spork.EventQueue as EventQueue
import Spork.Interpreter (Interpreter(..))
import Ssb.Config (SSB)

data Sub a = ReceiveSsbMessage (Json -> a)
derive instance functorSub :: Functor Sub

type SubEffects eff = (ssb :: SSB, console :: CONSOLE | eff)

type E fx = Eff (SubEffects fx)

-- NOTE: couldn't use stepper here because can't directly return an `Eff fx Action`
-- due to needing to defer to the listener to add items to the queue

-- NOTE: also couldn't use withCont because it executes every sub,
-- we can't differentiate between first time (for setup) and subsequent times

type Handler eff = (Json -> E eff Unit)

interpreter ∷
  ∀ eff o  -- o is Action!!
  . (Handler eff -> E eff Unit)
  -> Interpreter (E eff) Sub o
interpreter listenWith = Interpreter $ EventQueue.withAccum spec
  where

    spec :: EventQueueInstance (E eff) o -> E eff (EventQueueAccum (E eff) Boolean (Sub o))
    spec queue = pure { init, update, commit }
      where
        getHandler :: Sub o -> Handler eff
        getHandler sub json =
          case sub of
            ReceiveSsbMessage k -> do
              queue.push (k json)
              queue.run

        init = false

        update started sub = do
          when (not started) $ listenWith $ getHandler sub
          pure true

        commit = pure